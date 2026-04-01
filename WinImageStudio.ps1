#Requires -Version 5.1
<#
.SYNOPSIS
    WinImageStudio v1.0.1 - Modern WPF DISM GUI
.DESCRIPTION
    dismtool.ps1 mantığı, WPF arayüzüne aktarılmış tam sürüm.
    Mount Workspace, Driver/Package/Feature Servicing, Deploy, Capture,
    Export, Split, Regional Settings, FFU, Offline Registry ve daha fazlası.
#>

# ── YÖNETİCİ KONTROLÜ ──
$myWindowsID        = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole          = [System.Security.Principal.WindowsBuiltInRole]::Administrator
if (-not $myWindowsPrincipal.IsInRole($adminRole)) {
    $proc = New-Object System.Diagnostics.ProcessStartInfo "PowerShell"
    $proc.Arguments = "& '" + $script:MyInvocation.MyCommand.Path + "'"
    $proc.Verb = "runas"
    [System.Diagnostics.Process]::Start($proc) | Out-Null
    Exit
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName System.Windows.Forms   # FolderBrowserDialog için

# ── DPI AYARI ────────────────────────────────────────────────────────────────
# Per-Monitor v2 DPI Awareness — her monitörün gerçek DPI'ını kullan.
# Bu olmadan WPF %125/%150 ölçeklendirmede bulanık render eder.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class DpiHelper {
    // Per-Monitor v2 (Windows 10 1703+), fallback olarak Per-Monitor v1, sonra System
    [DllImport("shcore.dll")]
    private static extern int SetProcessDpiAwareness(int value);

    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr hwnd);

    [DllImport("gdi32.dll")]
    private static extern int GetDeviceCaps(IntPtr hdc, int nIndex);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);

    // LOGPIXELSX = 88
    private const int LOGPIXELSX = 88;

    public static void SetAwareness() {
        try {
            // PROCESS_PER_MONITOR_DPI_AWARE = 2
            int hr = SetProcessDpiAwareness(2);
            if (hr != 0) {
                // Fallback: PROCESS_SYSTEM_DPI_AWARE = 1
                SetProcessDpiAwareness(1);
            }
        } catch {
            try { SetProcessDPIAware(); } catch { }
        }
    }

    public static int GetSystemDpi() {
        IntPtr hdc = GetDC(IntPtr.Zero);
        try {
            return GetDeviceCaps(hdc, LOGPIXELSX);
        } finally {
            ReleaseDC(IntPtr.Zero, hdc);
        }
    }

    public static double GetScaleFactor() {
        return GetSystemDpi() / 96.0;
    }
}
'@ -ErrorAction SilentlyContinue

# DPI Awareness'ı XAML yüklenmeden ÖNCE ayarla
try { [DpiHelper]::SetAwareness() } catch { }

# Sistem DPI ölçek faktörünü al (96 DPI = %100, 120 = %125, 144 = %150, 192 = %200)
$script:DpiScale = 1.0
try { $script:DpiScale = [DpiHelper]::GetScaleFactor() } catch { }

# ── GLOBAL DEĞİŞKENLER ──
$global:WIMMounted              = $false
$global:StrMountedImageLocation = ""
$global:StrOutput               = ""
$global:StrIndex                = ""
$global:StrWIM                  = ""
$global:PackageNames            = @()   # Package listesi (ListBox için)
$global:IsBusy                  = $false  # İşlem kilidi
$global:SelectedDiskNumber      = $null   # Deploy için seçili disk numarası

class InfosWIM {
    [int]   $Index_Wim
    [string]$Wim_Name
    [string]$Wim_Description
    [uint64]$Wim_Size
}
$global:ListInfosWimMount  = New-Object System.Collections.Generic.List[InfosWIM]
$global:ListInfosWimApply  = New-Object System.Collections.Generic.List[InfosWIM]
$global:ListInfosWimExport = New-Object System.Collections.Generic.List[InfosWIM]
$global:ListInfosWimDelete = New-Object System.Collections.Generic.List[InfosWIM]

# ══════════════════════════════════════════════════════════════════
# ASYNC MİMARİ
#
# Pattern:
#   Start-Job → izole PowerShell process'te DISM çalışır
#   DispatcherTimer (80-300ms) → UI thread'de job çıktısını okur
#   Dispatcher.PushFrame → modal dialog'lar için senkron bekleme
#   __PID__:N  token'ı → iptal için DISM PID'si yakalanır
#   __EXIT__:N token'ı → işlem tamamlandı sinyali
# ══════════════════════════════════════════════════════════════════

$script:VssDismPid      = 0

function Assert-NotBusy {
    if ($global:IsBusy) {
        Write-Log "Meşgul — işlem reddedildi." -Level "WARN"
        Show-Alert -Title "Meşgul" -Message "Şu anda bir işlem devam ediyor. Lütfen bekleyin veya uygulamayı yeniden başlatın."
        return $false
    }
    return $true
}

# ── ANA DISM ÇALIŞTIRICI ──
# Start-Job ile izole process, DispatcherTimer ile UI thread'de polling
function Start-DismJob {
    param(
        [string]      $DismArgs,
        [string]      $StatusMessage = "İşlem devam ediyor...",
        [scriptblock] $OnComplete    = $null,
        [scriptblock] $OnCancel      = $null  # İptal durumunda temizlik callback'i
    )

    if (-not (Assert-NotBusy)) { return }
    $global:IsBusy          = $true
    $global:CancelRequested = $false
    $BtnCancelJob.Visibility = [System.Windows.Visibility]::Visible
    # Kritik işlem sırasında menü ve sayfa alanını kilitle
    $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Visible
    $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Visible
    Update-CaptureForm

    # StatusMessage zaten "...iyor" ile bitiyorsa "başlatılıyor" ekleme
    $startMsg = if ($StatusMessage -match '(yor|ıyor|uyor|üyor)') { 
        $StatusMessage 
    } else { 
        "$StatusMessage başlatılıyor..." 
    }
    Set-Progress -Percent 5 -Message $startMsg
    Write-Log "DISM.EXE $DismArgs" -Level "RUN"

    $script:DismStatus  = $StatusMessage
    $script:DismOnDone  = $OnComplete
    $script:DismOnCancel = $OnCancel  # İptal callback'ini kaydet

    $dismArgsCopy = $DismArgs

    $script:DismJob = Start-Job -ScriptBlock {
        param($dismCmd)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = "DISM.EXE"
        $psi.Arguments              = $dismCmd
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $proc.Start() | Out-Null
        
        # PID'yi output'a yaz (ilk satır)
        Write-Output "__PID__:$($proc.Id)"
        
        while (-not $proc.StandardOutput.EndOfStream) {
            $line = $proc.StandardOutput.ReadLine()
            if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Output $line.Trim() }
        }
        $errTxt = $proc.StandardError.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($errTxt)) {
            foreach ($el in ($errTxt -split "`n")) {
                if (-not [string]::IsNullOrWhiteSpace($el)) { Write-Output "[ERR] $($el.Trim())" }
            }
        }
        $proc.WaitForExit()
        Write-Output "__EXIT__:$($proc.ExitCode)"
    } -ArgumentList $dismArgsCopy

    $script:DismTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:DismTimer.Interval = [TimeSpan]::FromMilliseconds(80)
    $script:DismTimer.Add_Tick({
        $lines = $script:DismJob | Receive-Job
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            
            # PID'yi yakala
            if ($line.StartsWith("__PID__:")) {
                $script:DismPid = [int]($line.Substring(8))
                Write-Log "DISM başlatıldı (PID: $($script:DismPid))" -Level "INFO"
                continue
            }

            if ($line.StartsWith("__EXIT__:")) {
                $script:DismTimer.Stop()
                $ec = [int]($line.Substring(9))
                Remove-Job -Job $script:DismJob -Force -ErrorAction SilentlyContinue
                $BtnCancelJob.Visibility = [System.Windows.Visibility]::Collapsed
                # İşlem bitti — overlay kilitleri kaldır
                $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Collapsed
                $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Collapsed
                if ($global:CancelRequested) {
                    Write-Log "İşlem iptal edildi" -Level "WARN"
                    Set-Progress -Percent 0 -Message "İptal edildi."
                    # İptal callback'ini çalıştır (temp dosya temizliği vs.)
                    if ($null -ne $script:DismOnCancel) { 
                        & $script:DismOnCancel 
                    }
                } elseif ($ec -eq 0) {
                    # Başarılı - sadece ilgili durumlarda log yaz
                    Set-Progress -Percent 100 -Message "Tamamlandı."
                } else {
                    Write-Log "DISM hatası (kod: $ec)" -Level "ERR"
                    Set-Progress -Percent 0 -Message "Hata (kod: $ec)"
                }
                Start-Sleep -Milliseconds 400
                Set-Progress -Percent 0 -Message "Sistem Hazır."
                $wasCancelled           = $global:CancelRequested
                $global:IsBusy          = $false
                $global:CancelRequested = $false
                $script:DismPid         = 0
                Update-CaptureForm
                if ($null -ne $script:DismOnDone -and -not $wasCancelled) { & $script:DismOnDone $ec }
                return
            }

            # DISM çıktı formatı: "[===  ] 40.0%" veya "[ 10%]" veya "10%"
            $pct = -1
            if ($line -match "(\d+(?:\.\d+)?)\s*%") {
                $pct = [int][Math]::Floor([double]$Matches[1])
            }

            $global:_Console.AppendText("`r`n  $line")
            $global:_Console.ScrollToEnd()

            if ($pct -ge 0 -and $pct -le 100) {
                $global:_PBar.Value    = $pct
                $global:_PctLbl.Text   = "$pct%"
                $global:_MsgLbl.Text   = "$script:DismStatus $pct%"

                # Mount rozeti renk animasyonu — yüzdeye göre sarıdan maviye geçiş
                if ($null -ne $script:MountingItem) {
                    $script:MountingItem.MountStatus = "$pct%"
                    # 0% → #F59E0B (sarı/turuncu)  →  50% → #3B82F6 (mavi)  →  100% → #16A34A (yeşil)
                    if ($pct -lt 50) {
                        # Sarı → Mavi geçişi
                        $r = [int](245 - ($pct / 50.0) * (245 - 59))
                        $g = [int](158 - ($pct / 50.0) * (158 - 130))
                        $b = [int](11  + ($pct / 50.0) * (246 - 11))
                    } else {
                        # Mavi → Yeşil geçişi
                        $t = ($pct - 50) / 50.0
                        $r = [int](59  + $t * (22  - 59))
                        $g = [int](130 + $t * (163 - 130))
                        $b = [int](246 + $t * (74  - 246))
                    }
                    $script:MountingItem.MountStatusColor = "#{0:X2}{1:X2}{2:X2}" -f $r, $g, $b
                    $ListViewMountIndex.Items.Refresh()
                }
            }
        }
    })
    $script:DismTimer.Start()
}


# ── WIM ANALİZİ ──
# PowerShell Job + DispatcherTimer — en kararlı cross-thread yöntem
function Start-WimAnalysis {
    param(
        [string]$Path,
        [System.Windows.Controls.ComboBox]$TargetCombo,
        $TargetList,
        [scriptblock]$OnComplete = $null
    )
    $global:IsBusy = $true
    Set-Progress -Percent 10 -Message "WIM analiz ediliyor..."

    # PowerShell Job — tamamen izole process, crash window'u etkilemez
    $script:WimJob    = Start-Job -ScriptBlock {
        param($p)
        try {
            Import-Module DISM -ErrorAction SilentlyContinue
            Write-Output "__PROGRESS__:WIM okunuyor..."
            $imgs = Get-WindowsImage -ImagePath $p
            $out  = @()
            foreach ($img in $imgs) {
                $out += "$($img.ImageIndex)|$($img.ImageName)|$($img.ImageDescription)|$($img.ImageSize)"
            }
            return $out
        } catch {
            return "__ERR__:$($_.Exception.Message)"
        }
    } -ArgumentList $Path

    $script:WimCombo  = $TargetCombo
    $script:WimList   = $TargetList
    $script:WimOnDone = $OnComplete

    $script:WimTimer  = New-Object System.Windows.Threading.DispatcherTimer
    $script:WimTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:WimTimer.Add_Tick({
        $job = $script:WimJob

        # Job çalışırken progress token'larını -Keep ile oku (consume etme)
        if ($job.State -notin @('Completed','Failed','Stopped')) {
            $partial = @(Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue)
            foreach ($p in $partial) {
                if ($p -is [string] -and $p.StartsWith("__PROGRESS__:")) {
                    $LblProgressMsg.Text = $p.Substring(13)
                }
            }
            return
        }

        $script:WimTimer.Stop()

        try {
            # Job bitti — tüm çıktıyı tek seferde al (consume)
            $results = @(Receive-Job -Job $job -ErrorAction Stop)
            Remove-Job -Job $job -Force

            # __PROGRESS__ token'larını filtrele, geri kalanı gerçek veri
            $results = $results | Where-Object { $_ -notmatch '^__PROGRESS__:' }

            if ($results.Count -eq 1 -and $results[0] -is [string] -and $results[0].StartsWith("__ERR__:")) {
                Write-Log "WIM okunamadı: $($results[0].Substring(8))" -Level "ERR"
                $global:IsBusy = $false
                Set-Progress -Percent 0 -Message "Hata."
                return
            }

            $script:WimList.Clear()
            $script:WimCombo.Items.Clear()

            foreach ($row in $results) {
                if ([string]::IsNullOrWhiteSpace($row)) { continue }
                $parts = $row -split "\|", 4
                if ($parts.Count -lt 2) { continue }
                $entry = [InfosWIM]::new()
                $entry.Index_Wim       = [int]$parts[0]
                $entry.Wim_Name        = $parts[1]
                $entry.Wim_Description = if ($parts.Count -gt 2) { $parts[2] } else { "" }
                $entry.Wim_Size        = if ($parts.Count -gt 3 -and $parts[3] -match "^\d+$") { [uint64]$parts[3] } else { 0 }
                $script:WimList.Add($entry)
                $script:WimCombo.Items.Add("$($entry.Index_Wim) - $($entry.Wim_Name)") | Out-Null
            }

            if ($script:WimCombo.Items.Count -gt 0) { $script:WimCombo.SelectedIndex = 0 }
            if ($script:WimList.Count -gt 1) {
                Write-Log "$($script:WimList.Count) indeks bulundu" -Level "OK"
            }
        } catch {
            Write-Log "WIM analiz hatası: $($_.Exception.Message)" -Level "ERR"
        } finally {
            $global:IsBusy = $false
            Set-Progress -Percent 0 -Message "Sistem Hazır."
            if ($null -ne $script:WimOnDone) { & $script:WimOnDone }
        }
    })
    $script:WimTimer.Start()
}



# ── DOSYA SEÇİCİ (WPF Native - Microsoft.Win32) ──
function Select-File {
    param([string]$Filter = "Tüm Dosyalar (*.*)|*.*", [string]$Title = "Dosya Seç")
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    # WPF filtresi "Ad|*.ext" formatında
    $dlg.Filter = $Filter
    $dlg.Title  = $Title
    $result = $dlg.ShowDialog($window)
    if ($result -eq $true) { return $dlg.FileName }
    return ""
}

# ── DOSYA KAYDET SEÇİCİ (WPF Native) ──
function Select-SaveFile {
    param([string]$Filter = "Tüm Dosyalar (*.*)|*.*", [string]$Title = "Dosyayı Kaydet")
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = $Filter
    $dlg.Title  = $Title
    $result = $dlg.ShowDialog($window)
    if ($result -eq $true) { return $dlg.FileName }
    return ""
}

# ── KLASÖR SEÇİCİ ──
# Shell COM nesnesiyle modern klasör dialog'u
function Select-Folder {
    param([string]$Description = "Klasör Seçin", [string]$InitialPath = "")
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description  = $Description
    $dlg.ShowNewFolderButton = $true
    if ($InitialPath -ne "" -and (Test-Path $InitialPath)) {
        $dlg.SelectedPath = $InitialPath
    }
    # WPF pencere handle'ını al (dialog owner için)
    $hwnd = New-Object System.Windows.Interop.WindowInteropHelper($window)
    $owner = New-Object System.Windows.Forms.NativeWindow
    $owner.AssignHandle($hwnd.Handle)
    $result = $dlg.ShowDialog($owner)
    $owner.ReleaseHandle()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dlg.SelectedPath
    }
    return ""
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        xmlns:options="http://schemas.microsoft.com/winfx/2006/xaml/presentation/options"
        Title="WinImage Studio" Height="800" Width="1100" MinWidth="860" MinHeight="500"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="Manual"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType"
        RenderOptions.BitmapScalingMode="HighQuality"
        RenderOptions.ClearTypeHint="Enabled">

    <shell:WindowChrome.WindowChrome>
        <shell:WindowChrome CaptionHeight="0" ResizeBorderThickness="8" GlassFrameThickness="0" CornerRadius="8"/>
    </shell:WindowChrome.WindowChrome>

    <Window.Resources>
        <Style TargetType="{x:Type ScrollBar}">
            <Setter Property="Width" Value="4"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ScrollBar}">
                        <Grid Background="Transparent">
                            <Track x:Name="PART_Track" IsDirectionReversed="true" Margin="0,4,0,4">
                                <Track.Thumb>
                                    <Thumb>
                                        <Thumb.Template>
                                            <ControlTemplate TargetType="Thumb">
                                                <Border x:Name="ThumbBorder" CornerRadius="2" Background="#9CA3AF" Opacity="0.3" Margin="0"/>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ThumbBorder" Property="Opacity" Value="0.7"/></Trigger>
                                                    <Trigger Property="IsDragging"  Value="True"><Setter TargetName="ThumbBorder" Property="Opacity" Value="0.9"/></Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Thumb.Template>
                                    </Thumb>
                                </Track.Thumb>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="RndTxt" TargetType="TextBox">
            <Setter Property="Height" Value="22"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Padding" Value="5,0"/>
            <Setter Property="Foreground" Value="#111827"/>
            <Setter Property="Background" Value="#F9FAFB"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border CornerRadius="3" BorderBrush="#D1D5DB" BorderThickness="1" Background="{TemplateBinding Background}">
                            <Grid>
                                <TextBlock x:Name="PlaceholderText" Text="{TemplateBinding Tag}" Foreground="#9CA3AF" FontStyle="Italic"
                                           Padding="6,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False" Visibility="Collapsed"/>
                                <ScrollViewer x:Name="PART_ContentHost" Background="Transparent"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="Text" Value=""><Setter TargetName="PlaceholderText" Property="Visibility" Value="Visible"/></Trigger>
                            <Trigger Property="Text" Value="{x:Null}"><Setter TargetName="PlaceholderText" Property="Visibility" Value="Visible"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="RndProgress" TargetType="ProgressBar">
            <Setter Property="Height" Value="6"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Border Background="#E5E7EB" CornerRadius="3" ClipToBounds="True">
                            <Border x:Name="PART_Indicator" Background="#4A6278" CornerRadius="3" HorizontalAlignment="Left"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BtnOutline" TargetType="Button">
            <Setter Property="Background" Value="White"/>
            <Setter Property="Foreground" Value="#111827"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Height" Value="24"/>
            <Setter Property="Padding" Value="10,0"/>
            <Setter Property="Margin" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border CornerRadius="4" BorderBrush="#D1D5DB" BorderThickness="1" Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#F3F4F6"/></Trigger></Style.Triggers>
        </Style>

        <Style x:Key="BtnSolidClassic" TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Height" Value="24"/>
            <Setter Property="Padding" Value="10,0"/>
            <Setter Property="Margin" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border CornerRadius="4" BorderThickness="0" Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter Property="Opacity" Value="0.85"/></Trigger>
                            <Trigger Property="IsPressed"   Value="True"><Setter Property="Opacity" Value="0.70"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BtnAccent"  BasedOn="{StaticResource BtnSolidClassic}" TargetType="Button"><Setter Property="Background" Value="#4A6278"/></Style>
        <Style x:Key="BtnDanger"  BasedOn="{StaticResource BtnSolidClassic}" TargetType="Button"><Setter Property="Background" Value="#37474F"/></Style>
        <Style x:Key="BtnRed"     BasedOn="{StaticResource BtnSolidClassic}" TargetType="Button"><Setter Property="Background" Value="#B91C1C"/></Style>
        <Style x:Key="BtnGreen"   BasedOn="{StaticResource BtnSolidClassic}" TargetType="Button"><Setter Property="Background" Value="#4E6E52"/></Style>

        <Style x:Key="CardStyle" TargetType="Border">
            <Setter Property="Background"        Value="White"/>
            <Setter Property="CornerRadius"      Value="6"/>
            <Setter Property="BorderBrush"       Value="#E5E7EB"/>
            <Setter Property="BorderThickness"   Value="1"/>
            <Setter Property="Padding"           Value="10"/>
            <Setter Property="Margin"            Value="0,0,0,10"/>
        </Style>
        <Style x:Key="CardTitle" TargetType="TextBlock">
            <Setter Property="Foreground"  Value="#6B7280"/>
            <Setter Property="FontSize"    Value="10"/>
            <Setter Property="FontWeight"  Value="Bold"/>
            <Setter Property="Margin"      Value="0,0,0,8"/>
        </Style>

        <Style x:Key="WinBtn" TargetType="Button">
            <Setter Property="Width"  Value="12"/><Setter Property="Height" Value="12"/>
            <Setter Property="Cursor" Value="Arrow"/>
            <Setter Property="Template">
                <Setter.Value><ControlTemplate TargetType="Button"><Ellipse Fill="{TemplateBinding Background}"/></ControlTemplate></Setter.Value>
            </Setter>
            <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Opacity" Value="0.7"/></Trigger></Style.Triggers>
        </Style>

        <Style x:Key="MenuBtn" TargetType="RadioButton">
            <Setter Property="Foreground" Value="#8EB4D8"/>
            <Setter Property="Cursor"     Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Border x:Name="BgBorder" Background="Transparent" Padding="12,6,0,6">
                            <Grid>
                                <Rectangle x:Name="ActiveLine" Width="3" Fill="White" HorizontalAlignment="Left" Visibility="Hidden" Margin="-12,-6,0,-6"/>
                                <ContentPresenter TextElement.Foreground="{TemplateBinding Foreground}"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="BgBorder" Property="Background" Value="#263F63"/></Trigger>
                            <Trigger Property="IsChecked"   Value="True">
                                <Setter TargetName="BgBorder"   Property="Background"  Value="#2A4A7A"/>
                                <Setter Property="Foreground"                            Value="White"/>
                                <Setter TargetName="ActiveLine" Property="Visibility"  Value="Visible"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
        <Border x:Name="MainBorder" CornerRadius="8" Background="#F3F4F6" BorderBrush="#D1D5DB" BorderThickness="1" ClipToBounds="True">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="160"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <Border x:Name="SidebarBorder" Grid.Column="0" Background="#1E3250" CornerRadius="7,0,0,7">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="50"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="40"/>
                        </Grid.RowDefinitions>

                        <StackPanel Grid.Row="0" Margin="12,8,0,0">
                            <TextBlock Text="WinImage Studio" Foreground="White"    FontSize="14" FontWeight="Bold"/>
                            <TextBlock Text="v1.0"            Foreground="#8EB4D8"  FontSize="9"/>
                        </StackPanel>
                        <Separator Grid.Row="0" VerticalAlignment="Bottom" Background="#264067" Margin="0" Height="1"/>

                        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                            <StackPanel Margin="0,8,0,0">
                                <TextBlock Text="GÖRÜNTÜ VE DAĞITIM (IMAGING)" Foreground="#5A86B5" FontSize="8" FontWeight="Bold" Margin="12,0,0,4"/>
                                <RadioButton x:Name="Nav_0" GroupName="M" IsChecked="True" Style="{StaticResource MenuBtn}">
                                    <StackPanel><TextBlock Text="Mount Workspace"      FontSize="11" FontWeight="SemiBold"/><TextBlock Text="İmaj Bağlama ve Yönetim" FontSize="8" Foreground="#8EB4D8"/></StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="Nav_6" GroupName="M" Style="{StaticResource MenuBtn}">
                                    <StackPanel><TextBlock Text="Capture OS Image"     FontSize="11" FontWeight="SemiBold"/><TextBlock Text="Referans İmaj Yakalama"  FontSize="8" Foreground="#8EB4D8"/></StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="Nav_7" GroupName="M" Style="{StaticResource MenuBtn}">
                                    <StackPanel><TextBlock Text="Deploy OS Image"      FontSize="11" FontWeight="SemiBold"/><TextBlock Text="Hedef Diske Dağıtım"     FontSize="8" Foreground="#8EB4D8"/></StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="Nav_8" GroupName="M" Style="{StaticResource MenuBtn}">
                                    <StackPanel><TextBlock Text="Export &amp; Consolidate" FontSize="11" FontWeight="SemiBold"/><TextBlock Text="İndeks Birleştirme/Aktarma" FontSize="8" Foreground="#8EB4D8"/></StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="Nav_9" GroupName="M" Style="{StaticResource MenuBtn}">
                                    <StackPanel><TextBlock Text="Split Media (SWM)"    FontSize="11" FontWeight="SemiBold"/><TextBlock Text="Medya İçin Parçalama"    FontSize="8" Foreground="#8EB4D8"/></StackPanel>
                                </RadioButton>

                                <TextBlock Text="BİLEŞEN SERVİSLERİ (SERVICING)" Foreground="#5A86B5" FontSize="8" FontWeight="Bold" Margin="12,12,0,4"/>
                                <RadioButton x:Name="Nav_1" GroupName="M" Style="{StaticResource MenuBtn}">
                                    <StackPanel><TextBlock Text="Driver Servicing"    FontSize="11" FontWeight="SemiBold"/><TextBlock Text="Sürücü Entegrasyonu"     FontSize="8" Foreground="#8EB4D8"/></StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="Nav_2" GroupName="M" Style="{StaticResource MenuBtn}">
                                    <StackPanel><TextBlock Text="Package Servicing"   FontSize="11" FontWeight="SemiBold"/><TextBlock Text="MSU/CAB Paket Yönetimi"  FontSize="8" Foreground="#8EB4D8"/></StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="Nav_3" GroupName="M" Style="{StaticResource MenuBtn}">
                                    <StackPanel><TextBlock Text="Features on Demand"  FontSize="11" FontWeight="SemiBold"/><TextBlock Text="İsteğe Bağlı Özellikler"  FontSize="8" Foreground="#8EB4D8"/></StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="Nav_14" GroupName="M" Style="{StaticResource MenuBtn}">
                                    <StackPanel><TextBlock Text="Offline Registry"    FontSize="11" FontWeight="SemiBold"/><TextBlock Text="Kayıt Defteri Düzenleme"  FontSize="8" Foreground="#8EB4D8"/></StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="Nav_4" GroupName="M" Style="{StaticResource MenuBtn}">
                                    <StackPanel><TextBlock Text="Edition Management"  FontSize="11" FontWeight="SemiBold"/><TextBlock Text="Sürüm ve Lisans Yönetimi" FontSize="8" Foreground="#8EB4D8"/></StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="Nav_10" GroupName="M" Style="{StaticResource MenuBtn}">
                                    <StackPanel><TextBlock Text="Regional Settings"   FontSize="11" FontWeight="SemiBold"/><TextBlock Text="Dil ve Bölge Paketleri"   FontSize="8" Foreground="#8EB4D8"/></StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="Nav_5" GroupName="M" Style="{StaticResource MenuBtn}">
                                    <StackPanel><TextBlock Text="Automated Setup"     FontSize="11" FontWeight="SemiBold"/><TextBlock Text="Unattend.xml Yapılandırması" FontSize="8" Foreground="#8EB4D8"/></StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="Nav_11" GroupName="M" Style="{StaticResource MenuBtn}">
                                    <StackPanel><TextBlock Text="FFU Storage Flash"   FontSize="11" FontWeight="SemiBold"/><TextBlock Text="Sektör Bazlı İmaj İşlemleri" FontSize="8" Foreground="#8EB4D8"/></StackPanel>
                                </RadioButton>

                                <TextBlock Text="MODERN UYGULAMA DAĞITIMI" Foreground="#5A86B5" FontSize="8" FontWeight="Bold" Margin="12,12,0,4"/>
                                <RadioButton x:Name="Nav_12" GroupName="M" Style="{StaticResource MenuBtn}">
                                    <StackPanel><TextBlock Text="Store Package Fetcher" FontSize="11" FontWeight="SemiBold"/><TextBlock Text="Appx/Msix İndirme Servisi" FontSize="8" Foreground="#8EB4D8"/></StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="Nav_13" GroupName="M" Style="{StaticResource MenuBtn}">
                                    <StackPanel><TextBlock Text="Offline Provisioning"  FontSize="11" FontWeight="SemiBold"/><TextBlock Text="Çevrimdışı App Entegrasyonu" FontSize="8" Foreground="#8EB4D8"/></StackPanel>
                                </RadioButton>
                            </StackPanel>
                        </ScrollViewer>

                        <Border x:Name="SidebarBottomBorder" Grid.Row="2" Background="#162640" CornerRadius="0,0,0,7">
                            <StackPanel Margin="12,6,0,0">
                                <TextBlock x:Name="TxtTrustedInstaller" Text="TrustedInstaller" Foreground="#8EB4D8" FontSize="9" Cursor="Hand"/>
                                <TextBlock x:Name="TxtDismLog"          Text="DISM Log"         Foreground="#8EB4D8" FontSize="9" Margin="0,3,0,0" Cursor="Hand"/>
                            </StackPanel>
                        </Border>
                    </Grid>
                </Border>

                <Border x:Name="BusyOverlayMenu" Grid.Column="0" Visibility="Collapsed"
                        Background="#01000000" Panel.ZIndex="50" IsHitTestVisible="True"
                        CornerRadius="7,0,0,7"/>

                <Grid Grid.Column="1">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="26"/>
                        <RowDefinition Height="3*" MinHeight="120"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*" MinHeight="80"/>
                        <RowDefinition Height="22"/>
                    </Grid.RowDefinitions>

                    <Grid Grid.Row="0">
                        <Border x:Name="DragBar" Background="Transparent" Cursor="SizeAll"/>
                        <Border HorizontalAlignment="Right" Background="Transparent" Cursor="Arrow" Padding="20,0,12,0">
                            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                <Button x:Name="BtnMin"   Style="{StaticResource WinBtn}" Background="#FFBD2E" Margin="0,0,6,0" ToolTip="Küçült"/>
                                <Button x:Name="BtnMax"   Style="{StaticResource WinBtn}" Background="#27C93F" Margin="0,0,6,0" ToolTip="Tam Ekran"/>
                                <Button x:Name="BtnClose" Style="{StaticResource WinBtn}" Background="#FF5F56" ToolTip="Kapat"/>
                            </StackPanel>
                        </Border>
                    </Grid>

                    <Grid Grid.Row="1" Margin="15,0,15,8">

                        <Border x:Name="BusyOverlayContent" Visibility="Collapsed"
                                Background="#01000000" Panel.ZIndex="50" IsHitTestVisible="True"/>

                        <Grid x:Name="Pg_0" Visibility="Visible">
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                            <TextBlock Text="Mount Workspace" FontSize="16" FontWeight="Bold" Margin="0,0,0,10" Foreground="#111827"/>
                            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                <StackPanel>
                                    <Border Style="{StaticResource CardStyle}" Padding="10,10,10,12">
                                        <StackPanel>
                                            <TextBlock Text="GÖRÜNTÜ DOSYASI" Style="{StaticResource CardTitle}"/>
                                            <Grid Margin="0,0,0,8">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="85"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Text="WIM/ESD:" VerticalAlignment="Center" FontSize="11"/>
                                                <TextBox x:Name="TxtWimFile" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Gözat ile işlenecek .wim veya .esd dosyasını seçin..."/>
                                                <Button x:Name="BtnChooseWim" Grid.Column="2" Content="Seç" Style="{StaticResource BtnOutline}" Margin="6,0,0,0" Height="22"/>
                                            </Grid>
                                            <Grid>
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="85"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Text="Mount Dizin:" VerticalAlignment="Center" FontSize="11"/>
                                                <TextBox x:Name="TxtMountFolder" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="İmajın klasör olarak açılacağı boş dizini belirtin..."/>
                                                <Button x:Name="BtnChooseFolder" Grid.Column="2" Content="Seç" Style="{StaticResource BtnOutline}" Margin="6,0,0,0" Height="22"/>
                                            </Grid>
                                        </StackPanel>
                                    </Border>
                                    
                                    <Border Style="{StaticResource CardStyle}">
                                        <StackPanel>
                                            <TextBlock Text="INDEX &amp; SEÇENEKLER" Style="{StaticResource CardTitle}"/>
                                            <TextBlock Text="Index:" FontSize="11" Margin="0,0,0,4"/>
                                            <Border BorderBrush="#D1D5DB" BorderThickness="1" Background="White" CornerRadius="6" Height="160" Margin="0,0,0,6">
                                                    <Grid>
                                                        <Grid.RowDefinitions>
                                                            <RowDefinition Height="Auto"/>
                                                            <RowDefinition Height="*"/>
                                                        </Grid.RowDefinitions>
                                                        
                                                        <Border Grid.Row="0" Background="#F9FAFB" BorderBrush="#E5E7EB" BorderThickness="0,0,0,1" Padding="8,6">
                                                            <Grid>
                                                                <Grid.ColumnDefinitions>
                                                                    <ColumnDefinition Width="28"/>
                                                                    <ColumnDefinition Width="160"/>
                                                                    <ColumnDefinition Width="*"/>
                                                                    <ColumnDefinition Width="46"/>
                                                                    <ColumnDefinition Width="54"/>
                                                                    <ColumnDefinition Width="74"/>
                                                                    <ColumnDefinition Width="60"/>
                                                                    <ColumnDefinition Width="76"/>
                                                                </Grid.ColumnDefinitions>
                                                                <TextBlock Grid.Column="0" Text="#"         FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                                <TextBlock Grid.Column="1" Text="Index Adı"  FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                                <TextBlock Grid.Column="2" Text="Açıklama"   FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                                <TextBlock Grid.Column="3" Text="Mimari"     FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                                <TextBlock Grid.Column="4" Text="Diller"     FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                                <TextBlock Grid.Column="5" Text="Oluşturma"  FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                                <TextBlock Grid.Column="6" Text="Boyut"      FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center" TextAlignment="Right"/>
                                                                <TextBlock Grid.Column="7" Text="Durum"      FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center" TextAlignment="Center"/>
                                                            </Grid>
                                                        </Border>
                                                        
                                                        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                                            <ListView x:Name="ListViewMountIndex" BorderThickness="0" Background="Transparent" Padding="0" SelectionMode="Single">
                                                                <ListView.ItemContainerStyle>
                                                                    <Style TargetType="ListViewItem">
                                                                        <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                                                                        <Setter Property="Padding" Value="0"/>
                                                                        <Setter Property="Margin" Value="0"/>
                                                                        <Setter Property="BorderThickness" Value="0"/>
                                                                        <Style.Triggers>
                                                                            <Trigger Property="IsSelected" Value="True">
                                                                                <Setter Property="Background" Value="#DBEAFE"/>
                                                                                <Setter Property="Foreground" Value="#1E40AF"/>
                                                                            </Trigger>
                                                                            <Trigger Property="IsMouseOver" Value="True">
                                                                                <Setter Property="Background" Value="#F3F4F6"/>
                                                                            </Trigger>
                                                                        </Style.Triggers>
                                                                    </Style>
                                                                </ListView.ItemContainerStyle>
                                                                <ListView.ItemTemplate>
                                                                    <DataTemplate>
                                                                        <Border Padding="8,3" BorderBrush="#F3F4F6" BorderThickness="0,0,0,1">
                                                                            <Grid>
                                                                                <Grid.ColumnDefinitions>
                                                                                    <ColumnDefinition Width="28"/>
                                                                                    <ColumnDefinition Width="160"/>
                                                                                    <ColumnDefinition Width="*"/>
                                                                                    <ColumnDefinition Width="46"/>
                                                                                    <ColumnDefinition Width="54"/>
                                                                                    <ColumnDefinition Width="74"/>
                                                                                    <ColumnDefinition Width="60"/>
                                                                                    <ColumnDefinition Width="76"/>
                                                                                </Grid.ColumnDefinitions>

                                                                                <TextBlock Grid.Column="0" Text="{Binding IndexNumber}" FontWeight="SemiBold"
                                                                                           Foreground="#3B82F6" FontSize="11" VerticalAlignment="Center"/>

                                                                                <TextBlock Grid.Column="1" Text="{Binding IndexName}" FontWeight="Medium"
                                                                                           FontSize="11" Foreground="#111827" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>

                                                                                <TextBlock Grid.Column="2" Text="{Binding Description}" FontSize="10"
                                                                                           Foreground="#6B7280" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>

                                                                                <TextBlock Grid.Column="3" Text="{Binding Architecture}" FontSize="10"
                                                                                           Foreground="#6B7280" VerticalAlignment="Center"/>

                                                                                <TextBlock Grid.Column="4" Text="{Binding Languages}" FontSize="10"
                                                                                           Foreground="#6B7280" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>

                                                                                <TextBlock Grid.Column="5" Text="{Binding CreatedDate}" FontSize="10"
                                                                                           Foreground="#6B7280" VerticalAlignment="Center"/>

                                                                                <TextBlock Grid.Column="6" Text="{Binding Size}" FontSize="10"
                                                                                           Foreground="#6B7280" VerticalAlignment="Center" TextAlignment="Right"/>

                                                                                <Border Grid.Column="7" HorizontalAlignment="Right" VerticalAlignment="Center"
                                                                                        Background="{Binding MountStatusColor}" CornerRadius="4" Padding="7,2" Margin="4,0,2,0">
                                                                                    <TextBlock Text="{Binding MountStatus}" FontSize="9" FontWeight="Bold"
                                                                                               Foreground="White" VerticalAlignment="Center"/>
                                                                                </Border>
                                                                            </Grid>
                                                                        </Border>
                                                                    </DataTemplate>
                                                                </ListView.ItemTemplate>
                                                            </ListView>
                                                        </ScrollViewer>
                                                    </Grid>
                                                </Border>

                                            <Border Background="#FFFBEB" BorderBrush="#FCD34D" BorderThickness="1" CornerRadius="5" Padding="10,6" Margin="0,0,0,6">
                                                <Grid>
                                                    <Grid.ColumnDefinitions>
                                                        <ColumnDefinition Width="*"/>
                                                        <ColumnDefinition Width="*"/>
                                                    </Grid.ColumnDefinitions>
                                                    <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                                                        <CheckBox x:Name="ChkReadOnly" Margin="0,0,8,0" VerticalAlignment="Center"/>
                                                        <TextBlock Text="Salt Okunur Bağla" FontSize="11" FontWeight="SemiBold" Foreground="#374151" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                                        <TextBlock Text="⚠ İmaj değiştirilmez, sadece görüntülenir" FontSize="9" Foreground="#B45309" VerticalAlignment="Center"/>
                                                    </StackPanel>
                                                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                                                        <CheckBox x:Name="ChkRemoveReadOnly" Margin="0,0,8,0" VerticalAlignment="Center"/>
                                                        <TextBlock Text="Yazma Korumasını Kaldır" FontSize="11" FontWeight="SemiBold" Foreground="#374151" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                                        <TextBlock Text="⚠ Dosyanın salt-okunur özelliğini siler" FontSize="9" Foreground="#B45309" VerticalAlignment="Center"/>
                                                    </StackPanel>
                                                </Grid>
                                            </Border>
                                        </StackPanel>
                                    </Border>

                                    <Border Background="White" CornerRadius="6" BorderBrush="#E5E7EB" BorderThickness="1" Padding="10,8,10,8" Margin="0,0,0,10">
                                        <Grid>
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="*"/>
                                            </Grid.ColumnDefinitions>
                                            <Button x:Name="BtnMountWim"       Grid.Column="0" Content="&#x25B6;  Bağla"               Style="{StaticResource BtnAccent}"  Margin="0,0,5,0" Height="30" Padding="0"/>
                                            <Button x:Name="BtnUnmountSave"    Grid.Column="1" Content="&#x2713;  Kaydet &amp; Çık"     Style="{StaticResource BtnGreen}"   Margin="0,0,5,0" Height="30" Padding="0"/>
                                            <Button x:Name="BtnUnmountDiscard" Grid.Column="2" Content="&#x2715;  İptal &amp; Çık"      Style="{StaticResource BtnDanger}"  Margin="0,0,5,0" Height="30" Padding="0"/>
                                            <Button x:Name="BtnOpenFolder"     Grid.Column="3" Content="&#x25A1;  Klasör Aç"            Style="{StaticResource BtnOutline}" Margin="0,0,5,0" Height="30" Padding="0"/>
                                            <Button x:Name="BtnCleanupWim"     Grid.Column="4" Content="&#x2605;  Temizlik"             Style="{StaticResource BtnOutline}" Margin="0"       Height="30" Padding="0"/>
                                        </Grid>
                                    </Border>

                                    <Border Style="{StaticResource CardStyle}" Margin="0,4,0,0">
                                        <StackPanel>
                                            <TextBlock Text="WIM BİLGİSİ" Style="{StaticResource CardTitle}"/>
                                            <Grid>
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="85"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock Text="Adı:" VerticalAlignment="Center" FontSize="11"/>
                                                <TextBox x:Name="TxtWimName" Grid.Column="1" Style="{StaticResource RndTxt}" IsReadOnly="True" Background="#F3F4F6"/>
                                            </Grid>
                                            <Grid Margin="0,4,0,0">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="85"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock Text="Açıklama:" VerticalAlignment="Center" FontSize="11"/>
                                                <TextBox x:Name="TxtWimDesc" Grid.Column="1" Style="{StaticResource RndTxt}" IsReadOnly="True" Background="#F3F4F6"/>
                                            </Grid>
                                        </StackPanel>
                                    </Border>
                                </StackPanel>
                            </ScrollViewer>
                        </Grid>

                        <Grid x:Name="Pg_1" Visibility="Collapsed">
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                            <TextBlock Text="Driver Servicing" FontSize="16" FontWeight="Bold" Margin="0,0,0,10" Foreground="#111827"/>
                            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                <StackPanel>
                                    <Border Style="{StaticResource CardStyle}">
                                        <Grid>
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="170"/>
                                            </Grid.ColumnDefinitions>
                                            
                                            <StackPanel Grid.Column="0">
                                                <TextBlock Text="SÜRÜCÜ YÖNETİMİ" Style="{StaticResource CardTitle}"/>
                                                
                                                <TextBlock Text="Image'e Sürücü Yükle" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,6" Foreground="#374151"/>
                                                <Grid Margin="0,0,0,12">
                                                    <Grid.ColumnDefinitions>
                                                        <ColumnDefinition Width="80"/>
                                                        <ColumnDefinition Width="*"/>
                                                        <ColumnDefinition Width="Auto"/>
                                                    </Grid.ColumnDefinitions>
                                                    <TextBlock Text="Kaynak:" VerticalAlignment="Center" FontSize="11" Foreground="#6B7280"/>
                                                    <TextBox x:Name="TxtDriverFolder" Grid.Column="1" Style="{StaticResource RndTxt}" 
                                                             Tag="Sürücü klasörünü seçin (.inf dosyaları)"/>
                                                    <Button x:Name="BtnChooseDriverFolder" Grid.Column="2" Content="Gözat..." 
                                                            Style="{StaticResource BtnOutline}" Margin="6,0,0,0" Height="22" Padding="12,0"/>
                                                </Grid>
                                                <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                                    <CheckBox x:Name="ChkRecurse" Content="Alt klasörleri tara (/Recurse)" Margin="0,0,20,0" FontSize="10"/>
                                                    <CheckBox x:Name="ChkForceUnsigned" Content="İmzasız sürücülere izin ver (/ForceUnsigned)" FontSize="10"/>
                                                </StackPanel>
                                                
                                                <Border Height="1" Background="#E5E7EB" Margin="0,0,0,12"/>
                                                
                                                <Border BorderBrush="#D1D5DB" BorderThickness="1" Background="White" CornerRadius="6" Height="240">
                                                    <Grid>
                                                        <Grid.RowDefinitions>
                                                            <RowDefinition Height="Auto"/>
                                                            <RowDefinition Height="*"/>
                                                        </Grid.RowDefinitions>
                                                        
                                                        <Border Grid.Row="0" Background="#F9FAFB" BorderBrush="#E5E7EB" BorderThickness="0,0,0,1">
                                                            <Grid>
                                                                <Grid.RowDefinitions>
                                                                    <RowDefinition Height="Auto"/>
                                                                    <RowDefinition Height="Auto"/>
                                                                </Grid.RowDefinitions>
                                                                
                                                                <Grid Grid.Row="0" Margin="8,6,8,4">
                                                                    <Grid.ColumnDefinitions>
                                                                        <ColumnDefinition Width="35"/>
                                                                        <ColumnDefinition Width="110"/>
                                                                        <ColumnDefinition Width="*"/>
                                                                        <ColumnDefinition Width="90"/>
                                                                        <ColumnDefinition Width="75"/>
                                                                    </Grid.ColumnDefinitions>
                                                                    <CheckBox x:Name="ChkSelectAllDrivers" Grid.Column="0" VerticalAlignment="Center"/>
                                                                    <TextBlock Grid.Column="1" Text="Dosya Adı" FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                                    <TextBlock Grid.Column="2" Text="Sağlayıcı / Açıklama" FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                                    <TextBlock Grid.Column="3" Text="Sınıf" FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                                    <TextBlock Grid.Column="4" Text="Versiyon" FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                                </Grid>
                                                                
                                                                <Grid Grid.Row="1" Margin="8,0,8,6">
                                                                    <Grid.ColumnDefinitions>
                                                                        <ColumnDefinition Width="35"/>
                                                                        <ColumnDefinition Width="110"/>
                                                                        <ColumnDefinition Width="*"/>
                                                                        <ColumnDefinition Width="90"/>
                                                                        <ColumnDefinition Width="75"/>
                                                                    </Grid.ColumnDefinitions>
                                                                    <Border Grid.Column="0"/>
                                                                    <Border Grid.Column="1"/>
                                                                    <ComboBox x:Name="CmbDriverProvider" Grid.Column="2" Height="20" FontSize="10" Padding="4,2">
                                                                        <ComboBoxItem Content="Tüm Sağlayıcılar" IsSelected="True"/>
                                                                    </ComboBox>
                                                                    <Border Grid.Column="3"/>
                                                                    <Border Grid.Column="4"/>
                                                                </Grid>
                                                            </Grid>
                                                        </Border>
                                                        
                                                        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                                            <ListView x:Name="ListViewDrivers" BorderThickness="0" Background="Transparent" Padding="0">
                                                                <ListView.ItemContainerStyle>
                                                                    <Style TargetType="ListViewItem">
                                                                        <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                                                                        <Setter Property="Padding" Value="0"/>
                                                                        <Setter Property="Margin" Value="0"/>
                                                                        <Setter Property="BorderThickness" Value="0"/>
                                                                        <Style.Triggers>
                                                                            <Trigger Property="IsMouseOver" Value="True">
                                                                                <Setter Property="Background" Value="#F3F4F6"/>
                                                                            </Trigger>
                                                                        </Style.Triggers>
                                                                    </Style>
                                                                </ListView.ItemContainerStyle>
                                                                <ListView.ItemTemplate>
                                                                    <DataTemplate>
                                                                        <Border Padding="8,4" BorderBrush="#F3F4F6" BorderThickness="0,0,0,1">
                                                                            <Grid>
                                                                                <Grid.ColumnDefinitions>
                                                                                    <ColumnDefinition Width="35"/>
                                                                                    <ColumnDefinition Width="110"/>
                                                                                    <ColumnDefinition Width="*"/>
                                                                                    <ColumnDefinition Width="90"/>
                                                                                    <ColumnDefinition Width="75"/>
                                                                                </Grid.ColumnDefinitions>
                                                                                
                                                                                <CheckBox Grid.Column="0" IsChecked="{Binding IsSelected, Mode=TwoWay}" VerticalAlignment="Center"/>
                                                                                <TextBlock Grid.Column="1" Text="{Binding DriverName}" FontWeight="SemiBold" 
                                                                                           Foreground="#3B82F6" FontSize="10" VerticalAlignment="Center"/>
                                                                                <TextBlock Grid.Column="2" VerticalAlignment="Center">
                                                                                    <Run Text="{Binding ProviderName}" FontWeight="Medium" FontSize="10" Foreground="#111827"/>
                                                                                    <Run Text="{Binding Description, StringFormat=' — {0}'}" FontSize="9" Foreground="#9CA3AF"/>
                                                                                </TextBlock>
                                                                                <TextBlock Grid.Column="3" Text="{Binding ClassName}" FontSize="10" 
                                                                                           Foreground="#6B7280" VerticalAlignment="Center"/>
                                                                                <TextBlock Grid.Column="4" Text="{Binding Version}" FontSize="9" 
                                                                                           Foreground="#6B7280" VerticalAlignment="Center"/>
                                                                            </Grid>
                                                                        </Border>
                                                                    </DataTemplate>
                                                                </ListView.ItemTemplate>
                                                            </ListView>
                                                        </ScrollViewer>
                                                    </Grid>
                                                </Border>
                                                
                                                <Grid Margin="0,8,0,0">
                                                    <TextBlock VerticalAlignment="Center" FontSize="10" Foreground="#6B7280">
                                                        <Run x:Name="TxtDriverCount" Text="Seçili (görünür): 0"/>
                                                        <Run Text="  │  " Foreground="#9CA3AF"/>
                                                        <Run x:Name="TxtDriverTotalCount" Text="Toplam Seçili: 0" FontWeight="SemiBold" Foreground="#F59E0B"/>
                                                    </TextBlock>
                                                </Grid>
                                            </StackPanel>
                                            
                                            <StackPanel Grid.Column="1" Margin="20,0,0,0">
                                                <TextBlock Text="İŞLEMLER" FontSize="9" FontWeight="SemiBold" Foreground="#9CA3AF" Margin="0,0,0,8"/>
                                                
                                                <Button x:Name="BtnAddDriver" Content="Sürücüleri Yükle" 
                                                        Style="{StaticResource BtnAccent}" Height="22" Margin="0,21,0,0"/>
                                                
                                                <Rectangle Height="47" Fill="Transparent"/>
                                                
                                                <Button x:Name="BtnListDrivers" Content="Tüm Sürücüleri Listele" 
                                                        Style="{StaticResource BtnOutline}" Height="22" Margin="0,0,0,6"/>
                                                
                                                <Button x:Name="BtnRemoveSelectedDrivers" Content="Seçilenleri Kaldır" 
                                                        Style="{StaticResource BtnDanger}" Height="22" Margin="0,0,0,0"/>
                                            </StackPanel>
                                        </Grid>
                                    </Border>
                                    
                                    <Border Style="{StaticResource CardStyle}">
                                        <Grid>
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="170"/>
                                            </Grid.ColumnDefinitions>
                                            
                                            <StackPanel Grid.Column="0">
                                                <TextBlock Text="ÇALIŞAN SİSTEMDEN SÜRÜCÜ YEDEKLEME" Style="{StaticResource CardTitle}"/>
                                                <TextBlock Text="Şu anda çalışan sistemdeki tüm 3. parti sürücüleri dışa aktarır (online mode)" 
                                                           FontSize="10" Foreground="#6B7280" Margin="0,0,0,12" TextWrapping="Wrap"/>
                                                
                                                <Grid Margin="0,0,0,8">
                                                    <Grid.ColumnDefinitions>
                                                        <ColumnDefinition Width="100"/>
                                                        <ColumnDefinition Width="*"/>
                                                        <ColumnDefinition Width="Auto"/>
                                                    </Grid.ColumnDefinitions>
                                                    <TextBlock Text="Hedef Klasör:" VerticalAlignment="Center" FontSize="11" Foreground="#6B7280"/>
                                                    <TextBox x:Name="TxtOnlineExportPath" Grid.Column="1" Style="{StaticResource RndTxt}" 
                                                             Tag="Sürücülerin kaydedileceği klasörü seçin"/>
                                                    <Button x:Name="BtnChooseOnlineExportPath" Grid.Column="2" Content="Gözat..." 
                                                            Style="{StaticResource BtnOutline}" Margin="6,0,0,0" Height="22" Padding="12,0"/>
                                                </Grid>
                                            </StackPanel>
                                            
                                            <StackPanel Grid.Column="1" Margin="20,0,0,0">
                                                <TextBlock Text="İŞLEMLER" FontSize="9" FontWeight="SemiBold" Foreground="#9CA3AF" Margin="0,0,0,8"/>
                                                <Button x:Name="BtnExportDriverOnline" Content="Sürücüleri Dışa Aktar" 
                                                        Style="{StaticResource BtnAccent}" Height="22" Margin="0,53,0,0"/>
                                            </StackPanel>
                                        </Grid>
                                    </Border>
                                </StackPanel>
                            </ScrollViewer>
                        </Grid>

                        <Grid x:Name="Pg_2" Visibility="Collapsed">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <TextBlock Text="Package Servicing" FontSize="16" FontWeight="Bold" Margin="0,0,0,10" Foreground="#111827"/>

                            <Grid Grid.Row="1">
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <Border Grid.Row="0" Style="{StaticResource CardStyle}" Margin="0,0,0,6">
                                    <StackPanel>
                                        <TextBlock Text="PAKET EKLE" Style="{StaticResource CardTitle}"/>
                                        <Grid Margin="0,0,0,6">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="70"/>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Text="CAB / MSU:" VerticalAlignment="Center" FontSize="11" Foreground="#6B7280"/>
                                            <TextBox x:Name="TxtPackagePath" Grid.Column="1"
                                                     Style="{StaticResource RndTxt}" Margin="0,0,6,0"
                                                     Tag="Eklenecek .cab veya .msu dosyasının yolunu seçin..."/>
                                            <Button x:Name="BtnChoosePackage" Grid.Column="2"
                                                    Content="Tek Dosya" Style="{StaticResource BtnOutline}"
                                                    Height="22" Padding="10,0" Margin="0,0,4,0"/>
                                            <Button x:Name="BtnChoosePackageFolder" Grid.Column="3"
                                                    Content="Klasör" Style="{StaticResource BtnOutline}"
                                                    Height="22" Padding="10,0"/>
                                        </Grid>
                                        <Grid>
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                                <ColumnDefinition Width="Auto"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                                <CheckBox x:Name="ChkIgnoreCheck" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                                <TextBlock Text="/IgnoreCheck" FontSize="10" FontWeight="SemiBold"
                                                           Foreground="#374151" VerticalAlignment="Center" Margin="0,0,4,0"/>
                                                <TextBlock Text="(bağımlılık kontrolünü atla)" FontSize="9"
                                                           Foreground="#9CA3AF" VerticalAlignment="Center"/>
                                            </StackPanel>
                                            <CheckBox x:Name="ChkPreventPending" Grid.Column="1"
                                                      VerticalAlignment="Center" Margin="0,0,12,0">
                                                <TextBlock FontSize="10" Foreground="#374151"
                                                           Text="/PreventPending (bekleyen işlem varsa atla)"/>
                                            </CheckBox>
                                            <CheckBox x:Name="ChkNoRestart" Grid.Column="2"
                                                      VerticalAlignment="Center" Margin="0,0,12,0">
                                                <TextBlock FontSize="10" Foreground="#374151" Text="/NoRestart"/>
                                            </CheckBox>
                                            <Button x:Name="BtnAddPackage" Grid.Column="3"
                                                    Content="▶  Paket Ekle" Style="{StaticResource BtnGreen}"
                                                    Height="24" Padding="12,0"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>

                                <Grid Grid.Row="1" Margin="0,0,0,6">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="140"/>
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBox x:Name="TxtPackageSearch" Grid.Column="0"
                                             Style="{StaticResource RndTxt}" Margin="0,0,8,0"
                                             Tag="🔍  Paket adına göre filtrele..."/>
                                    <ComboBox x:Name="CmbPackageStateFilter" Grid.Column="1"
                                              Height="22" FontSize="11" Margin="0,0,8,0"
                                              BorderBrush="#D1D5DB" Background="#F9FAFB">
                                        <ComboBoxItem Content="Tüm Durumlar" IsSelected="True"/>
                                        <ComboBoxItem Content="Installed"/>
                                        <ComboBoxItem Content="Staged"/>
                                        <ComboBoxItem Content="Superseded"/>
                                        <ComboBoxItem Content="Diğer"/>
                                    </ComboBox>
                                    <Button x:Name="BtnListPackages" Grid.Column="2"
                                            Content="↻  Listele" Style="{StaticResource BtnAccent}"
                                            Height="22" Padding="12,0" Margin="0,0,6,0"/>
                                    <Button x:Name="BtnPkgGetInfo" Grid.Column="3"
                                            Content="ℹ  Detay" Style="{StaticResource BtnOutline}"
                                            Height="22" Padding="10,0"/>
                                </Grid>

                                <Border Grid.Row="2" BorderBrush="#D1D5DB" BorderThickness="1"
                                        Background="White" CornerRadius="6" ClipToBounds="True">
                                    <Grid>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="Auto"/>
                                            <RowDefinition Height="*"/>
                                        </Grid.RowDefinitions>

                                        <Border Grid.Row="0" Background="#F9FAFB"
                                                BorderBrush="#E5E7EB" BorderThickness="0,0,0,1" Padding="8,5">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="28"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="80"/>
                                                    <ColumnDefinition Width="70"/>
                                                    <ColumnDefinition Width="90"/>
                                                </Grid.ColumnDefinitions>
                                                <CheckBox x:Name="ChkSelectAllPkgs" Grid.Column="0" VerticalAlignment="Center"/>
                                                <TextBlock Grid.Column="1" Text="Paket Adı"          FontSize="10" FontWeight="Bold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                <TextBlock Grid.Column="2" Text="Sürüm"              FontSize="10" FontWeight="Bold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                <TextBlock Grid.Column="3" Text="Mimari"             FontSize="10" FontWeight="Bold" Foreground="#6B7280" VerticalAlignment="Center" HorizontalAlignment="Center"/>
                                                <TextBlock Grid.Column="4" Text="Durum"              FontSize="10" FontWeight="Bold" Foreground="#6B7280" VerticalAlignment="Center" HorizontalAlignment="Center"/>
                                            </Grid>
                                        </Border>

                                        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                            <ListView x:Name="ListViewPackages" BorderThickness="0"
                                                      Background="Transparent" Padding="0"
                                                      VirtualizingPanel.IsVirtualizing="True"
                                                      VirtualizingPanel.VirtualizationMode="Recycling">
                                                <ListView.ItemContainerStyle>
                                                    <Style TargetType="ListViewItem">
                                                        <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                                                        <Setter Property="Padding" Value="0"/>
                                                        <Setter Property="Margin" Value="0"/>
                                                        <Setter Property="BorderThickness" Value="0"/>
                                                        <Style.Triggers>
                                                            <Trigger Property="IsMouseOver" Value="True">
                                                                <Setter Property="Background" Value="#F3F4F6"/>
                                                            </Trigger>
                                                        </Style.Triggers>
                                                    </Style>
                                                </ListView.ItemContainerStyle>
                                                <ListView.ItemTemplate>
                                                    <DataTemplate>
                                                        <Border Padding="8,4" BorderBrush="#F3F4F6" BorderThickness="0,0,0,1">
                                                            <Grid>
                                                                <Grid.ColumnDefinitions>
                                                                    <ColumnDefinition Width="28"/>
                                                                    <ColumnDefinition Width="*"/>
                                                                    <ColumnDefinition Width="80"/>
                                                                    <ColumnDefinition Width="70"/>
                                                                    <ColumnDefinition Width="90"/>
                                                                </Grid.ColumnDefinitions>
                                                                <CheckBox Grid.Column="0"
                                                                          IsChecked="{Binding IsSelected, Mode=TwoWay}"
                                                                          VerticalAlignment="Center"/>
                                                                <TextBlock Grid.Column="1"
                                                                           Text="{Binding PackageName}"
                                                                           FontSize="10" FontWeight="SemiBold"
                                                                           Foreground="#1D4ED8" VerticalAlignment="Center"
                                                                           TextTrimming="CharacterEllipsis"
                                                                           ToolTip="{Binding PackageName}"/>
                                                                <TextBlock Grid.Column="2"
                                                                           Text="{Binding Version}"
                                                                           FontSize="9" Foreground="#6B7280"
                                                                           VerticalAlignment="Center"
                                                                           TextTrimming="CharacterEllipsis"/>
                                                                <TextBlock Grid.Column="3"
                                                                           Text="{Binding Architecture}"
                                                                           FontSize="9" Foreground="#6B7280"
                                                                           VerticalAlignment="Center"
                                                                           HorizontalAlignment="Center"/>
                                                                <Border Grid.Column="4"
                                                                        Background="{Binding StateColor}"
                                                                        CornerRadius="4" Padding="6,2"
                                                                        HorizontalAlignment="Center"
                                                                        VerticalAlignment="Center">
                                                                    <TextBlock Text="{Binding StateLabel}"
                                                                               FontSize="9" FontWeight="SemiBold"
                                                                               Foreground="White"/>
                                                                </Border>
                                                            </Grid>
                                                        </Border>
                                                    </DataTemplate>
                                                </ListView.ItemTemplate>
                                            </ListView>
                                        </ScrollViewer>

                                        <TextBlock x:Name="LblPackagesEmpty"
                                                   Grid.Row="1"
                                                   Text="İmaj bağlayın ve 'Listele' butonuna tıklayın."
                                                   FontSize="11" Foreground="#9CA3AF"
                                                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Grid>
                                </Border>

                                <Grid Grid.Row="3" Margin="0,6,0,0">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock VerticalAlignment="Center" FontSize="10" Foreground="#6B7280">
                                        <Run x:Name="TxtPkgTotal"    Text="Toplam: 0"/>
                                        <Run Text="  │  " Foreground="#9CA3AF"/>
                                        <Run x:Name="TxtPkgInstalled" Text="Installed: 0" Foreground="#16A34A" FontWeight="SemiBold"/>
                                        <Run Text="  │  " Foreground="#9CA3AF"/>
                                        <Run x:Name="TxtPkgSelected"  Text="Seçili: 0"   Foreground="#F59E0B" FontWeight="SemiBold"/>
                                    </TextBlock>
                                    <StackPanel Grid.Column="1" Orientation="Horizontal">
                                        <Button x:Name="BtnPkgSelectAll"  Content="Tümünü Seç"
                                                Style="{StaticResource BtnOutline}" Height="22" Padding="8,0" Margin="0,0,4,0"/>
                                        <Button x:Name="BtnPkgSelectNone" Content="Seçimi Kaldır"
                                                Style="{StaticResource BtnOutline}" Height="22" Padding="8,0"/>
                                    </StackPanel>
                                </Grid>

                                <Border Grid.Row="4" Style="{StaticResource CardStyle}" Margin="0,6,0,0">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="180"/>
                                        </Grid.ColumnDefinitions>
                                        <Button x:Name="BtnRemoveSelectedPackages" Grid.Column="0"
                                                Content="✖  Seçilileri Kaldır"
                                                Style="{StaticResource BtnDanger}"
                                                Height="28" Padding="0" Margin="0,0,5,0"/>
                                        <Grid Grid.Column="1" Margin="0,0,5,0">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="70"/>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Text="İsme Göre:" VerticalAlignment="Center"
                                                       FontSize="10" Foreground="#6B7280"/>
                                            <TextBox x:Name="TxtRemovePackageName" Grid.Column="1"
                                                     Style="{StaticResource RndTxt}" Margin="0,0,4,0"
                                                     Tag="Tam paket adını girin..."/>
                                            <Button x:Name="BtnRemovePackageByName" Grid.Column="2"
                                                    Content="Kaldır" Style="{StaticResource BtnDanger}"
                                                    Height="24" Padding="10,0"/>
                                        </Grid>
                                        <Button x:Name="BtnPkgExportList" Grid.Column="2"
                                                Content="📋  Listeyi Dışa Aktar"
                                                Style="{StaticResource BtnOutline}"
                                                Height="28" Padding="0"/>
                                    </Grid>
                                </Border>
                            </Grid>
                        </Grid>

                        <Grid x:Name="Pg_3" Visibility="Collapsed">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <TextBlock Text="Features on Demand" FontSize="16" FontWeight="Bold" Margin="0,0,0,10" Foreground="#111827"/>

                            <Grid Grid.Row="1">
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <Border Grid.Row="0" Style="{StaticResource CardStyle}" Margin="0,0,0,6">
                                    <Grid>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="Auto"/>
                                            <RowDefinition Height="Auto"/>
                                        </Grid.RowDefinitions>

                                        <Grid Grid.Row="0" Margin="0,0,0,8">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="140"/>
                                                <ColumnDefinition Width="110"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBox x:Name="TxtFeatureSearch" Grid.Column="0"
                                                     Style="{StaticResource RndTxt}" Margin="0,0,8,0"
                                                     Tag="🔍  Özellik adına göre filtrele..."/>
                                            <ComboBox x:Name="CmbFeatureStateFilter" Grid.Column="1"
                                                      Height="22" FontSize="11" Margin="0,0,8,0"
                                                      BorderBrush="#D1D5DB" Background="#F9FAFB">
                                                <ComboBoxItem Content="Tüm Durumlar" IsSelected="True"/>
                                                <ComboBoxItem Content="Etkin"/>
                                                <ComboBoxItem Content="Devre Dışı"/>
                                                <ComboBoxItem Content="Beklemede"/>
                                            </ComboBox>
                                            <Button x:Name="BtnListFeatures" Grid.Column="2"
                                                    Content="↻  Listele" Height="22"
                                                    Style="{StaticResource BtnAccent}" Padding="0"/>
                                        </Grid>

                                        <Grid Grid.Row="1">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="70"/>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                                <ColumnDefinition Width="Auto"/>
                                                <ColumnDefinition Width="Auto"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Text="Kaynak:" VerticalAlignment="Center"
                                                       FontSize="11" Foreground="#6B7280"/>
                                            <TextBox x:Name="TxtFeatureSource" Grid.Column="1"
                                                     Style="{StaticResource RndTxt}" Margin="0,0,6,0"
                                                     Tag="(İsteğe bağlı) .cab, .wim veya .esd kaynak dosyası..."/>
                                            <Button x:Name="BtnFeatureSourceBrowse" Grid.Column="2"
                                                    Content="Gözat" Style="{StaticResource BtnOutline}"
                                                    Height="22" Padding="10,0" Margin="0,0,6,0"/>
                                            <CheckBox x:Name="ChkFeatureLimitAccess" Grid.Column="3"
                                                      VerticalAlignment="Center" Margin="0,0,10,0">
                                                <TextBlock FontSize="10" Foreground="#374151"
                                                           Text="/LimitAccess  (WU/WSUS'u devre dışı bırak)"/>
                                            </CheckBox>
                                            <CheckBox x:Name="ChkFeatureAll" Grid.Column="4"
                                                      VerticalAlignment="Center" Margin="0,0,10,0">
                                                <TextBlock FontSize="10" Foreground="#374151"
                                                           Text="/All  (tüm bağımlıları dahil et)"/>
                                            </CheckBox>
                                            <Button x:Name="BtnInstallFromSource" Grid.Column="5"
                                                    Content="📦  Kaynaktan Yükle" Style="{StaticResource BtnAccent}"
                                                    Height="22" Padding="10,0" IsEnabled="False"/>
                                        </Grid>
                                    </Grid>
                                </Border>

                                <Border Grid.Row="1" BorderBrush="#D1D5DB" BorderThickness="1"
                                        Background="White" CornerRadius="6" ClipToBounds="True">
                                    <Grid>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="Auto"/>
                                            <RowDefinition Height="*"/>
                                        </Grid.RowDefinitions>

                                        <Border Grid.Row="0" Background="#F9FAFB"
                                                BorderBrush="#E5E7EB" BorderThickness="0,0,0,1" Padding="8,5,25,5">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="28"/>
                                                    <ColumnDefinition Width="220"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                </Grid.ColumnDefinitions>
                                                <CheckBox x:Name="ChkSelectAllFeatures" Grid.Column="0"
                                                          VerticalAlignment="Center"/>
                                                <TextBlock Grid.Column="1" Text="Özellik Adı"
                                                           FontSize="10" FontWeight="Bold" Foreground="#6B7280"
                                                           VerticalAlignment="Center"/>
                                                <TextBlock Grid.Column="2" Text="Açıklama"
                                                           FontSize="10" FontWeight="Bold" Foreground="#6B7280"
                                                           VerticalAlignment="Center"/>
                                                <TextBlock Grid.Column="3" Text="Durum"
                                                           FontSize="10" FontWeight="Bold" Foreground="#6B7280"
                                                           VerticalAlignment="Center" HorizontalAlignment="Center"
                                                           MinWidth="80" TextAlignment="Center"/>
                                            </Grid>
                                        </Border>

                                        <ListView x:Name="ListViewFeatures" Grid.Row="1"
                                                  BorderThickness="0" Background="Transparent" Padding="0"
                                                  ScrollViewer.VerticalScrollBarVisibility="Auto"
                                                  ScrollViewer.HorizontalScrollBarVisibility="Hidden"
                                                  VirtualizingPanel.IsVirtualizing="True"
                                                  VirtualizingPanel.VirtualizationMode="Recycling"
                                                  HorizontalContentAlignment="Stretch">
                                            <ListView.ItemContainerStyle>
                                                <Style TargetType="ListViewItem">
                                                    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                                                    <Setter Property="Padding" Value="0"/>
                                                    <Setter Property="Margin" Value="0"/>
                                                    <Setter Property="BorderThickness" Value="0"/>
                                                    <Setter Property="Template">
                                                        <Setter.Value>
                                                            <ControlTemplate TargetType="ListViewItem">
                                                                <Border x:Name="ItemBorder"
                                                                        Background="Transparent"
                                                                        BorderBrush="#F3F4F6"
                                                                        BorderThickness="0,0,0,1">
                                                                    <ContentPresenter
                                                                        HorizontalAlignment="Stretch"
                                                                        VerticalAlignment="Center"/>
                                                                </Border>
                                                                <ControlTemplate.Triggers>
                                                                    <Trigger Property="IsMouseOver" Value="True">
                                                                        <Setter TargetName="ItemBorder" Property="Background" Value="#F3F4F6"/>
                                                                    </Trigger>
                                                                    <Trigger Property="IsSelected" Value="True">
                                                                        <Setter TargetName="ItemBorder" Property="Background" Value="#EFF6FF"/>
                                                                    </Trigger>
                                                                </ControlTemplate.Triggers>
                                                            </ControlTemplate>
                                                        </Setter.Value>
                                                    </Setter>
                                                </Style>
                                            </ListView.ItemContainerStyle>
                                            <ListView.ItemTemplate>
                                                <DataTemplate>
                                                    <Grid Margin="8,3,8,3">
                                                        <Grid.ColumnDefinitions>
                                                            <ColumnDefinition Width="28"/>
                                                            <ColumnDefinition Width="220"/>
                                                            <ColumnDefinition Width="*"/>
                                                            <ColumnDefinition Width="Auto"/>
                                                        </Grid.ColumnDefinitions>
                                                        <CheckBox Grid.Column="0"
                                                                  IsChecked="{Binding IsSelected, Mode=TwoWay}"
                                                                  VerticalAlignment="Center"/>
                                                        <TextBlock Grid.Column="1"
                                                                   Text="{Binding FeatureName}"
                                                                   FontWeight="SemiBold" FontSize="11"
                                                                   Foreground="#1D4ED8" VerticalAlignment="Center"
                                                                   TextTrimming="CharacterEllipsis"
                                                                   ToolTip="{Binding FeatureName}"
                                                                   Margin="0,0,8,0"/>
                                                        <TextBlock Grid.Column="2"
                                                                   Text="{Binding DisplayName}"
                                                                   FontSize="10" Foreground="#374151"
                                                                   VerticalAlignment="Center"
                                                                   TextTrimming="CharacterEllipsis"
                                                                   ToolTip="{Binding DisplayName}"
                                                                   Margin="0,0,8,0"/>
                                                        <Border Grid.Column="3"
                                                                Background="{Binding StateColor}"
                                                                CornerRadius="4" Padding="12,3"
                                                                MinWidth="80"
                                                                HorizontalAlignment="Right"
                                                                VerticalAlignment="Center">
                                                            <TextBlock Text="{Binding StateLabel}"
                                                                       FontSize="10" FontWeight="SemiBold"
                                                                       Foreground="White"
                                                                       HorizontalAlignment="Center"
                                                                       TextAlignment="Center"
                                                                       TextWrapping="NoWrap"/>
                                                        </Border>
                                                    </Grid>
                                                </DataTemplate>
                                            </ListView.ItemTemplate>
                                        </ListView>

                                        <TextBlock x:Name="LblFeaturesEmpty"
                                                   Grid.Row="1" Text="İmaj bağlayın ve 'Listele' butonuna tıklayın."
                                                   FontSize="11" Foreground="#9CA3AF"
                                                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Grid>
                                </Border>

                                <Grid Grid.Row="2" Margin="0,6,0,0">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock VerticalAlignment="Center" FontSize="10" Foreground="#6B7280">
                                        <Run x:Name="TxtFeatureCount"      Text="Toplam: 0"/>
                                        <Run Text="  │  " Foreground="#9CA3AF"/>
                                        <Run x:Name="TxtFeatureEnabled"    Text="Etkin: 0"    Foreground="#16A34A" FontWeight="SemiBold"/>
                                        <Run Text="  │  " Foreground="#9CA3AF"/>
                                        <Run x:Name="TxtFeatureDisabled"   Text="Devre Dışı: 0" Foreground="#6B7280"/>
                                        <Run Text="  │  " Foreground="#9CA3AF"/>
                                        <Run x:Name="TxtFeatureSelected"   Text="Seçili: 0"   Foreground="#F59E0B" FontWeight="SemiBold"/>
                                    </TextBlock>
                                </Grid>

                                <Border Grid.Row="3" Style="{StaticResource CardStyle}" Margin="0,6,0,0">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <Button x:Name="BtnEnableFeature"    Grid.Column="0"
                                                Content="✔  Seçilileri Etkinleştir"
                                                Style="{StaticResource BtnGreen}"
                                                Height="28" Padding="0" Margin="0,0,5,0"/>
                                        <Button x:Name="BtnDisableFeature"   Grid.Column="1"
                                                Content="✖  Seçilileri Devre Dışı"
                                                Style="{StaticResource BtnDanger}"
                                                Height="28" Padding="0" Margin="0,0,5,0"/>
                                        <Button x:Name="BtnFeatureInfo"      Grid.Column="2"
                                                Content="ℹ  Özellik Detayı"
                                                Style="{StaticResource BtnOutline}"
                                                Height="28" Padding="0" Margin="0"/>
                                    </Grid>
                                </Border>
                            </Grid>
                        </Grid>

                        <Grid x:Name="Pg_4" Visibility="Collapsed">
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                            <TextBlock Text="Edition Management" FontSize="16" FontWeight="Bold" Margin="0,0,0,10" Foreground="#111827"/>
                            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                <StackPanel>
                                    <Border Style="{StaticResource CardStyle}">
                                        <StackPanel>
                                            <TextBlock Text="SÜRÜM &amp; LİSANS İŞLEMLERİ" Style="{StaticResource CardTitle}"/>
                                            <Grid Margin="0,0,0,6">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Text="Ürün Anahtarı:" VerticalAlignment="Center" FontSize="11"/>
                                                <TextBox x:Name="TxtProductKey" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"/>
                                                <Button x:Name="BtnSetProductKey" Grid.Column="2" Content="Ata" Style="{StaticResource BtnAccent}" Margin="6,0,0,0" Height="22"/>
                                            </Grid>
                                            <Grid Margin="0,0,0,6">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Text="Hedef Sürüm:" VerticalAlignment="Center" FontSize="11"/>
                                                <TextBox x:Name="TxtEdition" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Yükseltilecek sürüm adını girin (Örn: Professional)"/>
                                                <Button x:Name="BtnSetEdition" Grid.Column="2" Content="Yükselt" Style="{StaticResource BtnAccent}" Margin="6,0,0,0" Height="22"/>
                                            </Grid>
                                        </StackPanel>
                                    </Border>
                                    <WrapPanel>
                                        <Button x:Name="BtnShowCurrentEdition" Content="Mevcut Sürümü Göster"         Style="{StaticResource BtnOutline}"/>
                                        <Button x:Name="BtnShowTargetEdition"  Content="Yükseltilebilir Sürümleri Listele" Style="{StaticResource BtnOutline}"/>
                                    </WrapPanel>
                                </StackPanel>
                            </ScrollViewer>
                        </Grid>

                        <Grid x:Name="Pg_5" Visibility="Collapsed">
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                            <TextBlock Text="Automated Setup" FontSize="16" FontWeight="Bold" Margin="0,0,0,10" Foreground="#111827"/>
                            <StackPanel Grid.Row="1">
                                <Border Style="{StaticResource CardStyle}">
                                    <StackPanel>
                                        <TextBlock Text="YANIT DOSYASI (XML)" Style="{StaticResource CardTitle}"/>
                                        <Grid Margin="0,0,0,6">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="85"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="XML Dosyası:" VerticalAlignment="Center" FontSize="11"/>
                                            <TextBox x:Name="TxtUnattendXml" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Unattend.xml veya Autounattend.xml dosyasını seçin..."/>
                                            <Button x:Name="BtnChooseUnattendXml" Grid.Column="2" Content="..." Style="{StaticResource BtnOutline}" Margin="6,0,0,0" Height="22"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>
                                <WrapPanel>
                                    <Button x:Name="BtnApplyUnattendXml" Content="XML'i İmaja Uygula" Style="{StaticResource BtnAccent}"/>
                                </WrapPanel>
                            </StackPanel>
                        </Grid>

                        <Grid x:Name="Pg_6" Visibility="Collapsed">
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                            <TextBlock Text="Capture OS Image" FontSize="16" FontWeight="Bold" Margin="0,0,0,10" Foreground="#111827"/>
                            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                <StackPanel>
                                    <Border Style="{StaticResource CardStyle}">
                                        <StackPanel>
                                            <TextBlock Text="YAKALAMA AYARLARI" Style="{StaticResource CardTitle}"/>
                                            <Grid Margin="0,0,0,6">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock VerticalAlignment="Center" FontSize="11"><Run Foreground="#6B7280" Text="① "/><Run Text="Kaynak Dizin" FontWeight="SemiBold"/></TextBlock>
                                                <TextBox x:Name="TxtCaptureSource" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Kaynağı seçerek başlayın..."/>
                                                <Button x:Name="BtnCaptureBrowseSource" Grid.Column="2" Content="Gözat" Style="{StaticResource BtnOutline}" Margin="6,0,0,0" Height="22"/>
                                            </Grid>
                                            <Grid Margin="0,0,0,6">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock VerticalAlignment="Center" FontSize="11"><Run Foreground="#6B7280" Text="② "/><Run Text="Hedef Dizin" FontWeight="SemiBold"/></TextBlock>
                                                <TextBox x:Name="TxtCaptureDestDir" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Kaynak seçince aktif olur..." IsEnabled="False"/>
                                                <Button x:Name="BtnCaptureBrowseDest" Grid.Column="2" Content="Gözat" Style="{StaticResource BtnOutline}" Margin="6,0,0,0" Height="22" IsEnabled="False"/>
                                            </Grid>
                                            <Grid Margin="0,0,0,6">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock VerticalAlignment="Center" FontSize="11"><Run Foreground="#6B7280" Text="③ "/><Run Text="Dosya Adı" FontWeight="SemiBold"/></TextBlock>
                                                <TextBox x:Name="TxtCaptureFileName" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Hedef seçince Generate kullanabilirsiniz..." IsEnabled="False"/>
                                                <Button x:Name="BtnGenerateFileName" Grid.Column="2" Content="⚙ Generate" Style="{StaticResource BtnOutline}" Margin="6,0,0,0" Height="22" IsEnabled="False" ToolTip="İmaj adı ve tarihe göre otomatik dosya adı oluştur"/>
                                            </Grid>
                                            <Grid Margin="0,0,0,6">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock VerticalAlignment="Center" FontSize="11"><Run Foreground="#6B7280" Text="④ "/><Run Text="İmaj Adı" FontWeight="SemiBold"/></TextBlock>
                                                <TextBox x:Name="TxtCaptureWimName" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Dosya adı girilince aktif olur..." IsEnabled="False"/>
                                            </Grid>
                                            <Grid>
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock VerticalAlignment="Center" FontSize="11"><Run Foreground="#6B7280" Text="  "/><Run Text="Açıklama" FontWeight="SemiBold"/></TextBlock>
                                                <TextBox x:Name="TxtCaptureDesc" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Sistem analizi otomatik doldurur, düzenleyebilirsiniz" IsEnabled="False"/>
                                            </Grid>
                                        </StackPanel>
                                    </Border>
                                    <Border Style="{StaticResource CardStyle}" x:Name="PnlCaptureOptions" IsEnabled="False">
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock VerticalAlignment="Center" FontSize="11" Margin="0,0,10,0"><Run Foreground="#6B7280" Text="⑤ "/><Run Text="Sıkıştırma:" FontWeight="SemiBold"/></TextBlock>
                                            <ComboBox x:Name="CmbCaptureCompression" Height="22" Width="100" FontSize="11">
                                                <ComboBoxItem Content="fast" IsSelected="True"/>
                                                <ComboBoxItem Content="max"/>
                                                <ComboBoxItem Content="none"/>
                                            </ComboBox>
                                            <CheckBox x:Name="ChkCaptureVerify" Content="/Verify" Margin="15,0,0,0" VerticalAlignment="Center" FontSize="11"/>
                                        </StackPanel>
                                    </Border>
                                    <WrapPanel>
                                        <Button x:Name="BtnCaptureCreate" Content="▶ Yeni Capture Başlat" Style="{StaticResource BtnAccent}" IsEnabled="False"/>
                                        <Button x:Name="BtnCaptureAppend" Content="➕ Mevcut WIM’e Ekle" Style="{StaticResource BtnOutline}" IsEnabled="False"/>
                                        <Button x:Name="BtnCaptureClear" Content="🗑 Formu Temizle" Style="{StaticResource BtnOutline}" Margin="10,0,0,0"/>
                                    </WrapPanel>
                                </StackPanel>
                            </ScrollViewer>
                        </Grid>

                        <Grid x:Name="Pg_7" Visibility="Collapsed">
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                            <TextBlock Text="Deploy OS Image" FontSize="16" FontWeight="Bold" Margin="0,0,0,10" Foreground="#111827"/>
                            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                <StackPanel>
                                    <Border Style="{StaticResource CardStyle}">
                                        <StackPanel>
                                            <TextBlock Text="KAYNAK &amp; INDEX" Style="{StaticResource CardTitle}"/>
                                            <Grid Margin="0,0,0,8">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="90"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                </Grid.ColumnDefinitions>
                                                <TextBlock Text="WIM/ESD:" VerticalAlignment="Center" FontSize="11"/>
                                                <TextBox x:Name="TxtApplySource" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Dağıtılacak WIM veya ESD imajını seçin..."/>
                                                <Button x:Name="BtnApplyBrowseSource" Grid.Column="2" Content="Gözat" Style="{StaticResource BtnOutline}" Margin="6,0,0,0" Height="22"/>
                                            </Grid>
                                            
                                            <TextBlock Text="Index Seçin:" FontSize="11" Margin="0,0,0,4" Foreground="#6B7280"/>
                                            <Border BorderBrush="#D1D5DB" BorderThickness="1" Background="White" CornerRadius="6" Height="160">
                                                <Grid>
                                                    <Grid.RowDefinitions>
                                                        <RowDefinition Height="Auto"/>
                                                        <RowDefinition Height="*"/>
                                                    </Grid.RowDefinitions>
                                                    
                                                    <Border Grid.Row="0" Background="#F9FAFB" BorderBrush="#E5E7EB" BorderThickness="0,0,0,1" Padding="8,6">
                                                        <Grid>
                                                            <Grid.ColumnDefinitions>
                                                                <ColumnDefinition Width="45"/>
                                                                <ColumnDefinition Width="*"/>
                                                                <ColumnDefinition Width="80"/>
                                                            </Grid.ColumnDefinitions>
                                                            <TextBlock Grid.Column="0" Text="#" FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                            <TextBlock Grid.Column="1" Text="Index Adı" FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                            <TextBlock Grid.Column="2" Text="Boyut" FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center" TextAlignment="Right"/>
                                                        </Grid>
                                                    </Border>
                                                    
                                                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                                        <ListView x:Name="ListViewApplyIndex" BorderThickness="0" Background="Transparent" Padding="0" SelectionMode="Single">
                                                            <ListView.ItemContainerStyle>
                                                                <Style TargetType="ListViewItem">
                                                                    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                                                                    <Setter Property="Padding" Value="0"/>
                                                                    <Setter Property="Margin" Value="0"/>
                                                                    <Setter Property="BorderThickness" Value="0"/>
                                                                    <Style.Triggers>
                                                                        <Trigger Property="IsSelected" Value="True">
                                                                            <Setter Property="Background" Value="#DBEAFE"/>
                                                                            <Setter Property="Foreground" Value="#1E40AF"/>
                                                                        </Trigger>
                                                                        <Trigger Property="IsMouseOver" Value="True">
                                                                            <Setter Property="Background" Value="#F3F4F6"/>
                                                                        </Trigger>
                                                                    </Style.Triggers>
                                                                </Style>
                                                            </ListView.ItemContainerStyle>
                                                            <ListView.ItemTemplate>
                                                                <DataTemplate>
                                                                    <Border Padding="8,6" BorderBrush="#F3F4F6" BorderThickness="0,0,0,1">
                                                                        <Grid>
                                                                            <Grid.ColumnDefinitions>
                                                                                <ColumnDefinition Width="45"/>
                                                                                <ColumnDefinition Width="*"/>
                                                                                <ColumnDefinition Width="80"/>
                                                                            </Grid.ColumnDefinitions>
                                                                            
                                                                            <TextBlock Grid.Column="0" Text="{Binding IndexNumber}" FontWeight="SemiBold" 
                                                                                       Foreground="#3B82F6" FontSize="11" VerticalAlignment="Center"/>
                                                                            
                                                                            <TextBlock Grid.Column="1" VerticalAlignment="Center">
                                                                                <Run Text="{Binding IndexName}" FontWeight="Medium" FontSize="11" Foreground="#111827"/>
                                                                                <Run Text="{Binding Description, StringFormat=' — {0}'}" FontSize="10" Foreground="#9CA3AF"/>
                                                                            </TextBlock>
                                                                            
                                                                            <TextBlock Grid.Column="2" Text="{Binding SizeText}" FontSize="10" 
                                                                                       Foreground="#6B7280" VerticalAlignment="Center" TextAlignment="Right"/>
                                                                        </Grid>
                                                                    </Border>
                                                                </DataTemplate>
                                                            </ListView.ItemTemplate>
                                                        </ListView>
                                                    </ScrollViewer>
                                                </Grid>
                                            </Border>
                                        </StackPanel>
                                    </Border>

                                    <Border Style="{StaticResource CardStyle}">
                                        <StackPanel>
                                            <TextBlock Text="GERİ YÜKLEME MODU" Style="{StaticResource CardTitle}"/>
                                            <RadioButton x:Name="RdoApplyToVolume" Content="Bölüme Uygula  (Format + DISM Apply, mevcut disk yapısı korunur)" IsChecked="True" FontSize="11" Margin="0,0,0,6"/>
                                            <RadioButton x:Name="RdoApplyToDisk"   Content="Diske Uygula  (Disk silinir, yeniden bölümlenir, boot ayarlanır)" FontSize="11" Margin="0,0,0,6"/>
                                            <RadioButton x:Name="RdoApplyToVhd"    Content="VHD/VHDX'e Uygula  (Sanal disk oluştur veya mevcut VHD'yi kullan)" FontSize="11"/>
                                        </StackPanel>
                                    </Border>

                                    <Border Style="{StaticResource CardStyle}" x:Name="PnlApplyVolume">
                                        <StackPanel>
                                            <TextBlock Text="HEDEF BÖLÜM" Style="{StaticResource CardTitle}"/>
                                            <Grid Margin="0,0,0,6">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Text="Hedef Sürücü:" VerticalAlignment="Center" FontSize="11"/>
                                                <TextBox x:Name="TxtApplyDest" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Örn: W: veya D:"/>
                                                <Button x:Name="BtnApplyBrowseDest" Grid.Column="2" Content="Seç" Style="{StaticResource BtnOutline}" Margin="6,0,0,0" Height="22"/>
                                            </Grid>
                                            <StackPanel Orientation="Horizontal">
                                                <CheckBox x:Name="ChkApplyVerify"  Content="/Verify" Margin="0,0,15,0" FontSize="11"/>
                                                <CheckBox x:Name="ChkApplyCompact" Content="/Compact" FontSize="11"/>
                                            </StackPanel>
                                        </StackPanel>
                                    </Border>

                                    <Border Style="{StaticResource CardStyle}" x:Name="PnlApplyDisk" Visibility="Collapsed">
                                        <StackPanel>
                                            <TextBlock Text="HEDEF DİSK &amp; FIRMWARE" Style="{StaticResource CardTitle}"/>
                                            
                                            <Grid Margin="0,0,0,6">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="90"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="Auto" MaxWidth="80"/>
                                                </Grid.ColumnDefinitions>
                                                <TextBlock Text="Hedef Disk:" VerticalAlignment="Center" FontSize="11"/>
                                                <TextBox x:Name="TxtApplyDisk" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Disk numarası (Seç butonundan seçin)" IsReadOnly="True"/>
                                                <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="6,0,0,0">
                                                    <Button x:Name="BtnApplyDiskSelect" Content="Seç" Style="{StaticResource BtnOutline}" Height="22" Margin="0"/>
                                                    <Button x:Name="BtnRefreshDisks" Content="🔄" Style="{StaticResource BtnOutline}" Margin="4,0,0,0" Height="22" Width="24" Padding="2,0" ToolTip="Disk listesini yenile"/>
                                                </StackPanel>
                                            </Grid>
                                            
                                            <Grid Margin="0,0,0,6">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock Text="Firmware:" VerticalAlignment="Center" FontSize="11"/>
                                                <StackPanel Grid.Column="1" Orientation="Horizontal">
                                                    <RadioButton x:Name="RdoFirmwareUEFI" Content="UEFI / GPT  (Modern)" IsChecked="True" FontSize="11" Margin="0,0,20,0"/>
                                                    <RadioButton x:Name="RdoFirmwareBIOS" Content="BIOS / MBR  (Eski)" FontSize="11"/>
                                                </StackPanel>
                                            </Grid>
                                            
                                            <TextBlock Text="Algılanan Firmware:" FontSize="10" Foreground="#6B7280" Margin="0,0,0,2"/>
                                            <TextBlock x:Name="LblDetectedFirmware" Text="—" FontSize="11" FontWeight="SemiBold" Foreground="#4A6278" Margin="0,0,0,10"/>
                                            
                                            <Border Background="#EFF6FF" CornerRadius="4" Padding="10,8" Margin="0,0,0,10">
                                                <StackPanel>
                                                    <TextBlock Text="BÖLÜMLENDIRME AYARLARI" FontSize="11" FontWeight="Bold" Foreground="#1E40AF" Margin="0,0,0,8"/>
                                                    
                                                    <CheckBox x:Name="ChkCreateRecovery" Content="Kurtarma bölümü oluştur (WinRE - 1 GB)" IsChecked="True" FontSize="11" Margin="0,0,0,6"/>
                                                    
                                                    <Grid Margin="0,0,0,6">
                                                        <Grid.ColumnDefinitions>
                                                            <ColumnDefinition Width="Auto"/>
                                                            <ColumnDefinition Width="70"/>
                                                            <ColumnDefinition Width="*"/>
                                                        </Grid.ColumnDefinitions>
                                                        <TextBlock Text="Windows Boyutu:" VerticalAlignment="Center" FontSize="11" Margin="0,0,8,0"/>
                                                        <TextBox x:Name="TxtWindowsSize" Grid.Column="1" Height="22" FontSize="11" Padding="4,2" ToolTip="GB cinsinden (Boş = Tüm disk)"/>
                                                        <TextBlock Grid.Column="2" Text="GB  (Boş = Tüm disk)" VerticalAlignment="Center" FontSize="10" Foreground="#6B7280" Margin="6,0,0,0"/>
                                                    </Grid>
                                                    
                                                    <CheckBox x:Name="ChkCreateDataDisk" Content="Kalan alanı Data diski olarak ayır" FontSize="11" Margin="0,0,0,4"/>
                                                    <Grid Margin="18,0,0,0">
                                                        <Grid.ColumnDefinitions>
                                                            <ColumnDefinition Width="Auto"/>
                                                            <ColumnDefinition Width="*"/>
                                                        </Grid.ColumnDefinitions>
                                                        <TextBlock Text="Etiket:" VerticalAlignment="Center" FontSize="10" Foreground="#6B7280" Margin="0,0,8,0"/>
                                                        <TextBox x:Name="TxtDataDiskLabel" Grid.Column="1" Text="DATA" Height="22" FontSize="11" Padding="4,2" MaxLength="11" IsEnabled="False"/>
                                                    </Grid>

                                                    <Separator Margin="0,8,0,8" Background="#BFDBFE"/>
                                                    <CheckBox x:Name="ChkAddToBcd" Content="Mevcut sistemin önyükleme menüsüne ekle" IsChecked="False" FontSize="11" Margin="0,0,0,4"/>
                                                    <TextBlock x:Name="LblBcdWarning" Visibility="Collapsed" TextWrapping="Wrap" FontSize="10" Foreground="#DC2626" Margin="18,0,0,0"
                                                               Text="UYARI: Bu seçenek, kurulu Windows'un BCD deposuna yeni kurulumu ekler. Yanlış yapılandırma mevcut sistemi açılamaz hale getirebilir. Yalnızca deneyimli kullanıcılar tarafından kullanılmalıdır."/>
                                                </StackPanel>
                                            </Border>
                                            
                                            <Border Background="#162840" BorderBrush="#2A4A7A" BorderThickness="1" CornerRadius="4" Padding="10,8" Margin="0,0,0,10">
                                                <StackPanel>
                                                    <TextBlock Text="Bölümlendirme Önizleme" FontSize="11" FontWeight="SemiBold" Foreground="#93C5FD" Margin="0,0,0,4"/>
                                                    <TextBlock x:Name="LblDiskInfo" Text="Disk: —" FontSize="10" Foreground="#94A3B8" Margin="0,0,0,6"/>
                                                    
                                                    <Border x:Name="PartitionBarContainer" Visibility="Collapsed" BorderBrush="#334155" BorderThickness="1" CornerRadius="4" Margin="0,0,0,6" ClipToBounds="True">
                                                        <Grid x:Name="PartitionVisualPreview" Height="52" Background="#0F1F35">
                                                        </Grid>
                                                    </Border>
                                                    
                                                    <Border x:Name="LegendBorder" Visibility="Collapsed" Background="#1E3250" CornerRadius="3" Padding="8,5" Margin="0,0,0,2">
                                                        <ItemsControl x:Name="PartitionLegend">
                                                            <ItemsControl.ItemsPanel>
                                                                <ItemsPanelTemplate>
                                                                    <WrapPanel Orientation="Horizontal"/>
                                                                </ItemsPanelTemplate>
                                                            </ItemsControl.ItemsPanel>
                                                        </ItemsControl>
                                                    </Border>
                                                    
                                                    <TextBlock x:Name="LblPartitionPreview" FontSize="10" Foreground="#64748B" TextWrapping="Wrap" FontFamily="Consolas" Text="Lütfen bir disk seçin"/>
                                                </StackPanel>
                                            </Border>
                                            
                                            <Border Background="#FEF3C7" CornerRadius="4" Padding="8,6">
                                                <TextBlock FontSize="10" TextWrapping="Wrap" Foreground="#92400E"
                                                    Text="UYARI: Seçilen disk tamamen silinecek ve yeniden bölümlenecektir. İşlem tamamlandıktan sonra bcdboot ile boot kaydı oluşturulacaktır."/>
                                            </Border>
                                        </StackPanel>
                                    </Border>

                                    <Border Style="{StaticResource CardStyle}" x:Name="PnlApplyVhd" Visibility="Collapsed">
                                        <StackPanel>
                                            <TextBlock Text="VHD / VHDX HEDEF" Style="{StaticResource CardTitle}"/>
                                            <Grid Margin="0,0,0,6">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Text="VHD Dosyası:" VerticalAlignment="Center" FontSize="11"/>
                                                <TextBox x:Name="TxtVhdPath" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Yeni veya mevcut .vhd / .vhdx dosyası"/>
                                                <Button x:Name="BtnVhdBrowse" Grid.Column="2" Content="Seç" Style="{StaticResource BtnOutline}" Margin="6,0,0,0" Height="22"/>
                                            </Grid>
                                            <Grid Margin="0,0,0,6">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock Text="VHD Boyutu:" VerticalAlignment="Center" FontSize="11"/>
                                                <StackPanel Grid.Column="1" Orientation="Horizontal">
                                                    <TextBox x:Name="TxtVhdSize" Width="70" Height="22" FontSize="11" Padding="4,2" Text="50"/>
                                                    <TextBlock Text=" GB  (Yeni VHD için)" VerticalAlignment="Center" FontSize="10" Foreground="#6B7280"/>
                                                </StackPanel>
                                            </Grid>
                                            <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
                                                <RadioButton x:Name="RdoVhdFixed"   Content="Fixed"   GroupName="VhdType" FontSize="11" Margin="0,0,16,0"/>
                                                <RadioButton x:Name="RdoVhdDynamic" Content="Dynamic" GroupName="VhdType" IsChecked="True" FontSize="11"/>
                                            </StackPanel>
                                            <TextBlock FontSize="10" Foreground="#6B7280" TextWrapping="Wrap"
                                                Text="Mevcut bir VHD/VHDX seçilirse boyut ve tür görmezden gelinir. Yeni bir yol girilirse belirtilen boyutta VHD oluşturulur."/>
                                        </StackPanel>
                                    </Border>

                                    <Border Style="{StaticResource CardStyle}">
                                        <StackPanel>
                                            <CheckBox x:Name="ChkUseUnattend" Content="Unattend.xml ile uygula" FontSize="11" Margin="0,0,0,6"/>
                                            <Grid x:Name="PnlUnattend" Visibility="Collapsed">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Text="Unattend.xml:" VerticalAlignment="Center" FontSize="11"/>
                                                <TextBox x:Name="TxtUnattendApply" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Unattend.xml dosyasını seçin"/>
                                                <Button x:Name="BtnUnattendApplyBrowse" Grid.Column="2" Content="Seç" Style="{StaticResource BtnOutline}" Margin="6,0,0,0" Height="22"/>
                                            </Grid>
                                        </StackPanel>
                                    </Border>

                                    <WrapPanel>
                                        <Button x:Name="BtnApplyImage" Content="▶ İmajı Uygula" Style="{StaticResource BtnAccent}"/>
                                    </WrapPanel>
                                </StackPanel>
                            </ScrollViewer>
                        </Grid>
                        <Grid x:Name="Pg_8" Visibility="Collapsed">
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                            <TextBlock Text="Export &amp; Consolidate" FontSize="16" FontWeight="Bold" Margin="0,0,0,10" Foreground="#111827"/>
                            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                <StackPanel>
                                    <Border Style="{StaticResource CardStyle}">
                                        <StackPanel>
                                            <TextBlock Text="INDEX &amp; SIKIŞTURMA" Style="{StaticResource CardTitle}"/>
                                            
                                            <Grid Margin="0,0,0,8">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="Auto"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                </Grid.ColumnDefinitions>
                                                <Grid.RowDefinitions>
                                                    <RowDefinition Height="Auto"/>
                                                </Grid.RowDefinitions>
                                                
                                                <TextBlock Grid.Row="0" Grid.Column="0" Text="Kaynak İmaj:" VerticalAlignment="Center" Margin="0,0,10,0" FontSize="11"/>
                                                <TextBox Grid.Row="0" Grid.Column="1" x:Name="TxtExportIndexSource" Style="{StaticResource RndTxt}" 
                                                         Tag="WIM/ESD dosyası seçin..." IsReadOnly="True" Background="#F3F4F6"/>
                                                <Button Grid.Row="0" Grid.Column="2" x:Name="BtnExportIndexBrowse" Content="Gözat" 
                                                        Style="{StaticResource BtnOutline}" Height="22" Width="60" Margin="6,0,0,0"/>
                                                <Button Grid.Row="0" Grid.Column="3" x:Name="BtnExportIndexRefresh" Content="Yenile" 
                                                        Style="{StaticResource BtnOutline}" Height="22" Width="60" Margin="4,0,0,0"/>
                                            </Grid>
                                            
                                            <TextBlock Text="İhraç Edilecek Index'ler:" FontSize="11" Margin="0,0,0,4" Foreground="#6B7280"/>
                                            <Border BorderBrush="#D1D5DB" BorderThickness="1" Background="White" CornerRadius="6" Height="160">
                                                <Grid>
                                                    <Grid.RowDefinitions>
                                                        <RowDefinition Height="Auto"/>
                                                        <RowDefinition Height="*"/>
                                                    </Grid.RowDefinitions>
                                                    
                                                    <Border Grid.Row="0" Background="#F9FAFB" BorderBrush="#E5E7EB" BorderThickness="0,0,0,1" Padding="8,6">
                                                        <Grid>
                                                            <Grid.ColumnDefinitions>
                                                                <ColumnDefinition Width="35"/>
                                                                <ColumnDefinition Width="45"/>
                                                                <ColumnDefinition Width="*"/>
                                                                <ColumnDefinition Width="80"/>
                                                            </Grid.ColumnDefinitions>
                                                            <TextBlock Grid.Column="0" Text="✓" FontSize="11" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                            <TextBlock Grid.Column="1" Text="#" FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                            <TextBlock Grid.Column="2" Text="Index Adı" FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                            <TextBlock Grid.Column="3" Text="Boyut" FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center" TextAlignment="Right"/>
                                                        </Grid>
                                                    </Border>
                                                    
                                                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                                        <ListView x:Name="ListViewExportIndex" BorderThickness="0" Background="Transparent" Padding="0">
                                                            <ListView.ItemContainerStyle>
                                                                <Style TargetType="ListViewItem">
                                                                    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                                                                    <Setter Property="Padding" Value="0"/>
                                                                    <Setter Property="Margin" Value="0"/>
                                                                    <Setter Property="BorderThickness" Value="0"/>
                                                                    <Style.Triggers>
                                                                        <Trigger Property="IsMouseOver" Value="True">
                                                                            <Setter Property="Background" Value="#F3F4F6"/>
                                                                        </Trigger>
                                                                    </Style.Triggers>
                                                                </Style>
                                                            </ListView.ItemContainerStyle>
                                                            <ListView.ItemTemplate>
                                                                <DataTemplate>
                                                                    <Border Padding="8,4" BorderBrush="#F3F4F6" BorderThickness="0,0,0,1">
                                                                        <Grid>
                                                                            <Grid.ColumnDefinitions>
                                                                                <ColumnDefinition Width="35"/>
                                                                                <ColumnDefinition Width="45"/>
                                                                                <ColumnDefinition Width="*"/>
                                                                                <ColumnDefinition Width="80"/>
                                                                            </Grid.ColumnDefinitions>
                                                                            
                                                                            <CheckBox Grid.Column="0" IsChecked="{Binding IsSelected, Mode=TwoWay}" 
                                                                                      VerticalAlignment="Center"/>
                                                                            
                                                                            <TextBlock Grid.Column="1" Text="{Binding IndexNumber}" FontWeight="SemiBold" 
                                                                                       Foreground="#3B82F6" FontSize="11" VerticalAlignment="Center"/>
                                                                            
                                                                            <TextBlock Grid.Column="2" VerticalAlignment="Center">
                                                                                <Run Text="{Binding IndexName}" FontWeight="Medium" FontSize="11" Foreground="#111827"/>
                                                                                <Run Text="{Binding Description, StringFormat=' — {0}'}" FontSize="10" Foreground="#9CA3AF"/>
                                                                            </TextBlock>
                                                                            
                                                                            <TextBlock Grid.Column="3" Text="{Binding SizeText}" FontSize="10" 
                                                                                       Foreground="#6B7280" VerticalAlignment="Center" TextAlignment="Right"/>
                                                                        </Grid>
                                                                    </Border>
                                                                </DataTemplate>
                                                            </ListView.ItemTemplate>
                                                        </ListView>
                                                    </ScrollViewer>
                                                </Grid>
                                            </Border>
                                            
                                            <TextBlock Margin="0,4,0,8" FontSize="10" Foreground="#6B7280">
                                                <Run x:Name="TxtExportIndexCount" Text="Seçili: 0"/>
                                            </TextBlock>
                                            
                                            <Grid Margin="0,0,0,8">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="Auto"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                </Grid.ColumnDefinitions>
                                                <TextBlock Grid.Column="0" Text="Hedef Dosya:" VerticalAlignment="Center" Margin="0,0,10,0" FontSize="11"/>
                                                <TextBox Grid.Column="1" x:Name="TxtExportFileName" Style="{StaticResource RndTxt}" 
                                                         Tag="Kaydet butonuyla hedef dosyayı seçin..." IsReadOnly="True" Background="#F3F4F6"/>
                                                <Button Grid.Column="2" x:Name="BtnExportChooseFileName" Content="Kaydet" 
                                                        Style="{StaticResource BtnOutline}" Height="22" Width="60" Margin="6,0,0,0" ToolTip="Hedef dosyayı seç"/>
                                            </Grid>
                                            
                                            <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                                <TextBlock Text="Sıkıştırma:" VerticalAlignment="Center" Margin="0,0,10,0" FontSize="11"/>
                                                <ComboBox x:Name="CmbExportCompression" Height="22" Width="100" FontSize="11">
                                                    <ComboBoxItem Content="recovery" IsSelected="True"/>
                                                    <ComboBoxItem Content="max"/>
                                                    <ComboBoxItem Content="fast"/>
                                                    <ComboBoxItem Content="none"/>
                                                </ComboBox>
                                            </StackPanel>
                                            
                                            <Grid Margin="0,0,0,2">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                </Grid.ColumnDefinitions>
                                                
                                                <StackPanel Grid.Column="0">
                                                    <StackPanel Orientation="Horizontal" Margin="0,0,0,1">
                                                        <CheckBox x:Name="ChkExportBootable" Content="/Bootable" FontSize="11" Width="110"/>
                                                        <TextBlock Foreground="#DC2626" FontSize="9" VerticalAlignment="Center"
                                                                   Text="Yalnızca WinPE/boot.wim için geçerlidir. Normal install.wim'de hiçbir etkisi yoktur."/>
                                                    </StackPanel>
                                                    <StackPanel Orientation="Horizontal" Margin="0,0,0,1">
                                                        <CheckBox x:Name="ChkExportWimBoot" Content="/WimBoot" FontSize="11" Width="110"/>
                                                        <TextBlock Foreground="#DC2626" FontSize="9" VerticalAlignment="Center"
                                                                   Text="Windows 8.1 dönemi özelliği, kullanımdan kalkmış. Modern sistemlerde desteklenmez."/>
                                                    </StackPanel>
                                                    <StackPanel Orientation="Horizontal">
                                                        <CheckBox x:Name="ChkExportCheckIntegrity" Content="/CheckIntegrity" FontSize="11" Width="110"/>
                                                        <TextBlock Foreground="#DC2626" FontSize="9" VerticalAlignment="Center"
                                                                   Text="İmaj bütünlüğünü doğrular, export süresi uzar."/>
                                                    </StackPanel>
                                                </StackPanel>
                                                
                                                <Button Grid.Column="1" x:Name="BtnExportImage" Content="İmajı Dışa Aktar / Birleştir" 
                                                        Style="{StaticResource BtnAccent}" Height="28" MinWidth="160" VerticalAlignment="Bottom"/>
                                            </Grid>
                                        </StackPanel>
                                    </Border>

                                    <Border Style="{StaticResource CardStyle}">
                                        <StackPanel>
                                            <TextBlock Text="INDEX SİLME" Style="{StaticResource CardTitle}"/>
                                            
                                            <Grid Margin="0,0,0,8">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="Auto"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                </Grid.ColumnDefinitions>
                                                <Grid.RowDefinitions>
                                                    <RowDefinition Height="Auto"/>
                                                </Grid.RowDefinitions>
                                                
                                                <TextBlock Grid.Row="0" Grid.Column="0" Text="Kaynak İmaj:" VerticalAlignment="Center" Margin="0,0,10,0" FontSize="11"/>
                                                <TextBox Grid.Row="0" Grid.Column="1" x:Name="TxtDeleteIndexSource" Style="{StaticResource RndTxt}" 
                                                         Tag="WIM/ESD dosyası seçin..." IsReadOnly="True" Background="#F3F4F6"/>
                                                <Button Grid.Row="0" Grid.Column="2" x:Name="BtnDeleteIndexBrowse" Content="Gözat" 
                                                        Style="{StaticResource BtnOutline}" Height="22" Width="60" Margin="6,0,0,0"/>
                                                <Button Grid.Row="0" Grid.Column="3" x:Name="BtnDeleteIndexRefresh" Content="Yenile" 
                                                        Style="{StaticResource BtnOutline}" Height="22" Width="60" Margin="4,0,0,0"/>
                                            </Grid>
                                            
                                            <TextBlock Text="Silinecek Index'ler:" FontSize="11" Margin="0,0,0,4" Foreground="#6B7280"/>
                                            <Border BorderBrush="#D1D5DB" BorderThickness="1" Background="White" CornerRadius="6" Height="180">
                                                <Grid>
                                                    <Grid.RowDefinitions>
                                                        <RowDefinition Height="Auto"/>
                                                        <RowDefinition Height="*"/>
                                                    </Grid.RowDefinitions>
                                                    
                                                    <Border Grid.Row="0" Background="#F9FAFB" BorderBrush="#E5E7EB" BorderThickness="0,0,0,1" Padding="8,6">
                                                        <Grid>
                                                            <Grid.ColumnDefinitions>
                                                                <ColumnDefinition Width="35"/>
                                                                <ColumnDefinition Width="45"/>
                                                                <ColumnDefinition Width="*"/>
                                                                <ColumnDefinition Width="80"/>
                                                            </Grid.ColumnDefinitions>
                                                            <CheckBox x:Name="ChkSelectAllHeader" Grid.Column="0" VerticalAlignment="Center"/>
                                                            <TextBlock Grid.Column="1" Text="#" FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                            <TextBlock Grid.Column="2" Text="Index Adı" FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center"/>
                                                            <TextBlock Grid.Column="3" Text="Boyut" FontSize="10" FontWeight="SemiBold" Foreground="#6B7280" VerticalAlignment="Center" TextAlignment="Right"/>
                                                        </Grid>
                                                    </Border>
                                                    
                                                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                                        <ListView x:Name="ListViewDeleteIndex" BorderThickness="0" Background="Transparent" Padding="0">
                                                            <ListView.ItemContainerStyle>
                                                                <Style TargetType="ListViewItem">
                                                                    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                                                                    <Setter Property="Padding" Value="0"/>
                                                                    <Setter Property="Margin" Value="0"/>
                                                                    <Setter Property="BorderThickness" Value="0"/>
                                                                    <Style.Triggers>
                                                                        <Trigger Property="IsMouseOver" Value="True">
                                                                            <Setter Property="Background" Value="#F3F4F6"/>
                                                                        </Trigger>
                                                                    </Style.Triggers>
                                                                </Style>
                                                            </ListView.ItemContainerStyle>
                                                            <ListView.ItemTemplate>
                                                                <DataTemplate>
                                                                    <Border Padding="8,4" BorderBrush="#F3F4F6" BorderThickness="0,0,0,1">
                                                                        <Grid>
                                                                            <Grid.ColumnDefinitions>
                                                                                <ColumnDefinition Width="35"/>
                                                                                <ColumnDefinition Width="45"/>
                                                                                <ColumnDefinition Width="*"/>
                                                                                <ColumnDefinition Width="80"/>
                                                                            </Grid.ColumnDefinitions>
                                                                            
                                                                            <CheckBox Grid.Column="0" IsChecked="{Binding IsSelected, Mode=TwoWay}" 
                                                                                      VerticalAlignment="Center"/>
                                                                            
                                                                            <TextBlock Grid.Column="1" Text="{Binding IndexNumber}" FontWeight="SemiBold" 
                                                                                       Foreground="#3B82F6" FontSize="11" VerticalAlignment="Center"/>
                                                                            
                                                                            <TextBlock Grid.Column="2" VerticalAlignment="Center">
                                                                                <Run Text="{Binding IndexName}" FontWeight="Medium" FontSize="11" Foreground="#111827"/>
                                                                                <Run Text="{Binding Description, StringFormat=' — {0}'}" FontSize="10" Foreground="#9CA3AF"/>
                                                                            </TextBlock>
                                                                            
                                                                            <TextBlock Grid.Column="3" Text="{Binding SizeText}" FontSize="10" 
                                                                                       Foreground="#6B7280" VerticalAlignment="Center" TextAlignment="Right"/>
                                                                        </Grid>
                                                                    </Border>
                                                                </DataTemplate>
                                                            </ListView.ItemTemplate>
                                                        </ListView>
                                                    </ScrollViewer>
                                                </Grid>
                                            </Border>
                                            
                                            <Grid Margin="0,8,0,0">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                </Grid.ColumnDefinitions>
                                                
                                                <TextBlock Grid.Column="0" VerticalAlignment="Center" FontSize="10" Foreground="#6B7280">
                                                    <Run x:Name="TxtDeleteIndexCount" Text="Seçili: 0"/>
                                                </TextBlock>
                                                
                                                <StackPanel Grid.Column="1" Orientation="Horizontal">
                                                    <Button x:Name="BtnDeleteIndex" Content="Index'leri Sil" Style="{StaticResource BtnAccent}" 
                                                            Height="26" Width="100" FontSize="11"/>
                                                </StackPanel>
                                            </Grid>
                                        </StackPanel>
                                    </Border>
                                </StackPanel>
                            </ScrollViewer>
                        </Grid>

                        <Grid x:Name="Pg_9" Visibility="Collapsed">
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                            <TextBlock Text="Split Media (SWM)" FontSize="16" FontWeight="Bold" Margin="0,0,0,10" Foreground="#111827"/>
                            <StackPanel Grid.Row="1">
                                <Border Style="{StaticResource CardStyle}">
                                    <StackPanel>
                                        <TextBlock Text="BÖLME AYARLARI" Style="{StaticResource CardTitle}"/>
                                        <Grid Margin="0,0,0,6">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="Kaynak WIM:" VerticalAlignment="Center" FontSize="11"/>
                                            <TextBox x:Name="TxtSplitSourceWim" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Parçalara ayrılacak büyük WIM dosyasını seçin..."/>
                                            <Button x:Name="BtnSplitChooseWim" Grid.Column="2" Content="..." Style="{StaticResource BtnOutline}" Margin="6,0,0,0" Height="22"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,6">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="Hedef Dizin:" VerticalAlignment="Center" FontSize="11"/>
                                            <TextBox x:Name="TxtSplitDestDir" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="SWM parçalarının kaydedileceği klasör..."/>
                                            <Button x:Name="BtnSplitChooseDir" Grid.Column="2" Content="..." Style="{StaticResource BtnOutline}" Margin="6,0,0,0" Height="22"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,6">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="SWM Dosya Adı:" VerticalAlignment="Center" FontSize="11"/>
                                            <TextBox x:Name="TxtSplitSwmName" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Oluşacak parçaların ortak adı (Örn: install.swm)"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>
                                <Border Style="{StaticResource CardStyle}">
                                    <StackPanel Orientation="Horizontal">
                                        <TextBlock Text="Parça Boyutu (MB):" VerticalAlignment="Center" Margin="0,0,10,0" FontSize="11"/>
                                        <TextBox x:Name="TxtSplitSize" Width="100" Style="{StaticResource RndTxt}" Text="4000"/>
                                        <TextBlock Text="(FAT32 sınırları için max 4000 MB önerilir)" VerticalAlignment="Center" Margin="15,0,0,0" FontSize="10" Foreground="#6B7280"/>
                                        <CheckBox x:Name="ChkSplitCheckIntegrity" Content="/CheckIntegrity" Margin="20,0,0,0" VerticalAlignment="Center" FontSize="11"/>
                                    </StackPanel>
                                </Border>
                                <WrapPanel>
                                    <Button x:Name="BtnSplitImage" Content="SWM Olarak Parçala" Style="{StaticResource BtnAccent}"/>
                                </WrapPanel>
                            </StackPanel>
                        </Grid>

                        <Grid x:Name="Pg_10" Visibility="Collapsed">
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                            <TextBlock Text="Regional Settings" FontSize="16" FontWeight="Bold" Margin="0,0,0,10" Foreground="#111827"/>
                            <StackPanel Grid.Row="1">
                                <Border Style="{StaticResource CardStyle}">
                                    <StackPanel>
                                        <TextBlock Text="DİL VE BÖLGE PAKETLERİ" Style="{StaticResource CardTitle}"/>
                                        <Grid Margin="0,0,0,6">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="85"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="Dil Kodu:" VerticalAlignment="Center" FontSize="11"/>
                                            <TextBox x:Name="TxtLangCode" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Ayarla (Örn: tr-TR, en-US)"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,6">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="85"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="Zaman Dilimi:" VerticalAlignment="Center" FontSize="11"/>
                                            <TextBox x:Name="TxtTimezone" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="(Örn: Turkey Standard Time)"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>
                                <WrapPanel>
                                    <Button x:Name="BtnApplyLang"    Content="Ayarları Uygula"        Style="{StaticResource BtnAccent}"/>
                                    <Button x:Name="BtnGetLangInfo"  Content="Mevcut Dil Bilgisini Al" Style="{StaticResource BtnOutline}"/>
                                </WrapPanel>
                            </StackPanel>
                        </Grid>

                        <Grid x:Name="Pg_11" Visibility="Collapsed">
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                            <TextBlock Text="FFU Storage Flash" FontSize="16" FontWeight="Bold" Margin="0,0,0,10" Foreground="#111827"/>
                            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                <StackPanel>
                                    <Border Style="{StaticResource CardStyle}">
                                        <StackPanel>
                                            <TextBlock Text="CAPTURE FFU (SEKTÖR YAKALAMA)" Style="{StaticResource CardTitle}"/>
                                            <Grid Margin="0,0,0,6">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="85"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock Text="Fiziksel Disk:" VerticalAlignment="Center" FontSize="11"/>
                                                <TextBox x:Name="TxtFfuCapturePhysDrive" Grid.Column="1" Style="{StaticResource RndTxt}" Text="\\.\PhysicalDrive0"/>
                                            </Grid>
                                            <Grid Margin="0,0,0,6">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="85"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Text="Hedef Dosya:" VerticalAlignment="Center" FontSize="11"/>
                                                <TextBox x:Name="TxtFfuCaptureDest" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Örn: C:\backup.ffu"/>
                                                <Button x:Name="BtnFfuCaptureDest" Grid.Column="2" Content="..." Style="{StaticResource BtnOutline}" Margin="6,0,0,0" Height="22"/>
                                            </Grid>
                                            <Button x:Name="BtnCaptureFfu" Content="Sektörleri Yakala" Style="{StaticResource BtnAccent}" HorizontalAlignment="Left"/>
                                        </StackPanel>
                                    </Border>
                                    <Border Style="{StaticResource CardStyle}">
                                        <StackPanel>
                                            <TextBlock Text="APPLY FFU (DİSKE YAZMA)" Style="{StaticResource CardTitle}"/>
                                            <Grid Margin="0,0,0,6">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="85"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Text="FFU Dosyası:" VerticalAlignment="Center" FontSize="11"/>
                                                <TextBox x:Name="TxtFfuApplySource" Grid.Column="1" Style="{StaticResource RndTxt}" Tag="Geri yüklenecek .ffu dosyasını seçin..."/>
                                                <Button x:Name="BtnFfuApplySource" Grid.Column="2" Content="..." Style="{StaticResource BtnOutline}" Margin="6,0,0,0" Height="22"/>
                                            </Grid>
                                            <Grid Margin="0,0,0,6">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="85"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock Text="Hedef Disk:" VerticalAlignment="Center" FontSize="11"/>
                                                <TextBox x:Name="TxtFfuApplyDrive" Grid.Column="1" Style="{StaticResource RndTxt}" Text="\\.\PhysicalDrive0"/>
                                            </Grid>
                                            <Button x:Name="BtnApplyFfu" Content="Diske Uygula (Uyarı: Veriler Silinir)" Style="{StaticResource BtnDanger}" HorizontalAlignment="Left"/>
                                        </StackPanel>
                                    </Border>
                                </StackPanel>
                            </ScrollViewer>
                        </Grid>

                        <Grid x:Name="Pg_12" Visibility="Collapsed"><TextBlock Text="Store Package Fetcher — Yakında" FontSize="14" Foreground="#9CA3AF" VerticalAlignment="Center" HorizontalAlignment="Center"/></Grid>
                        <Grid x:Name="Pg_13" Visibility="Collapsed"><TextBlock Text="Offline Provisioning — Yakında"  FontSize="14" Foreground="#9CA3AF" VerticalAlignment="Center" HorizontalAlignment="Center"/></Grid>
                        <Grid x:Name="Pg_14" Visibility="Collapsed">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <TextBlock Text="Offline Registry" FontSize="16" FontWeight="Bold" Margin="0,0,0,10" Foreground="#111827"/>

                            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                <StackPanel>

                                    <Border Style="{StaticResource CardStyle}">
                                        <StackPanel>
                                            <TextBlock Text="HİVE YÖNETİMİ" Style="{StaticResource CardTitle}"/>

                                            <Grid Margin="0,0,0,8">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="90"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                </Grid.ColumnDefinitions>
                                                <TextBlock Text="Mount Dizini:" VerticalAlignment="Center" FontSize="11" Foreground="#6B7280"/>
                                                <TextBox x:Name="TxtRegMountDir" Grid.Column="1"
                                                         Style="{StaticResource RndTxt}" Margin="0,0,6,0"
                                                         Tag="WIM mount dizini (otomatik doldurulur veya manuel girin)..."/>
                                                <Button x:Name="BtnRegBrowseMountDir" Grid.Column="2"
                                                        Content="Gözat" Style="{StaticResource BtnOutline}"
                                                        Height="22" Padding="10,0"/>
                                            </Grid>

                                            <TextBlock Text="Yüklenecek hive:" FontSize="10" Foreground="#6B7280" Margin="0,0,0,6"/>
                                            <Grid Margin="0,0,0,8">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                </Grid.ColumnDefinitions>
                                                <Button x:Name="BtnRegLoadSoftware" Grid.Column="0" Content="SOFTWARE"   Style="{StaticResource BtnOutline}" Height="26" Padding="0" Margin="0,0,4,0"/>
                                                <Button x:Name="BtnRegLoadSystem"   Grid.Column="1" Content="SYSTEM"     Style="{StaticResource BtnOutline}" Height="26" Padding="0" Margin="0,0,4,0"/>
                                                <Button x:Name="BtnRegLoadDefault"  Grid.Column="2" Content="DEFAULT"    Style="{StaticResource BtnOutline}" Height="26" Padding="0" Margin="0,0,4,0"/>
                                                <Button x:Name="BtnRegLoadSam"      Grid.Column="3" Content="SAM"        Style="{StaticResource BtnOutline}" Height="26" Padding="0" Margin="0,0,4,0"/>
                                                <Button x:Name="BtnRegLoadNtuser"   Grid.Column="4" Content="NTUSER.DAT" Style="{StaticResource BtnOutline}" Height="26" Padding="0"/>
                                            </Grid>

                                            <Border x:Name="RegHiveStatusBorder"
                                                    Background="#F0FDF4" BorderBrush="#BBF7D0"
                                                    BorderThickness="1" CornerRadius="4" Padding="10,6">
                                                <Grid>
                                                    <Grid.ColumnDefinitions>
                                                        <ColumnDefinition Width="*"/>
                                                        <ColumnDefinition Width="Auto"/>
                                                    </Grid.ColumnDefinitions>
                                                    <TextBlock x:Name="TxtRegHiveStatus"
                                                               Text="Hiç hive yüklü değil."
                                                               FontSize="10" Foreground="#166534"
                                                               VerticalAlignment="Center" TextWrapping="Wrap"/>
                                                    <Button x:Name="BtnRegUnloadAll" Grid.Column="1"
                                                            Content="Tümünü Kaldır" Style="{StaticResource BtnDanger}"
                                                            Height="22" Padding="10,0" Visibility="Collapsed"/>
                                                </Grid>
                                            </Border>
                                        </StackPanel>
                                    </Border>

                                    <Border Style="{StaticResource CardStyle}">
                                        <StackPanel>
                                            <TextBlock Text=".REG DOSYASI İÇE / DIŞA AKTAR" Style="{StaticResource CardTitle}"/>
                                            <TextBlock Text="İçe Aktar" FontSize="10" FontWeight="SemiBold" Foreground="#374151" Margin="0,0,0,4"/>
                                            <Grid Margin="0,0,0,10">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                </Grid.ColumnDefinitions>
                                                <TextBox x:Name="TxtRegImportFile" Grid.Column="0"
                                                         Style="{StaticResource RndTxt}" Margin="0,0,6,0"
                                                         Tag=".reg dosyası seçin..."/>
                                                <Button x:Name="BtnRegImportBrowse" Grid.Column="1"
                                                        Content="..." Style="{StaticResource BtnOutline}"
                                                        Height="22" Padding="8,0" Margin="0,0,4,0"/>
                                                <Button x:Name="BtnRegImport" Grid.Column="2"
                                                        Content="📥  İçe Aktar" Style="{StaticResource BtnAccent}"
                                                        Height="22" Padding="12,0"/>
                                            </Grid>
                                            <TextBlock Text="Dışa Aktar (Key yolundan)" FontSize="10" FontWeight="SemiBold" Foreground="#374151" Margin="0,0,0,4"/>
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                </Grid.ColumnDefinitions>
                                                <TextBox x:Name="TxtRegExportKey" Grid.Column="0"
                                                         Style="{StaticResource RndTxt}" Margin="0,0,6,0"
                                                         Tag="Örn: HKLM\_OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion"/>
                                                <Button x:Name="BtnRegExport" Grid.Column="1"
                                                        Content="📤  Dışa Aktar" Style="{StaticResource BtnOutline}"
                                                        Height="22" Padding="12,0"/>
                                            </Grid>
                                        </StackPanel>
                                    </Border>

                                    <Border Style="{StaticResource CardStyle}">
                                        <StackPanel>
                                            <Grid Margin="0,0,0,8">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                </Grid.ColumnDefinitions>
                                                <TextBlock Text="HAZIR AYARLAR (PRESET TWEAKS)" Style="{StaticResource CardTitle}" Margin="0"/>
                                                <Button x:Name="BtnRegApplySelected" Grid.Column="1"
                                                        Content="✔  Seçilileri Uygula" Style="{StaticResource BtnGreen}"
                                                        Height="24" Padding="12,0" Margin="0,0,6,0"/>
                                                <Button x:Name="BtnRegSelectAllTweaks" Grid.Column="2"
                                                        Content="Tümünü Seç" Style="{StaticResource BtnOutline}"
                                                        Height="24" Padding="10,0"/>
                                            </Grid>

                                            <TextBlock Text="GİZLİLİK" FontSize="9" FontWeight="Bold" Foreground="#5A86B5" Margin="0,4,0,4"/>
                                            <WrapPanel Margin="0,0,0,8">
                                                <CheckBox x:Name="ChkTweakTelemetry"       Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Telemetri" FontWeight="SemiBold"/><Run Text=" (DiagTrack, CEIP)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakCortana"         Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Cortana" FontWeight="SemiBold"/><Run Text=" (sesli asistan)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakActivityHistory" Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Etkinlik Geçmişi" FontWeight="SemiBold"/><Run Text=" (Timeline)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakAdId"            Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Reklam Kimliği" FontWeight="SemiBold"/><Run Text=" (AAID)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakFeedback"        Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Geri Bildirim" FontWeight="SemiBold"/><Run Text=" (Windows Feedback)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakAppCompat"       Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Uygulama Uyumluluk Telemetri" FontWeight="SemiBold"/></TextBlock></CheckBox>
                                            </WrapPanel>

                                            <TextBlock Text="GÜVENLİK" FontSize="9" FontWeight="Bold" Foreground="#5A86B5" Margin="0,4,0,4"/>
                                            <WrapPanel Margin="0,0,0,8">
                                                <CheckBox x:Name="ChkTweakDefender"        Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Windows Defender" FontWeight="SemiBold"/><Run Text=" (RealtimeMonitoring kapat)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakSmartScreen"     Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="SmartScreen" FontWeight="SemiBold"/><Run Text=" (kapat)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakUac"             Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="UAC Seviye Düşür" FontWeight="SemiBold"/><Run Text=" (bildirim azalt)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakAutoplay"        Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="AutoPlay/AutoRun" FontWeight="SemiBold"/><Run Text=" (devre dışı)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                            </WrapPanel>

                                            <TextBlock Text="GÜNCELLEME" FontSize="9" FontWeight="Bold" Foreground="#5A86B5" Margin="0,4,0,4"/>
                                            <WrapPanel Margin="0,0,0,8">
                                                <CheckBox x:Name="ChkTweakWuAuto"          Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Otomatik Güncelleme" FontWeight="SemiBold"/><Run Text=" (bildir, otomatik kurma)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakDeliveryOpt"     Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Delivery Optimization" FontWeight="SemiBold"/><Run Text=" (P2P kapat)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakMsrt"            Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="MSRT Kötü Amaçlı Yazılım Aracı" FontWeight="SemiBold"/><Run Text=" (devre dışı)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                            </WrapPanel>

                                            <TextBlock Text="PERFORMANS / KULLANICI ARAYÜZÜ" FontSize="9" FontWeight="Bold" Foreground="#5A86B5" Margin="0,4,0,4"/>
                                            <WrapPanel Margin="0,0,0,8">
                                                <CheckBox x:Name="ChkTweakVerboseBoot"     Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Verbose Boot" FontWeight="SemiBold"/><Run Text=" (ayrıntılı açılış mesajları)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakAnimations"      Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Animasyonlar" FontWeight="SemiBold"/><Run Text=" (kapat)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakNewsInterests"   Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Haberler ve İlgi Alanları" FontWeight="SemiBold"/><Run Text=" (görev çubuğu widgetı kapat)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakStartSugg"       Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Başlat Menüsü Önerileri" FontWeight="SemiBold"/><Run Text=" (kapat)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakSearchTaskbar"   Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Görev Çubuğu Arama" FontWeight="SemiBold"/><Run Text=" (simge moduna al)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakTaskView"        Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Görev Görünümü" FontWeight="SemiBold"/><Run Text=" (görev çubuğunda gizle)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakCopilot"         Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Copilot" FontWeight="SemiBold"/><Run Text=" (devre dışı bırak)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                            </WrapPanel>

                                            <TextBlock Text="AĞ / DİĞER" FontSize="9" FontWeight="Bold" Foreground="#5A86B5" Margin="0,4,0,4"/>
                                            <WrapPanel>
                                                <CheckBox x:Name="ChkTweakNbns"            Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="NBNS / LLMNR" FontWeight="SemiBold"/><Run Text=" (devre dışı)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakIpv6"            Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="IPv6" FontWeight="SemiBold"/><Run Text=" (devre dışı)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakHibernation"     Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Hazırda Bekletme" FontWeight="SemiBold"/><Run Text=" (hiberfil.sys sil)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakRemoteReg"       Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="Uzak Kayıt Defteri" FontWeight="SemiBold"/><Run Text=" (RemoteRegistry servisini kapat)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                                <CheckBox x:Name="ChkTweakLmHash"          Margin="0,0,16,4" FontSize="10"><TextBlock><Run Text="LM Hash" FontWeight="SemiBold"/><Run Text=" (NoLMHash etkinleştir)" Foreground="#9CA3AF"/></TextBlock></CheckBox>
                                            </WrapPanel>
                                        </StackPanel>
                                    </Border>

                                    <Border Style="{StaticResource CardStyle}">
                                        <StackPanel>
                                            <TextBlock Text="HİVE İÇİNDE ARAMA" Style="{StaticResource CardTitle}"/>
                                            <Grid Margin="0,0,0,6">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="70"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="120"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                </Grid.ColumnDefinitions>
                                                <TextBlock Text="Arama:" VerticalAlignment="Center" FontSize="11" Foreground="#6B7280"/>
                                                <TextBox x:Name="TxtRegSearchQuery" Grid.Column="1"
                                                         Style="{StaticResource RndTxt}" Margin="0,0,6,0"
                                                         Tag="Value adı veya veri içinde ara..."/>
                                                <ComboBox x:Name="CmbRegSearchHive" Grid.Column="2"
                                                          Height="22" FontSize="11" Margin="0,0,6,0"
                                                          BorderBrush="#D1D5DB" Background="#F9FAFB">
                                                    <ComboBoxItem Content="SOFTWARE"   IsSelected="True"/>
                                                    <ComboBoxItem Content="SYSTEM"/>
                                                    <ComboBoxItem Content="DEFAULT"/>
                                                    <ComboBoxItem Content="NTUSER.DAT"/>
                                                </ComboBox>
                                                <Button x:Name="BtnRegSearch" Grid.Column="3"
                                                        Content="🔍  Ara" Style="{StaticResource BtnAccent}"
                                                        Height="22" Padding="12,0"/>
                                            </Grid>
                                            <Border BorderBrush="#D1D5DB" BorderThickness="1"
                                                    CornerRadius="4" Background="White" MinHeight="60" MaxHeight="180">
                                                <ScrollViewer VerticalScrollBarVisibility="Auto">
                                                    <ListBox x:Name="LstRegSearchResults"
                                                             BorderThickness="0" Background="Transparent"
                                                             FontFamily="Consolas" FontSize="10"
                                                             Padding="6"/>
                                                </ScrollViewer>
                                            </Border>
                                        </StackPanel>
                                    </Border>

                                </StackPanel>
                            </ScrollViewer>
                        </Grid>

                    </Grid>

                    <StackPanel Grid.Row="2" Margin="15,0,15,5">
                        <Grid>
                            <TextBlock x:Name="LblProgressMsg" Text="Sistem Hazır." FontSize="10" Foreground="#6B7280" HorizontalAlignment="Left"  Margin="0,0,0,3"/>
                            <TextBlock x:Name="LblProgressPct" Text=""              FontSize="10" Foreground="#6B7280" HorizontalAlignment="Right" Margin="0,0,0,3"/>
                        </Grid>
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <ProgressBar x:Name="MainProgress" Grid.Column="0" Style="{StaticResource RndProgress}" Value="0" Maximum="100" VerticalAlignment="Center"/>
                            <Button x:Name="BtnCancelJob" Grid.Column="1" Content="✕ İptal" Visibility="Collapsed"
                                    Margin="8,0,0,0" Height="18" Padding="8,0" FontSize="9" FontWeight="SemiBold"
                                    Background="#EF4444" Foreground="White" Cursor="Hand" BorderThickness="0">
                                <Button.Template>
                                    <ControlTemplate TargetType="Button">
                                        <Border CornerRadius="3" Background="{TemplateBinding Background}">
                                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#DC2626"/></Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </Button.Template>
                            </Button>
                        </Grid>
                    </StackPanel>

                    <GridSplitter Grid.Row="2" Height="4" HorizontalAlignment="Stretch" VerticalAlignment="Bottom"
                                  Background="Transparent" Cursor="SizeNS" Margin="15,0,15,0"/>

                    <Border Grid.Row="3" Margin="15,0,15,10" CornerRadius="8" Background="#1E3250" ClipToBounds="True">
                        <Grid>
                            <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                            <Border Grid.Row="0" Background="#162640" CornerRadius="8,8,0,0">
                                <Grid Margin="12,0">
                                    <TextBlock Text="OUTPUT LOG" Foreground="#8EB4D8" FontWeight="Bold" VerticalAlignment="Center" FontSize="10"/>
                                    <Button x:Name="BtnClearLog" Content="Temizle" Cursor="Hand" HorizontalAlignment="Right" VerticalAlignment="Center"
                                            Padding="12,0" Height="18" FontSize="9" Background="#263F63" Foreground="#D1E4F3" BorderThickness="0">
                                        <Button.Template>
                                            <ControlTemplate TargetType="Button">
                                                <Border CornerRadius="3" Background="{TemplateBinding Background}">
                                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                                                </Border>
                                            </ControlTemplate>
                                        </Button.Template>
                                    </Button>
                                </Grid>
                            </Border>
                            <TextBox Grid.Row="1" x:Name="TxtConsole"
                                     Background="Transparent" Foreground="#A7F3D0"
                                     BorderThickness="0" FontFamily="Consolas" FontSize="11" Padding="12,8"
                                     TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto"
                                     HorizontalScrollBarVisibility="Auto" IsReadOnly="True"
                                     Text="WinImageStudio v1.0.1 — Sistem hazır"/>
                        </Grid>
                    </Border>

                    <Border x:Name="StatusBarBorder" Grid.Row="4" Background="White" BorderBrush="#E5E7EB" BorderThickness="0,1,0,0" CornerRadius="0,0,7,0">
                        <Grid Margin="12,0">
                            <StackPanel Orientation="Horizontal">
                                <Ellipse x:Name="StatusDot" Width="6" Height="6" Fill="#10B981" VerticalAlignment="Center"/>
                                <TextBlock x:Name="StatusText" Text="Ready" Margin="6,0,0,0" Foreground="#6B7280" VerticalAlignment="Center" FontSize="10"/>
                            </StackPanel>
                            <TextBlock Text="WinImage Studio 1.0" HorizontalAlignment="Right" Foreground="#9CA3AF" VerticalAlignment="Center" FontSize="10"/>
                        </Grid>
                    </Border>
                </Grid>
            </Grid>
        </Border>

        <Grid x:Name="AlertOverlay" Visibility="Collapsed" Background="#80000000">
            <Border Width="380" MinHeight="140" MaxHeight="520" Background="White" CornerRadius="8"
                    HorizontalAlignment="Center" VerticalAlignment="Center" BorderBrush="#D1D5DB" BorderThickness="1">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="35"/>
                        <RowDefinition Height="Auto" MinHeight="50" MaxHeight="400"/>
                        <RowDefinition Height="45"/>
                    </Grid.RowDefinitions>
                    <Border Grid.Row="0" Background="#37474F" CornerRadius="7,7,0,0">
                        <TextBlock x:Name="AlertTitle" Text="BİLGİLENDİRME" Foreground="White" FontWeight="Bold" FontSize="11" VerticalAlignment="Center" Margin="15,0"/>
                    </Border>
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="0">
                        <TextBlock x:Name="AlertMessage" Text="" TextWrapping="Wrap" Margin="15,10" FontSize="11" Foreground="#111827"/>
                    </ScrollViewer>
                    <Border Grid.Row="2" Background="#F9FAFB" CornerRadius="0,0,7,7" BorderBrush="#E5E7EB" BorderThickness="0,1,0,0">
                        <Button x:Name="BtnAlertOk" Content="Tamam" Style="{StaticResource BtnAccent}" Width="80" Height="26" Margin="0,0,12,0" HorizontalAlignment="Right"/>
                    </Border>
                </Grid>
            </Border>
        </Grid>
        
        <Grid x:Name="ClosingConfirmOverlay" Visibility="Collapsed" Background="#80000000" Panel.ZIndex="100">
            <Border Width="480" MinHeight="160" Background="White" CornerRadius="8"
                    HorizontalAlignment="Center" VerticalAlignment="Center" BorderBrush="#D1D5DB" BorderThickness="1">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="35"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="45"/>
                    </Grid.RowDefinitions>

                    <Border Grid.Row="0" Background="#37474F" CornerRadius="7,7,0,0">
                        <StackPanel Orientation="Horizontal" Margin="15,0">
                            <TextBlock Text="⚠️" FontSize="14" VerticalAlignment="Center" Margin="0,0,8,0"/>
                            <TextBlock x:Name="ClosingConfirmTitle" Text="WIM MOUNT AKTİF" Foreground="White" FontWeight="Bold" FontSize="11" VerticalAlignment="Center"/>
                        </StackPanel>
                    </Border>

                    <TextBlock Grid.Row="1" x:Name="ClosingConfirmMessage" TextWrapping="Wrap"
                               Margin="15,12" FontSize="11" Foreground="#111827"/>

                    <Border Grid.Row="2" Background="#F9FAFB" CornerRadius="0,0,7,7" BorderBrush="#E5E7EB" BorderThickness="0,1,0,0">
                        <Grid Margin="12,9,12,9">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="80"/>
                                <ColumnDefinition Width="8"/>
                                <ColumnDefinition Width="80"/>
                                <ColumnDefinition Width="8"/>
                                <ColumnDefinition Width="80"/>
                                <ColumnDefinition Width="8"/>
                                <ColumnDefinition Width="60"/>
                            </Grid.ColumnDefinitions>

                            <Button Grid.Column="1" x:Name="BtnClosingSave" Content="Kaydet" FontSize="11" FontWeight="SemiBold" Cursor="Hand" Padding="0" Margin="0">
                                <Button.Template>
                                    <ControlTemplate TargetType="Button">
                                        <Border Background="#3B82F6" CornerRadius="4" Height="26">
                                            <TextBlock Text="{TemplateBinding Content}" Foreground="White" FontSize="11" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                        </Border>
                                    </ControlTemplate>
                                </Button.Template>
                            </Button>

                            <Button Grid.Column="3" x:Name="BtnClosingDiscard" Content="Kaydetme" FontSize="11" FontWeight="SemiBold" Cursor="Hand" Padding="0" Margin="0">
                                <Button.Template>
                                    <ControlTemplate TargetType="Button">
                                        <Border Background="#F59E0B" CornerRadius="4" Height="26">
                                            <TextBlock Text="{TemplateBinding Content}" Foreground="White" FontSize="11" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                        </Border>
                                    </ControlTemplate>
                                </Button.Template>
                            </Button>

                            <Button Grid.Column="5" x:Name="BtnClosingForceClose" Content="Kapat" FontSize="11" FontWeight="SemiBold" Cursor="Hand" Padding="0" Margin="0">
                                <Button.Template>
                                    <ControlTemplate TargetType="Button">
                                        <Border Background="#B91C1C" CornerRadius="4" Height="26">
                                            <TextBlock Text="{TemplateBinding Content}" Foreground="White" FontSize="11" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                        </Border>
                                    </ControlTemplate>
                                </Button.Template>
                            </Button>

                            <Button Grid.Column="7" x:Name="BtnClosingCancel" Content="İptal" FontSize="11" FontWeight="SemiBold" Cursor="Hand" Padding="0" Margin="0">
                                <Button.Template>
                                    <ControlTemplate TargetType="Button">
                                        <Border Background="#6B7280" CornerRadius="4" Height="26">
                                            <TextBlock Text="{TemplateBinding Content}" Foreground="White" FontSize="11" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                        </Border>
                                    </ControlTemplate>
                                </Button.Template>
                            </Button>
                        </Grid>
                    </Border>
                </Grid>
            </Border>
        </Grid>
        <Grid x:Name="ConfirmOverlay" Visibility="Collapsed" Background="#80000000">
            <Border Width="420" MinHeight="160" MaxHeight="520" Background="White" CornerRadius="8"
                    HorizontalAlignment="Center" VerticalAlignment="Center" BorderBrush="#D1D5DB" BorderThickness="1">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="35"/>
                        <RowDefinition Height="Auto" MinHeight="50" MaxHeight="400"/>
                        <RowDefinition Height="45"/>
                    </Grid.RowDefinitions>
                    
                    <Border Grid.Row="0" Background="#37474F" CornerRadius="7,7,0,0">
                        <StackPanel Orientation="Horizontal" Margin="15,0">
                            <TextBlock x:Name="ConfirmIcon" Text="⚠️" FontSize="14" VerticalAlignment="Center" Margin="0,0,8,0"/>
                            <TextBlock x:Name="ConfirmTitle" Text="ONAY" Foreground="White" FontWeight="Bold" FontSize="11" VerticalAlignment="Center"/>
                        </StackPanel>
                    </Border>
                    
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="0">
                        <TextBlock x:Name="ConfirmMessage" Text="" TextWrapping="Wrap" 
                                   Margin="15,12" FontSize="11" Foreground="#111827"/>
                    </ScrollViewer>
                    
                    <Border Grid.Row="2" Background="#F9FAFB" CornerRadius="0,0,7,7" BorderBrush="#E5E7EB" BorderThickness="0,1,0,0">
                        <Grid Margin="12,9,12,9">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="70"/>
                                <ColumnDefinition Width="8"/>
                                <ColumnDefinition Width="70"/>
                            </Grid.ColumnDefinitions>
                            
                            <Button Grid.Column="1" x:Name="BtnConfirmNo" Content="Hayır" FontSize="11" FontWeight="SemiBold"
                                    Cursor="Hand" Padding="0" Margin="0">
                                <Button.Template>
                                    <ControlTemplate TargetType="Button">
                                        <Border Background="#6B7280" CornerRadius="4" Height="26" Width="70">
                                            <TextBlock Text="{TemplateBinding Content}" 
                                                       Foreground="White" 
                                                       FontSize="11" 
                                                       FontWeight="SemiBold"
                                                       HorizontalAlignment="Center" 
                                                       VerticalAlignment="Center"/>
                                        </Border>
                                    </ControlTemplate>
                                </Button.Template>
                            </Button>
                            
                            <Button Grid.Column="3" x:Name="BtnConfirmYes" Content="Evet" FontSize="11" FontWeight="SemiBold"
                                    Cursor="Hand" Padding="0" Margin="0">
                                <Button.Template>
                                    <ControlTemplate TargetType="Button">
                                        <Border Background="#3B82F6" CornerRadius="4" Height="26" Width="70">
                                            <TextBlock Text="{TemplateBinding Content}" 
                                                       Foreground="White" 
                                                       FontSize="11" 
                                                       FontWeight="SemiBold"
                                                       HorizontalAlignment="Center" 
                                                       VerticalAlignment="Center"/>
                                        </Border>
                                    </ControlTemplate>
                                </Button.Template>
                            </Button>
                        </Grid>
                    </Border>
                </Grid>
            </Border>
        </Grid>
    </Grid>
</Window>
"@

# ── XAML YÜKLENİYOR ──
$reader = New-Object System.Xml.XmlNodeReader([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# ── KONTROL REFERANSları ──
$MainBorder        = $window.FindName("MainBorder")
$SidebarBorder     = $window.FindName("SidebarBorder")
$SidebarBottomBorder = $window.FindName("SidebarBottomBorder")
$StatusBarBorder   = $window.FindName("StatusBarBorder")
$DragBar           = $window.FindName("DragBar")
$BtnMin         = $window.FindName("BtnMin")
$BtnMax         = $window.FindName("BtnMax")
$BtnClose       = $window.FindName("BtnClose")
$TxtConsole     = $window.FindName("TxtConsole")
$BtnClearLog    = $window.FindName("BtnClearLog")
$BtnCancelJob      = $window.FindName("BtnCancelJob")
$BusyOverlayMenu   = $window.FindName("BusyOverlayMenu")
$BusyOverlayContent= $window.FindName("BusyOverlayContent")
$MainProgress   = $window.FindName("MainProgress")
$LblProgressMsg = $window.FindName("LblProgressMsg")
$LblProgressPct = $window.FindName("LblProgressPct")
$AlertOverlay   = $window.FindName("AlertOverlay")
$AlertTitle     = $window.FindName("AlertTitle")
$AlertMessage   = $window.FindName("AlertMessage")
$BtnAlertOk     = $window.FindName("BtnAlertOk")

# ── UI REFERANSLARINI GLOBAL'E AL (tek seferlik) ──
# Timer tick'leri ve job callback'leri bu global'leri kullanır
$global:_Console = $TxtConsole
$global:_PBar    = $MainProgress
$global:_PctLbl  = $LblProgressPct
$global:_MsgLbl  = $LblProgressMsg

$ConfirmOverlay = $window.FindName("ConfirmOverlay")
$ConfirmIcon    = $window.FindName("ConfirmIcon")
$ConfirmTitle   = $window.FindName("ConfirmTitle")
$ConfirmMessage = $window.FindName("ConfirmMessage")
$BtnConfirmYes  = $window.FindName("BtnConfirmYes")
$BtnConfirmNo   = $window.FindName("BtnConfirmNo")
$ClosingConfirmOverlay  = $window.FindName("ClosingConfirmOverlay")
$ClosingConfirmTitle    = $window.FindName("ClosingConfirmTitle")
$ClosingConfirmMessage  = $window.FindName("ClosingConfirmMessage")
$BtnClosingSave         = $window.FindName("BtnClosingSave")
$BtnClosingDiscard      = $window.FindName("BtnClosingDiscard")
$BtnClosingForceClose   = $window.FindName("BtnClosingForceClose")
$BtnClosingCancel       = $window.FindName("BtnClosingCancel")
$StatusDot      = $window.FindName("StatusDot")
$StatusText     = $window.FindName("StatusText")

# Pg_0 Mount
$TxtWimFile       = $window.FindName("TxtWimFile")
$TxtMountFolder   = $window.FindName("TxtMountFolder")
$ListViewMountIndex = $window.FindName("ListViewMountIndex")
$ChkReadOnly      = $window.FindName("ChkReadOnly")
$ChkRemoveRO      = $window.FindName("ChkRemoveReadOnly")
$BtnChooseWim     = $window.FindName("BtnChooseWim")
$BtnChooseFolder  = $window.FindName("BtnChooseFolder")
$BtnMountWim      = $window.FindName("BtnMountWim")
$BtnUnmountSave   = $window.FindName("BtnUnmountSave")
$BtnUnmountDiscard= $window.FindName("BtnUnmountDiscard")
$BtnOpenFolder    = $window.FindName("BtnOpenFolder")
$BtnCleanupWim    = $window.FindName("BtnCleanupWim")
$TxtWimName       = $window.FindName("TxtWimName")
$TxtWimDesc       = $window.FindName("TxtWimDesc")

# Pg_1 Driver
$TxtDriverFolder       = $window.FindName("TxtDriverFolder")
$BtnChooseDriverFolder = $window.FindName("BtnChooseDriverFolder")
$TxtOnlineExportPath   = $window.FindName("TxtOnlineExportPath")
$BtnChooseOnlineExportPath = $window.FindName("BtnChooseOnlineExportPath")
$ChkRecurse            = $window.FindName("ChkRecurse")
$ChkForceUnsigned      = $window.FindName("ChkForceUnsigned")
$BtnAddDriver          = $window.FindName("BtnAddDriver")
$ChkSelectAllDrivers   = $window.FindName("ChkSelectAllDrivers")
$ListViewDrivers       = $window.FindName("ListViewDrivers")
$TxtDriverCount        = $window.FindName("TxtDriverCount")
$TxtDriverTotalCount   = $window.FindName("TxtDriverTotalCount")
$CmbDriverProvider     = $window.FindName("CmbDriverProvider")
$BtnRemoveSelectedDrivers = $window.FindName("BtnRemoveSelectedDrivers")
$BtnListDrivers        = $window.FindName("BtnListDrivers")
$BtnExportDriverOnline = $window.FindName("BtnExportDriverOnline")

# Pg_2 Package Servicing
$TxtPackagePath          = $window.FindName("TxtPackagePath")
$BtnChoosePackage        = $window.FindName("BtnChoosePackage")
$BtnChoosePackageFolder  = $window.FindName("BtnChoosePackageFolder")
$ChkIgnoreCheck          = $window.FindName("ChkIgnoreCheck")
$ChkPreventPending       = $window.FindName("ChkPreventPending")
$ChkNoRestart            = $window.FindName("ChkNoRestart")
$BtnAddPackage           = $window.FindName("BtnAddPackage")
$TxtPackageSearch        = $window.FindName("TxtPackageSearch")
$CmbPackageStateFilter   = $window.FindName("CmbPackageStateFilter")
$BtnListPackages         = $window.FindName("BtnListPackages")
$BtnPkgGetInfo           = $window.FindName("BtnPkgGetInfo")
$ListViewPackages        = $window.FindName("ListViewPackages")
$LblPackagesEmpty        = $window.FindName("LblPackagesEmpty")
$ChkSelectAllPkgs        = $window.FindName("ChkSelectAllPkgs")
$TxtPkgTotal             = $window.FindName("TxtPkgTotal")
$TxtPkgInstalled         = $window.FindName("TxtPkgInstalled")
$TxtPkgSelected          = $window.FindName("TxtPkgSelected")
$BtnPkgSelectAll         = $window.FindName("BtnPkgSelectAll")
$BtnPkgSelectNone        = $window.FindName("BtnPkgSelectNone")
$BtnRemoveSelectedPackages = $window.FindName("BtnRemoveSelectedPackages")
$TxtRemovePackageName    = $window.FindName("TxtRemovePackageName")
$BtnRemovePackageByName  = $window.FindName("BtnRemovePackageByName")
$BtnPkgExportList        = $window.FindName("BtnPkgExportList")

# Pg_14 Offline Registry
$TxtRegMountDir          = $window.FindName("TxtRegMountDir")
$BtnRegBrowseMountDir    = $window.FindName("BtnRegBrowseMountDir")
$BtnRegLoadSoftware      = $window.FindName("BtnRegLoadSoftware")
$BtnRegLoadSystem        = $window.FindName("BtnRegLoadSystem")
$BtnRegLoadDefault       = $window.FindName("BtnRegLoadDefault")
$BtnRegLoadSam           = $window.FindName("BtnRegLoadSam")
$BtnRegLoadNtuser        = $window.FindName("BtnRegLoadNtuser")
$TxtRegHiveStatus        = $window.FindName("TxtRegHiveStatus")
$RegHiveStatusBorder     = $window.FindName("RegHiveStatusBorder")
$BtnRegUnloadAll         = $window.FindName("BtnRegUnloadAll")
$TxtRegImportFile        = $window.FindName("TxtRegImportFile")
$BtnRegImportBrowse      = $window.FindName("BtnRegImportBrowse")
$BtnRegImport            = $window.FindName("BtnRegImport")
$TxtRegExportKey         = $window.FindName("TxtRegExportKey")
$BtnRegExport            = $window.FindName("BtnRegExport")
$BtnRegApplySelected     = $window.FindName("BtnRegApplySelected")
$BtnRegSelectAllTweaks   = $window.FindName("BtnRegSelectAllTweaks")
$TxtRegSearchQuery       = $window.FindName("TxtRegSearchQuery")
$CmbRegSearchHive        = $window.FindName("CmbRegSearchHive")
$BtnRegSearch            = $window.FindName("BtnRegSearch")
$LstRegSearchResults     = $window.FindName("LstRegSearchResults")
# Tweak CheckBoxes
$ChkTweakTelemetry       = $window.FindName("ChkTweakTelemetry")
$ChkTweakCortana         = $window.FindName("ChkTweakCortana")
$ChkTweakActivityHistory = $window.FindName("ChkTweakActivityHistory")
$ChkTweakAdId            = $window.FindName("ChkTweakAdId")
$ChkTweakFeedback        = $window.FindName("ChkTweakFeedback")
$ChkTweakAppCompat       = $window.FindName("ChkTweakAppCompat")
$ChkTweakDefender        = $window.FindName("ChkTweakDefender")
$ChkTweakSmartScreen     = $window.FindName("ChkTweakSmartScreen")
$ChkTweakUac             = $window.FindName("ChkTweakUac")
$ChkTweakAutoplay        = $window.FindName("ChkTweakAutoplay")
$ChkTweakWuAuto          = $window.FindName("ChkTweakWuAuto")
$ChkTweakDeliveryOpt     = $window.FindName("ChkTweakDeliveryOpt")
$ChkTweakMsrt            = $window.FindName("ChkTweakMsrt")
$ChkTweakVerboseBoot     = $window.FindName("ChkTweakVerboseBoot")
$ChkTweakAnimations      = $window.FindName("ChkTweakAnimations")
$ChkTweakNewsInterests   = $window.FindName("ChkTweakNewsInterests")
$ChkTweakStartSugg       = $window.FindName("ChkTweakStartSugg")
$ChkTweakSearchTaskbar   = $window.FindName("ChkTweakSearchTaskbar")
$ChkTweakTaskView        = $window.FindName("ChkTweakTaskView")
$ChkTweakCopilot         = $window.FindName("ChkTweakCopilot")
$ChkTweakNbns            = $window.FindName("ChkTweakNbns")
$ChkTweakIpv6            = $window.FindName("ChkTweakIpv6")
$ChkTweakHibernation     = $window.FindName("ChkTweakHibernation")
$ChkTweakRemoteReg       = $window.FindName("ChkTweakRemoteReg")
$ChkTweakLmHash          = $window.FindName("ChkTweakLmHash")

# Pg_3 Features on Demand
$TxtFeatureSearch        = $window.FindName("TxtFeatureSearch")
$TxtFeatureSource        = $window.FindName("TxtFeatureSource")
$CmbFeatureStateFilter   = $window.FindName("CmbFeatureStateFilter")
$BtnListFeatures         = $window.FindName("BtnListFeatures")
$BtnEnableFeature        = $window.FindName("BtnEnableFeature")
$BtnDisableFeature       = $window.FindName("BtnDisableFeature")
$BtnFeatureInfo          = $window.FindName("BtnFeatureInfo")
$BtnFeatureSourceBrowse  = $window.FindName("BtnFeatureSourceBrowse")
$BtnInstallFromSource    = $window.FindName("BtnInstallFromSource")
$ChkFeatureLimitAccess   = $window.FindName("ChkFeatureLimitAccess")
$ChkFeatureAll           = $window.FindName("ChkFeatureAll")
$ChkSelectAllFeatures    = $window.FindName("ChkSelectAllFeatures")
$ListViewFeatures        = $window.FindName("ListViewFeatures")
$LblFeaturesEmpty        = $window.FindName("LblFeaturesEmpty")
$TxtFeatureCount         = $window.FindName("TxtFeatureCount")
$TxtFeatureEnabled       = $window.FindName("TxtFeatureEnabled")
$TxtFeatureDisabled      = $window.FindName("TxtFeatureDisabled")
$TxtFeatureSelected      = $window.FindName("TxtFeatureSelected")

# Pg_4 Edition
$TxtProductKey         = $window.FindName("TxtProductKey")
$TxtEdition            = $window.FindName("TxtEdition")
$BtnSetProductKey      = $window.FindName("BtnSetProductKey")
$BtnSetEdition         = $window.FindName("BtnSetEdition")
$BtnShowCurrentEdition = $window.FindName("BtnShowCurrentEdition")
$BtnShowTargetEdition  = $window.FindName("BtnShowTargetEdition")

# ── YARDIMCI FONKSİYONLAR ──
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts  = Get-Date -Format "HH:mm:ss"
    $tag = switch ($Level) {
        "OK"   { "[OK]"   }
        "ERR"  { "[ERR]"  }
        "RUN"  { "[RUN]"  }
        "WARN" { "[WARN]" }
        default{ "[INFO]" }
    }
    if ($null -ne $TxtConsole) {
        $TxtConsole.AppendText("`r`n$ts $tag $Message")
        $TxtConsole.ScrollToEnd()
    }
}

function Set-Progress {
    param([int]$Percent, [string]$Message = "")
    $MainProgress.Value  = $Percent
    $LblProgressPct.Text = if ($Percent -gt 0) { "$Percent%" } else { "" }
    if ($Message) { $LblProgressMsg.Text = $Message }
}

function Set-Status {
    param([string]$Text, [string]$Color = "#10B981")
    $StatusText.Text   = $Text
    $StatusDot.Fill    = $Color
}

function Show-Alert {
    param([string]$Title = "BİLGİ", [string]$Message, [string]$Icon = "")
    $AlertTitle.Text   = $Title.ToUpper()
    $AlertMessage.Text = $Message
    $AlertOverlay.Visibility = "Visible"
}

function Show-Confirm {
    <#
    .SYNOPSIS
        Modern confirm dialog - overlay tabanlı
    .OUTPUTS
        $true if Evet, $false if Hayır
    #>
    param(
        [string]$Title = "Onay",
        [string]$Message = "Devam edilsin mi?",
        [string]$Icon = "⚠️"
    )
    
    # Script-level değişken ile sonucu sakla
    $script:ConfirmDialogResult = $null
    
    # Dialog'u doldur
    $ConfirmIcon.Text    = $Icon
    $ConfirmTitle.Text   = $Title.ToUpper()
    $ConfirmMessage.Text = $Message
    
    # Overlay'i göster
    $ConfirmOverlay.Visibility = "Visible"
    
    # Dispatcher frame ile senkron bekle (WPF-native, DoEvents yerine)
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $startTime = Get-Date

    $checkTimer = New-Object System.Windows.Threading.DispatcherTimer
    $checkTimer.Interval = [TimeSpan]::FromMilliseconds(50)
    $checkTimer.Add_Tick({
        if ($script:ConfirmDialogResult -ne $null -or
            ((Get-Date) - $startTime).TotalSeconds -gt 30) {
            if ($script:ConfirmDialogResult -eq $null) {
                Write-Log "Confirm dialog timeout - hayır kabul edildi" -Level "WARN"
                $script:ConfirmDialogResult = $false
            }
            $checkTimer.Stop()
            $frame.Continue = $false
        }
    })
    $checkTimer.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    
    # Overlay'i gizle
    $ConfirmOverlay.Visibility = "Collapsed"
    
    # Sonucu döndür ve temizle
    $result = $script:ConfirmDialogResult
    $script:ConfirmDialogResult = $null
    
    return ($result -eq $true)
}

function Show-ClosingConfirm {
    <#
    .SYNOPSIS
        WIM unmount icin 3 secenekli dialog: Kaydet / Kaydetme / Iptal
    .OUTPUTS
        "Save", "Discard", "Cancel"
    #>
    param(
        [string]$Title   = "WIM MOUNT AKTİF",
        [string]$Message = "Hâlâ mount edilmiş bir WIM var. Kapatmadan önce unmount edilsin mi?"
    )

    $script:ClosingConfirmResult = $null

    $ClosingConfirmTitle.Text   = $Title.ToUpper()
    $ClosingConfirmMessage.Text = $Message
    $ClosingConfirmOverlay.Visibility = "Visible"

    $frame2 = New-Object System.Windows.Threading.DispatcherFrame
    $startTime2 = Get-Date

    $checkTimer2 = New-Object System.Windows.Threading.DispatcherTimer
    $checkTimer2.Interval = [TimeSpan]::FromMilliseconds(50)
    $checkTimer2.Add_Tick({
        if ($script:ClosingConfirmResult -ne $null -or
            ((Get-Date) - $startTime2).TotalSeconds -gt 30) {
            if ($script:ClosingConfirmResult -eq $null) {
                $script:ClosingConfirmResult = "Cancel"
            }
            $checkTimer2.Stop()
            $frame2.Continue = $false
        }
    })
    $checkTimer2.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame2)

    $ClosingConfirmOverlay.Visibility = "Collapsed"
    $result = $script:ClosingConfirmResult
    $script:ClosingConfirmResult = $null
    return $result
}

# ── Global önizleme durumu ──
$global:PreviewState = @{
    DiskBytes        = 0L
    Parts            = $null        # hashtable listesi
    SizeHandlerBound = $false
    IsDragging       = $false
    DragIdx          = -1           # sol bölüm indexi
    DragStartX       = 0
    DragStartLeftB   = 0L
    DragStartRightB  = 0L
}

function Get-PartitionList {
    param(
        [long]  $DiskBytes,
        [string]$Firmware,
        [bool]  $HasRecovery,
        [long]  $WinBytes,     # 0 = tüm disk
        [bool]  $HasData,
        [string]$DataLabel
    )
    $efi  = [long](260MB)
    $msr  = if ($Firmware -eq "UEFI") { [long](16MB)  } else { 0L }
    $rec  = if ($HasRecovery)         { [long](1024MB) } else { 0L }
    $fixed = $efi + $msr + $rec

    $win  = if ($WinBytes -gt 0) { $WinBytes } else { $DiskBytes - $fixed }
    $data = 0L
    if ($HasData -and $WinBytes -gt 0) {
        $data = $DiskBytes - $fixed - $WinBytes
        if ($data -lt [long](100MB)) { $data = 0L }
    }

    # Kalan ham alan — data yoksa ve windows sabit ise
    $raw  = 0L
    if ($WinBytes -gt 0 -and -not $HasData) {
        $raw = $DiskBytes - $fixed - $WinBytes
        if ($raw -lt [long](100MB)) { $raw = 0L }
    }

    $list = [System.Collections.Generic.List[hashtable]]::new()
    if ($Firmware -eq "UEFI") {
        $list.Add(@{ Label="EFI";    Detail="EFI Sistem Bölümü";       Color="#4A90D9"; Dark="#1E5A8C"; Bytes=$efi;  Fixed=$true;  GptType="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" })
        $list.Add(@{ Label="MSR";    Detail="Microsoft Ayrılmış";       Color="#6C5FC7"; Dark="#3D3480"; Bytes=$msr;  Fixed=$true;  GptType="e3c9e316-0b5c-4db8-817d-f92df00215ae" })
    } else {
        $list.Add(@{ Label="System"; Detail="System (Active)";          Color="#4A90D9"; Dark="#1E5A8C"; Bytes=$efi;  Fixed=$true  })
    }
    $list.Add(@{ Label="(C:)";  Detail="Windows NTFS";                 Color="#2E7D4F"; Dark="#1A4D30"; Bytes=$win;  Fixed=$false; GptType="ebd0a0a2-b9e5-4433-87c0-68b6b72699c7" })
    if ($data -gt 0) {
        $lbl = if ($DataLabel) { $DataLabel } else { "DATA" }
        $list.Add(@{ Label=$lbl; Detail="$lbl NTFS (Veri)";            Color="#1E6E9E"; Dark="#0D4066"; Bytes=$data; Fixed=$false })
    }
    if ($raw -gt 0) {
        $list.Add(@{ Label="RAW";   Detail="Ayrılmamış Alan";          Color="#374151"; Dark="#1F2937"; Bytes=$raw;  Fixed=$true  })
    }
    if ($rec -gt 0) {
        $list.Add(@{ Label="WinRE"; Detail="Kurtarma Bölümü (WinRE)"; Color="#8B3A2A"; Dark="#5C1F12"; Bytes=$rec;  Fixed=$true; GptType="de94bba4-06d1-4d40-a16a-bfd50179d6ac" })
    }
    return $list
}

function Render-PartitionBar {
    $grid  = $PartitionVisualPreview
    $parts = $global:PreviewState.Parts
    if ($null -eq $parts -or $parts.Count -eq 0) { return }

    $grid.ColumnDefinitions.Clear()
    $grid.Children.Clear()

    $totalB = 0L
    foreach ($p in $parts) { $totalB += $p.Bytes }
    if ($totalB -le 0) { return }

    # Minimum görsel oran %3 — EFI/MSR kaybolmasın
    $MIN_R  = 0.03
    $ratios = [double[]]::new($parts.Count)
    $adjSum = 0.0
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $ratios[$i] = [math]::Max($parts[$i].Bytes / $totalB, $MIN_R)
        $adjSum    += $ratios[$i]
    }
    for ($i = 0; $i -lt $ratios.Length; $i++) { $ratios[$i] = $ratios[$i] / $adjSum }

    $DIVW = 5   # ayırıcı sütun genişliği px

    for ($i = 0; $i -lt $parts.Count; $i++) {
        $p      = $parts[$i]
        $isLast = ($i -eq $parts.Count - 1)

        # ── Bölüm sütunu ──
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = New-Object System.Windows.GridLength($ratios[$i], [System.Windows.GridUnitType]::Star)
        $grid.ColumnDefinitions.Add($cd)

        # Gradient brush
        $grad = New-Object System.Windows.Media.LinearGradientBrush
        $grad.StartPoint = "0,0"; $grad.EndPoint = "0,1"
        $gs1 = New-Object System.Windows.Media.GradientStop
        $gs1.Color  = [System.Windows.Media.ColorConverter]::ConvertFromString($p.Color)
        $gs1.Offset = 0.0
        $gs2 = New-Object System.Windows.Media.GradientStop
        $gs2.Color  = [System.Windows.Media.ColorConverter]::ConvertFromString($p.Dark)
        $gs2.Offset = 1.0
        $grad.GradientStops.Add($gs1) | Out-Null
        $grad.GradientStops.Add($gs2) | Out-Null

        $cell = New-Object System.Windows.Controls.Border
        $cell.Background = $grad
        [System.Windows.Controls.Grid]::SetColumn($cell, $i * 2)

        # Etiket metni — ratio >%6 ise göster
        if ($ratios[$i] -gt 0.06) {
            $sizeStr = if ($p.Bytes -ge 1GB) { "$([math]::Round($p.Bytes/1GB,1)) GB" } else { "$([math]::Round($p.Bytes/1MB)) MB" }

            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.VerticalAlignment   = "Center"
            $sp.HorizontalAlignment = "Center"
            $sp.IsHitTestVisible    = $false

            $t1 = New-Object System.Windows.Controls.TextBlock
            $t1.Text = $p.Label; $t1.FontSize = 10; $t1.FontWeight = "SemiBold"
            $t1.Foreground = "White"; $t1.HorizontalAlignment = "Center"
            $t1.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect
            $t1.Effect.ShadowDepth = 1; $t1.Effect.BlurRadius = 2; $t1.Effect.Opacity = 0.8
            $sp.Children.Add($t1) | Out-Null

            $t2 = New-Object System.Windows.Controls.TextBlock
            $t2.Text = $sizeStr; $t2.FontSize = 9
            $t2.Foreground = "#BFDBFE"; $t2.HorizontalAlignment = "Center"
            $sp.Children.Add($t2) | Out-Null

            $cell.Child = $sp
        }
        $grid.Children.Add($cell) | Out-Null

        # ── Ayırıcı sütunu (son bölümden sonra yok) ──
        if (-not $isLast) {
            $nextPart = $parts[$i + 1]
            # Sadece C:↔Data veya C:↔RAW arası sürüklenebilir
            $draggable = (-not $p.Fixed -and -not $nextPart.Fixed) -or
                         ($p.Label -eq "(C:)" -and $nextPart.Label -ne "WinRE") -or
                         ($p.Label -eq "(C:)" -and $nextPart.Label -eq "RAW")

            $cdDiv = New-Object System.Windows.Controls.ColumnDefinition
            $cdDiv.Width = New-Object System.Windows.GridLength($DIVW, [System.Windows.GridUnitType]::Pixel)
            $grid.ColumnDefinitions.Add($cdDiv)

            $div = New-Object System.Windows.Controls.Border
            $div.Background = if ($draggable) { "#60A5FA" } else { "#1E3A5F" }
            $div.Tag        = $i   # sol bölüm indexi
            [System.Windows.Controls.Grid]::SetColumn($div, $i * 2 + 1)

            if ($draggable) {
                $div.Cursor  = [System.Windows.Input.Cursors]::SizeWE
                $div.ToolTip = "Sürükle: boyutu ayarla"

                $div.Add_MouseLeftButtonDown({
                    param($s, $e)
                    $idx = [int]$s.Tag
                    $ps  = $global:PreviewState
                    $ps.IsDragging      = $true
                    $ps.DragIdx         = $idx
                    $ps.DragStartX      = $e.GetPosition($PartitionVisualPreview).X
                    $ps.DragStartLeftB  = $ps.Parts[$idx].Bytes
                    $ps.DragStartRightB = $ps.Parts[$idx + 1].Bytes
                    $s.CaptureMouse() | Out-Null
                    $e.Handled = $true
                })

                $div.Add_MouseMove({
                    param($s, $e)
                    $ps = $global:PreviewState
                    if (-not $ps.IsDragging) { return }

                    $curX  = $e.GetPosition($PartitionVisualPreview).X
                    $gridW = $PartitionVisualPreview.ActualWidth
                    if ($gridW -le 10) { return }

                    $totalB2 = 0L
                    foreach ($pp in $ps.Parts) { $totalB2 += $pp.Bytes }
                    $bPerPx = $totalB2 / $gridW

                    $deltaX = $curX - $ps.DragStartX
                    $deltaB = [long]($deltaX * $bPerPx)

                    $MIN_B    = [long](10GB)
                    $newLeft  = $ps.DragStartLeftB  + $deltaB
                    $newRight = $ps.DragStartRightB - $deltaB
                    if ($newLeft  -lt $MIN_B) { $newLeft  = $MIN_B; $newRight = $ps.DragStartLeftB + $ps.DragStartRightB - $MIN_B }
                    if ($newRight -lt $MIN_B) { $newRight = $MIN_B; $newLeft  = $ps.DragStartLeftB + $ps.DragStartRightB - $MIN_B }

                    $ps.Parts[$ps.DragIdx].Bytes     = $newLeft
                    $ps.Parts[$ps.DragIdx + 1].Bytes = $newRight

                    # C: değişince TextBox güncelle — TextChanged tetiklemeden
                    $idx = $ps.DragIdx
                    if ($ps.Parts[$idx].Label -eq "(C:)") {
                        $TxtWindowsSize.TextChanged -= $script:TxtWindowsSizeHandler
                        $TxtWindowsSize.Text = [string][math]::Round($newLeft / 1GB)
                        $TxtWindowsSize.TextChanged += $script:TxtWindowsSizeHandler
                    }

                    Render-PartitionBar
                    Render-LegendBar
                    $e.Handled = $true
                })

                $div.Add_MouseLeftButtonUp({
                    param($s, $e)
                    $global:PreviewState.IsDragging = $false
                    $s.ReleaseMouseCapture() | Out-Null
                    $e.Handled = $true
                })
            }
            $grid.Children.Add($div) | Out-Null
        }
    }

    # Grid column indexlerini düzelt (her eleman için 2 sütun: içerik + ayırıcı)
    # Zaten yukarıda $i*2 ile ayarlandı — son eleman için ayırıcı yok, toplam sütun = parts*2-1
}

function Render-LegendBar {
    $PartitionLegend.Items.Clear()
    foreach ($p in $global:PreviewState.Parts) {
        $sizeStr = if ($p.Bytes -ge 1GB) { "$([math]::Round($p.Bytes/1GB,1)) GB" } else { "$([math]::Round($p.Bytes/1MB)) MB" }

        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = "Horizontal"
        $sp.Margin = New-Object System.Windows.Thickness(0,2,14,2)

        $dot = New-Object System.Windows.Controls.Border
        $dot.Width = 10; $dot.Height = 10
        $dot.CornerRadius = New-Object System.Windows.CornerRadius(2)
        $dot.Background = $p.Color
        $dot.VerticalAlignment = "Center"
        $dot.Margin = New-Object System.Windows.Thickness(0,0,5,0)
        $sp.Children.Add($dot) | Out-Null

        $txt = New-Object System.Windows.Controls.TextBlock
        $txt.Text = "$($p.Label)  $($p.Detail)  ($sizeStr)"
        $txt.FontSize = 9; $txt.Foreground = "#CBD5E1"
        $txt.VerticalAlignment = "Center"
        $sp.Children.Add($txt) | Out-Null

        $PartitionLegend.Items.Add($sp) | Out-Null
    }
}

function Update-PartitionPreview {
    # ── Disk seçilmemişse sıfırla ──
    if ([string]::IsNullOrWhiteSpace($TxtApplyDisk.Text) -or $null -eq $global:SelectedDiskNumber) {
        $LblDiskInfo.Text                 = "Disk: —"
        $LblPartitionPreview.Text         = "Lütfen bir disk seçin"
        $LblPartitionPreview.Visibility   = "Visible"
        $PartitionBarContainer.Visibility = "Collapsed"
        $LegendBorder.Visibility          = "Collapsed"
        return
    }

    # ── Disk bilgisi ──
    try {
        $disk      = Get-Disk -Number $global:SelectedDiskNumber -ErrorAction Stop
        $diskBytes = $disk.Size
        $diskGB    = [math]::Round($diskBytes / 1GB, 1)
        $LblDiskInfo.Text = "$($global:SelectedDiskNumber)  |  Disk $($global:SelectedDiskNumber)  $($disk.OperationalStatus)  $diskGB GB  $($disk.BusType)  *"
    } catch {
        $LblDiskInfo.Text                 = "Disk: Bilgi alınamadı"
        $LblPartitionPreview.Text         = "Disk bilgisi okunamadı"
        $LblPartitionPreview.Visibility   = "Visible"
        $PartitionBarContainer.Visibility = "Collapsed"
        $LegendBorder.Visibility          = "Collapsed"
        return
    }

    # ── Firmware ──
    $fw  = if ($RdoFirmwareUEFI.IsChecked) { "UEFI" } else { "BIOS" }
    $efi = [long](260MB)
    $msr = if ($fw -eq "UEFI") { [long](16MB) } else { 0L }
    $rec = if ($ChkCreateRecovery.IsChecked) { [long](1024MB) } else { 0L }
    $fixed = $efi + $msr + $rec

    # ── Windows boyutu ──
    $winGB    = 0
    $winFixed = $false
    if (-not [string]::IsNullOrWhiteSpace($TxtWindowsSize.Text)) {
        $parsed = 0
        if ([int]::TryParse($TxtWindowsSize.Text, [ref]$parsed) -and $parsed -gt 0) {
            $minGB = Get-WimMinimumSizeGB
            if ($parsed -lt $minGB) {
                $TxtWindowsSize.Background = "#FEE2E2"
            } else {
                $TxtWindowsSize.Background = "White"
                $winGB = $parsed; $winFixed = $true
            }
        } else { $TxtWindowsSize.Background = "White" }
    } else { $TxtWindowsSize.Background = "White" }

    # ── Data ──
    $dataLabel = if ([string]::IsNullOrWhiteSpace($TxtDataDiskLabel.Text)) { "DATA" } else { $TxtDataDiskLabel.Text }
    $hasData   = ($ChkCreateDataDisk.IsChecked -and $winFixed)

    # Checkbox görsel durumu
    if (-not $winFixed) {
        $ChkCreateDataDisk.Opacity  = 0.45
        $TxtDataDiskLabel.IsEnabled = $false
        $TxtDataDiskLabel.Opacity   = 0.45
    } else {
        $ChkCreateDataDisk.Opacity  = 1.0
        $TxtDataDiskLabel.IsEnabled = $ChkCreateDataDisk.IsChecked
        $TxtDataDiskLabel.Opacity   = if ($ChkCreateDataDisk.IsChecked) { 1.0 } else { 0.45 }
    }

    $winBytes = if ($winFixed) { [long]($winGB * 1GB) } else { $diskBytes - $fixed }

    # ── PreviewState güncelle ──
    $global:PreviewState.DiskBytes = $diskBytes
    $global:PreviewState.Parts     = Get-PartitionList `
        -DiskBytes   $diskBytes `
        -Firmware    $fw `
        -HasRecovery ([bool]$ChkCreateRecovery.IsChecked) `
        -WinBytes    $winBytes `
        -HasData     $hasData `
        -DataLabel   $dataLabel

    # ── Görünür yap, sonra render ──
    $LblPartitionPreview.Visibility   = "Collapsed"
    $PartitionBarContainer.Visibility = "Visible"
    $LegendBorder.Visibility          = "Visible"
    $PartitionLegend.Visibility       = "Visible"

    # ── SizeChanged: bir kez bağla, her resize'da yeniden çiz ──
    if (-not $global:PreviewState.SizeHandlerBound) {
        $global:PreviewState.SizeHandlerBound = $true
        $PartitionVisualPreview.Add_SizeChanged({
            if ($PartitionVisualPreview.ActualWidth -gt 10 -and $null -ne $global:PreviewState.Parts) {
                Render-PartitionBar
            }
        })
    }

    # ── Render: layout hazır değilse Dispatcher ile ertele ──
    $window.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Render,
        [Action]{
            Render-PartitionBar
            Render-LegendBar
        }
    ) | Out-Null
}

function Get-WimMinimumSizeGB {
    <#
    .SYNOPSIS
        Seçili WIM dosyasının minimum gereken boyutunu GB cinsinden döndürür
    .DESCRIPTION
        WIM dosyasının sıkıştırılmamış boyutunu alır ve %20 ekstra alan ekler
    #>
    
    # WIM seçilmemişse 20GB default (güvenli minimum)
    if ([string]::IsNullOrWhiteSpace($TxtApplySource.Text)) {
        return 20
    }
    
    $wimPath = $TxtApplySource.Text
    if (-not (Test-Path $wimPath)) {
        return 20
    }
    
    # Seçili index
    if ($global:ApplyIndexItems.Count -eq 0 -or $ListViewApplyIndex.SelectedIndex -lt 0) {
        return 20
    }
    
    try {
        $selectedIndex = $global:ApplyIndexItems[$ListViewApplyIndex.SelectedIndex].IndexNumber
        
        # DISM ile image info al
        $info = & DISM.EXE /Get-ImageInfo /ImageFile:"$wimPath" /Index:$selectedIndex 2>$null
        
        # Size satırını bul: "Size : 15,234,567,890 bytes"
        $sizeLine = $info | Where-Object { $_ -match 'Size\s*:\s*([\d,]+)\s*bytes' }
        
        if ($sizeLine -match 'Size\s*:\s*([\d,]+)\s*bytes') {
            $sizeBytes = [long]($Matches[1] -replace ',', '')
            # %20 ekstra alan ekle (sistem dosyaları, update, temp)
            $minSizeGB = [math]::Ceiling(($sizeBytes * 1.2) / 1GB)
            
            # En az 20GB
            if ($minSizeGB -lt 20) { $minSizeGB = 20 }
            
            return $minSizeGB
        }
    } catch {
        # Hata durumunda güvenli default
    }
    
    return 20  # Default minimum
}




# ── YENİ: Mount Dizini Hazırlama ve Doğrulama Fonksiyonları ──
function Prepare-MountDirectory {
    param([string]$Path)
    try {
        if (-not (Test-Path $Path)) {
            Write-Log "Mount dizini mevcut değil, oluşturuluyor: $Path" -Level "OK"
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
            if (-not (Test-Path $Path)) {
                Write-Log "Mount dizini oluşturulamadı: $Path" -Level "ERR"
                return $false
            }
        }
        $items = Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue
        if ($items.Count -gt 0) {
            Write-Log "UYARI: Mount dizini boş değil ($($items.Count) dosya)" -Level "WARN"
            & DISM.EXE /Cleanup-Wim 2>&1 | Out-Null
            Start-Sleep -Seconds 2
            $items = Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue
            if ($items.Count -gt 0) {
                $response = Show-Confirm -Title "Mount Dizini Uyarısı" `
                    -Message "Mount dizini boş değil. Devam edilsin mi?`n`nDizin: $Path`nDosya: $($items.Count)" `
                    -Icon "⚠️"
                if (-not $response) {
                    return $false
                }
            }
        }
        try {
            $testFile = Join-Path $Path "_test_$(Get-Random).tmp"
            [System.IO.File]::WriteAllText($testFile, "test")
            Remove-Item $testFile -Force
        } catch {
            Show-Alert -Title "İzin Hatası" -Message "Mount dizinine yazma izni yok:`n$Path"
            return $false
        }
        return $true
    } catch {
        Show-Alert -Title "Dizin Hatası" -Message "Mount dizini hazırlanamadı:`n$_"
        return $false
    }
}

function Test-WimFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Show-Alert -Title "Dosya Bulunamadı" -Message "WIM/ESD dosyası bulunamadı:`n$Path"
        return $false
    }
    $file = Get-Item $Path
    if ($file.Length -eq 0) {
        Show-Alert -Title "Geçersiz Dosya" -Message "WIM dosyası boş (0 byte)."
        return $false
    }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'None')
        $fs.Close()
    } catch {
        Show-Alert -Title "Dosya Kilitli" -Message "WIM başka bir program tarafından kullanılıyor."
        return $false
    }
    return $true
}

function Get-MountedImageInfo {
    <#
    .SYNOPSIS
        Şu an mount edilmiş olan tüm WIM'lerin bilgisini döndürür
    #>
    param([string]$MountDir = "")
    
    try {
        $output = & DISM.EXE /Get-MountedImageInfo 2>&1 | Out-String
        
        if ($MountDir -ne "") {
            # Belirli bir mount dizini için kontrol
            if ($output -match "Mount Dir\s*:\s*$([regex]::Escape($MountDir))") {
                $isReadOnly = $output -match "Mounted Read\/Write\s*:\s*No"
                return @{
                    IsMounted = $true
                    IsReadOnly = $isReadOnly
                    Path = $MountDir
                }
            }
            return @{ IsMounted = $false }
        }
        
        # Tüm mount'ları listele
        return $output
    } catch {
        return $null
    }
}



function Assert-WimMounted {
    if (-not $global:WIMMounted) {
        Show-Alert -Title "İmaj Bağlı Değil" -Message "Bu işlem için önce bir WIM/ESD imajı mount etmelisiniz."
        return $false
    }
    return $true
}

# ── SAYFA GEÇİŞLERİ ──
$pages = 0..14 | ForEach-Object { "Pg_$_" }
foreach ($page in $pages) {
    $idx    = $page.Replace("Pg_", "")
    $navBtn = $window.FindName("Nav_$idx")
    if ($null -ne $navBtn) {
        $navBtn.Add_Checked({
            $target = $this.Name.Replace("Nav_", "Pg_")
            foreach ($p in $pages) {
                $g = $window.FindName($p)
                if ($null -ne $g) { $g.Visibility = if ($p -eq $target) { "Visible" } else { "Collapsed" } }
            }
        })
    }
}

# ── PENCERE KONTROLLER ──
$DragBar.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($e.ClickCount -eq 2) {
        if ($script:IsMaximized) { Set-WindowRestored } else { Set-WindowMaximized }
    } elseif (-not $script:IsMaximized) {
        $window.DragMove()
    }
})
$BtnClose.Add_Click({
    if ($global:IsBusy) {
        Show-Alert -Title "İşlem Devam Ediyor" -Message "Bir işlem devam ediyor. Kapatmak için önce işlemi iptal edin."
        return
    }
    $window.Close()
})
$BtnMin.Add_Click({ $window.WindowState = "Minimized" })

# Önceki normal boyut/konum — restore için
$script:NormalLeft   = $null
$script:NormalTop    = $null
$script:NormalWidth  = $null
$script:NormalHeight = $null
$script:IsMaximized  = $false

function Set-WindowMaximized {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $script:NormalLeft   = $window.Left
    $script:NormalTop    = $window.Top
    $script:NormalWidth  = $window.Width
    $script:NormalHeight = $window.Height
    $script:IsMaximized  = $true
    $window.Left   = $wa.Left
    $window.Top    = $wa.Top
    $window.Width  = $wa.Width
    $window.Height = $wa.Height
    # Tüm köşe yuvarlamalarını kaldır
    $MainBorder.CornerRadius         = New-Object System.Windows.CornerRadius(0)
    $MainBorder.BorderThickness      = New-Object System.Windows.Thickness(0)
    $SidebarBorder.CornerRadius      = New-Object System.Windows.CornerRadius(0)
    $SidebarBottomBorder.CornerRadius = New-Object System.Windows.CornerRadius(0)
    $StatusBarBorder.CornerRadius    = New-Object System.Windows.CornerRadius(0)
    $wc = [System.Windows.Shell.WindowChrome]::GetWindowChrome($window)
    if ($null -ne $wc) { $wc.CornerRadius = New-Object System.Windows.CornerRadius(0) }
}

function Set-WindowRestored {
    $script:IsMaximized = $false
    if ($null -ne $script:NormalLeft) {
        $window.Left   = $script:NormalLeft
        $window.Top    = $script:NormalTop
        $window.Width  = $script:NormalWidth
        $window.Height = $script:NormalHeight
    }
    # Köşe yuvarlamalarını geri getir
    $MainBorder.CornerRadius         = New-Object System.Windows.CornerRadius(8)
    $MainBorder.BorderThickness      = New-Object System.Windows.Thickness(1)
    $SidebarBorder.CornerRadius      = New-Object System.Windows.CornerRadius(7,0,0,7)
    $SidebarBottomBorder.CornerRadius = New-Object System.Windows.CornerRadius(0,0,0,7)
    $StatusBarBorder.CornerRadius    = New-Object System.Windows.CornerRadius(0,0,7,0)
    $wc = [System.Windows.Shell.WindowChrome]::GetWindowChrome($window)
    if ($null -ne $wc) { $wc.CornerRadius = New-Object System.Windows.CornerRadius(8) }
}

$BtnMax.Add_Click({
    if ($script:IsMaximized) { Set-WindowRestored } else { Set-WindowMaximized }
})
$BtnClearLog.Add_Click({ $TxtConsole.Text = ""; $global:StrOutput = "" })

$BtnCancelJob.Add_Click({
    if (-not $global:IsBusy) { return }
    $global:CancelRequested = $true
    Write-Log "İptal istegi gönderildi - işlem durduruluyor..." -Level "WARN"

    # 1. DISM PID'si varsa direkt öldür
    if ($script:DismPid -gt 0) {
        try {
            $p = Get-Process -Id $script:DismPid -ErrorAction SilentlyContinue
            if ($p) { 
                $p.Kill()
                Write-Log "DISM.EXE (PID $($script:DismPid)) sonlandırıldı" -Level "OK"
            }
        } catch {
            Write-Log "DISM.EXE (PID $($script:DismPid)) sonlandırılamadı: $_" -Level "WARN"
        }
        $script:DismPid = 0
    }

    # 2. VSS DISM PID (eski capture kod için)
    if ($script:VssDismPid -gt 0) {
        try {
            $p = Get-Process -Id $script:VssDismPid -ErrorAction SilentlyContinue
            if ($p) { 
                $p.Kill()
                Write-Log "DISM.EXE VSS (PID $($script:VssDismPid)) sonlandırıldı" -Level "OK"
            }
        } catch {}
        $script:VssDismPid = 0
    }

    # 3. Adla bulunan diğer DISM prosesleri (fallback)
    Get-Process -Name "DISM" -ErrorAction SilentlyContinue | ForEach-Object {
        try { 
            $_.Kill()
            Write-Log "DISM.EXE (PID $($_.Id)) sonlandırıldı" -Level "OK"
        } catch {}
    }

    # 4. Job ve timer'ları durdur
    if ($script:DismTimer){ $script:DismTimer.Stop() }
    if ($script:VssTimer) { $script:VssTimer.Stop()  }
    
    if ($script:DriverListTimer) { $script:DriverListTimer.Stop() }
    if ($script:DriverListJob)   { Stop-Job $script:DriverListJob -ErrorAction SilentlyContinue; Remove-Job $script:DriverListJob -Force -ErrorAction SilentlyContinue }

    if ($script:DismJob)  { 
        Stop-Job $script:DismJob -ErrorAction SilentlyContinue
        Remove-Job $script:DismJob -Force -ErrorAction SilentlyContinue 
        
        # OnCancel callback varsa çalıştır
        if ($null -ne $script:DismOnCancel) {
            & $script:DismOnCancel
        }
    }
    if ($script:VssJob)   { Stop-Job $script:VssJob  -ErrorAction SilentlyContinue; Remove-Job $script:VssJob  -Force -ErrorAction SilentlyContinue }
    
    # 4.1. Defragment job'ı durdur ve temp dosya temizle
    if ($script:DefragTimer) { $script:DefragTimer.Stop() }
    if ($script:DefragJob) {
        Stop-Job $script:DefragJob -ErrorAction SilentlyContinue
        Remove-Job $script:DefragJob -Force -ErrorAction SilentlyContinue
        # Temp defrag dosyasını temizle
        if ($script:TempDefragFile -and (Test-Path $script:TempDefragFile)) {
            try {
                Remove-Item -Path $script:TempDefragFile -Force -ErrorAction Stop
                Write-Log "İptal: Temp defrag dosyası temizlendi ($($script:TempDefragFile))" -Level "INFO"
            } catch {
                Write-Log "İptal: Temp dosya silinemedi: $($_.Exception.Message)" -Level "WARN"
            }
        }
    }

    # 5. VHD job/timer — durdur ve async detach + temizlik yap
    if ($script:VhdTimer) { $script:VhdTimer.Stop() }
    if ($script:VhdJob)   { Stop-Job $script:VhdJob -ErrorAction SilentlyContinue; Remove-Job $script:VhdJob -Force -ErrorAction SilentlyContinue }
    if ($TxtVhdPath -and $TxtVhdPath.Text -ne '') {
        $vhdToDetach = $TxtVhdPath.Text
        $deleteVhd   = $script:VhdIsNew  # Sadece yeni oluşturulan VHD silinir
        Write-Log "VHD temizleniyor: $vhdToDetach" -Level "WARN"
        Start-Job -ScriptBlock {
            param($p, $del)
            # Önce detach et
            $tmp = [System.IO.Path]::GetTempFileName() + ".txt"
            "select vdisk file=`"$p`"`ndetach vdisk`nexit" | Set-Content $tmp -Encoding ASCII
            & diskpart /s $tmp 2>&1 | Out-Null
            Remove-Item $tmp -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            # Yeni oluşturulmuşsa yarım kalan VHD dosyasını sil
            if ($del -and (Test-Path $p)) {
                Remove-Item $p -Force -ErrorAction SilentlyContinue
            }
        } -ArgumentList $vhdToDetach, $deleteVhd | Out-Null
        $msg = if ($deleteVhd) { "VHD detach + silme komutu gönderildi." } else { "VHD detach komutu gönderildi." }
        Write-Log $msg -Level "OK"
        # VDS servisini kapat
        Get-Process -Name "vds" -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch {} }
    }

    $BtnCancelJob.Visibility = [System.Windows.Visibility]::Collapsed
    $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Collapsed
    $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Collapsed
    Set-Progress -Percent 0 -Message "İptal edildi."
    $global:IsBusy          = $false
    $global:CancelRequested = $false
    Update-CaptureForm
})
$BtnAlertOk.Add_Click({ $AlertOverlay.Visibility = "Collapsed" })

# Confirm dialog buton handler'ları (tek seferlik)
$BtnConfirmYes.Add_Click({
    $script:ConfirmDialogResult = $true
})

$BtnConfirmNo.Add_Click({
    $script:ConfirmDialogResult = $false
})

$BtnClosingSave.Add_Click({
    $script:ClosingConfirmResult = "Save"
})
$BtnClosingDiscard.Add_Click({
    $script:ClosingConfirmResult = "Discard"
})
$BtnClosingForceClose.Add_Click({
    $script:ClosingConfirmResult = "ForceClose"
})
$BtnClosingCancel.Add_Click({
    $script:ClosingConfirmResult = "Cancel"
})

# ── DISM LOG ──
$window.FindName("TxtDismLog").Add_MouseLeftButtonDown({
    $logPath = "$env:windir\Logs\DISM\dism.log"
    if (Test-Path $logPath) { Start-Process notepad.exe $logPath }
    else { Show-Alert -Title "Log Bulunamadı" -Message "DISM log dosyası bulunamadı: $logPath" }
})

# ═══════════════════════════════════════════════════════
# PG_0 : MOUNT WORKSPACE
# ═══════════════════════════════════════════════════════

# Mount Workspace için index listesi yükleme (async)
function Load-MountIndexList {
    param([string]$FilePath)
    
    $global:MountIndexItems.Clear()
    $TxtWimName.Text = ""
    $TxtWimDesc.Text = ""
    
    if (-not (Test-Path $FilePath)) { return }
    
    Write-Log "Index'ler yükleniyor: $FilePath" -Level "INFO"
    Set-Progress -Percent 10 -Message "WIM analiz ediliyor..."
    
    # Async job - UI donmaz
    $script:MountIndexJob = Start-Job -ScriptBlock {
        param($wimPath)
        
        try {
            Import-Module DISM -ErrorAction Stop
            $images = Get-WindowsImage -ImagePath $wimPath -ErrorAction Stop
            
            # ── Mevcut mount'ları DISM.EXE ile al (PowerShell cmdlet'i ImagePath/ImageFilePath
            #    property adını versiyona göre farklı döndürüyor; DISM.EXE çıktısı tutarlı) ──
            # Format: "Mount Dir : C:\mount" / "Image File : C:\install.wim" / "Image Index : 1" / "Mounted Read/Write : Yes" / "Status : Ok|NeedsRemount"
            $mountTable = @{}   # key = "$wimPathLower|$index", value = @{Path=...; Status=...}
            try {
                $dismOut = & DISM.EXE /Get-MountedImageInfo 2>&1 | Where-Object { $_ -match '\S' }
                $curFile = ""; $curIndex = 0; $curDir = ""; $curStatus = ""
                foreach ($line in $dismOut) {
                    if ($line -match '^\s*Image File\s*:\s*(.+)$')  { $curFile   = $Matches[1].Trim() }
                    if ($line -match '^\s*Image Index\s*:\s*(\d+)') { $curIndex  = [int]$Matches[1] }
                    if ($line -match '^\s*Mount Dir\s*:\s*(.+)$')   { $curDir    = $Matches[1].Trim() }
                    if ($line -match '^\s*Status\s*:\s*(.+)$') {
                        $curStatus = $Matches[1].Trim()
                        if ($curFile -ne "" -and $curIndex -gt 0 -and $curDir -ne "") {
                            $key = "$($curFile.ToLower())|$curIndex"
                            $mountTable[$key] = @{ Path = $curDir; Status = $curStatus }
                        }
                        $curFile = ""; $curIndex = 0; $curDir = ""; $curStatus = ""
                    }
                }
            } catch {}

            $results = @()
            foreach ($img in $images) {
                try {
                    $detailed = Get-WindowsImage -ImagePath $wimPath -Index $img.ImageIndex -ErrorAction Stop
                    
                    # Mount eşleştirme — case-insensitive, kesin
                    $key = "$($wimPath.ToLower())|$($img.ImageIndex)"
                    $mountEntry = $mountTable[$key]
                    
                    $mountStatus = if ($mountEntry) {
                        if ($mountEntry.Status -eq "Ok") { "Mounted" }
                        elseif ($mountEntry.Status -match "Remount") { "NeedsRemount" }
                        else { "Mounted" }
                    } else { "Hazır" }
                    
                    $results += @{
                        IndexNumber  = $detailed.ImageIndex
                        IndexName    = $detailed.ImageName
                        Description  = $detailed.ImageDescription
                        Size         = $detailed.ImageSize
                        Architecture = $detailed.Architecture
                        Languages    = $detailed.Languages
                        CreatedTime  = $detailed.CreatedTime
                        MountStatus  = $mountStatus
                        MountPath    = if ($mountEntry) { $mountEntry.Path } else { "" }
                    }
                } catch {
                    $results += @{
                        IndexNumber  = $img.ImageIndex
                        IndexName    = $img.ImageName
                        Description  = $img.ImageDescription
                        Size         = $img.ImageSize
                        Architecture = $null
                        Languages    = $null
                        CreatedTime  = $null
                        MountStatus  = "Hazır"
                        MountPath    = ""
                    }
                }
            }
            return $results
        } catch {
            return @{ Error = $_.Exception.Message }
        }
    } -ArgumentList $FilePath
    
    # Timer ile job sonucunu bekle
    $script:MountIndexTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:MountIndexTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:MountIndexTimer.Add_Tick({
        if ($script:MountIndexJob.State -notin @('Completed','Failed','Stopped')) { return }
        
        $script:MountIndexTimer.Stop()
        
        try {
            $results = Receive-Job $script:MountIndexJob -ErrorAction Stop
            Remove-Job $script:MountIndexJob -Force
            
            if ($results -and $results[0].Error) {
                Write-Log "Index yükleme hatası: $($results[0].Error)" -Level "ERR"
                Set-Progress -Percent 0 -Message "Hata."
                return
            }
            
            foreach ($r in $results) {
                $item = [MountIndexItem]::new()
                $item.IndexNumber = $r.IndexNumber
                $item.IndexName = $r.IndexName
                $item.Description = $r.Description
                $item.Size = "{0:N2} GB" -f ($r.Size / 1GB)
                
                # Architecture
                $item.Architecture = switch ($r.Architecture) {
                    0 { "x86" }
                    5 { "ARM" }
                    6 { "IA64" }
                    9 { "x64" }
                    12 { "ARM64" }
                    default { "?" }
                }
                
                # Languages
                if ($r.Languages -and $r.Languages.Count -gt 0) {
                    if ($r.Languages.Count -le 2) {
                        $item.Languages = $r.Languages -join ", "
                    } else {
                        $item.Languages = "$($r.Languages[0]), $($r.Languages[1]) +$($r.Languages.Count - 2)"
                    }
                } else {
                    $item.Languages = "-"
                }
                
                # Created Date
                if ($r.CreatedTime) {
                    $item.CreatedDate = $r.CreatedTime.ToString("yyyy-MM-dd")
                } else {
                    $item.CreatedDate = "-"
                }

                # Mount Durumu ve yolu
                $item.MountPath = if ($r.MountPath) { $r.MountPath } else { "" }
                switch ($r.MountStatus) {
                    "Mounted"      { $item.MountStatus = "Mounted";   $item.MountStatusColor = "#16A34A" }
                    "NeedsRemount" { $item.MountStatus = "Remount!";  $item.MountStatusColor = "#D97706" }
                    default        { $item.MountStatus = "Hazır";     $item.MountStatusColor = "#9CA3AF" }
                }
                
                $global:MountIndexItems.Add($item)
            }
            
            Write-Log "$($global:MountIndexItems.Count) index bulundu" -Level "OK"
            Set-Progress -Percent 0 -Message "Sistem Hazır."
            
            # İlk index'i otomatik seç (checkbox ile)
            if ($global:MountIndexItems.Count -gt 0) {
                $global:MountIndexItems[0].IsSelected = $true
                $ListViewMountIndex.Items.Refresh()
                
                # Text box'ları güncelle
                $TxtWimName.Text = $global:MountIndexItems[0].IndexName
                if ($TxtWimFile.Text -and (Test-Path $TxtWimFile.Text)) {
                    try {
                        $img = Get-WindowsImage -ImagePath $TxtWimFile.Text -Index $global:MountIndexItems[0].IndexNumber -ErrorAction Stop
                        $TxtWimDesc.Text = $img.ImageDescription
                    } catch {
                        $TxtWimDesc.Text = ""
                    }
                }
            }
        } catch {
            Write-Log "Index yükleme hatası: $($_.Exception.Message)" -Level "ERR"
            Set-Progress -Percent 0 -Message "Hata."
        }
    })
    $script:MountIndexTimer.Start()
}

$BtnChooseWim.Add_Click({
    $file = Select-File -Filter "Image Dosyaları (*.wim;*.esd)|*.wim;*.esd|WIM (*.wim)|*.wim|ESD (*.esd)|*.esd"
    if ($file -eq "") { return }
    $TxtWimFile.Text = $file
    Load-MountIndexList -FilePath $file
})
$ListViewMountIndex.Add_Loaded({
    # CheckBox'lara tek seçim mantığını ekle
    $listView = $ListViewMountIndex
    
    # Her item için checkbox event handler ekle
    $listView.AddHandler(
        [System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent,
        [System.Windows.RoutedEventHandler]{
            param($sender, $e)
            
            if ($sender -is [System.Windows.Controls.CheckBox]) {
                $clickedItem = $sender.DataContext
                
                # Tek seçim mantığı: Diğer tüm checkbox'ları kapat
                foreach ($item in $global:MountIndexItems) {
                    if ($item -ne $clickedItem) {
                        $item.IsSelected = $false
                    }
                }
                
                # Seçili item'ın verilerini text box'lara yükle
                if ($clickedItem.IsSelected) {
                    $TxtWimName.Text = $clickedItem.IndexName
                    if ($TxtWimFile.Text -and (Test-Path $TxtWimFile.Text)) {
                        try {
                            $img = Get-WindowsImage -ImagePath $TxtWimFile.Text -Index $clickedItem.IndexNumber -ErrorAction Stop
                            $TxtWimDesc.Text = $img.ImageDescription
                        } catch {
                            $TxtWimDesc.Text = ""
                        }
                    }
                }
                
                # Observable collection güncelleme
                $listView.Items.Refresh()
            }
        }
    )
    
    # Unchecked event için de handler ekle (item'ı seçimden çıkarma)
    $listView.AddHandler(
        [System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent,
        [System.Windows.RoutedEventHandler]{
            param($sender, $e)
            
            if ($sender -is [System.Windows.Controls.CheckBox]) {
                $clickedItem = $sender.DataContext
                
                # Tüm seçimleri kontrol et - hiç seçili yoksa text box'ları temizle
                $anySelected = $global:MountIndexItems | Where-Object { $_.IsSelected }
                if (-not $anySelected) {
                    $TxtWimName.Text = ""
                    $TxtWimDesc.Text = ""
                }
            }
        }
    )
})

$BtnChooseFolder.Add_Click({
    $folder = Select-Folder
    if ($folder -ne "") { $TxtMountFolder.Text = $folder }
})

$BtnMountWim.Add_Click({
    if ($TxtWimFile.Text -eq "") { Show-Alert -Title "Eksik Alan" -Message "Lütfen önce bir WIM/ESD dosyası seçin."; return }
    
    # Checkbox ile seçili item'ı bul
    $selectedItem = $global:MountIndexItems | Where-Object { $_.IsSelected } | Select-Object -First 1
    if (-not $selectedItem) { 
        Show-Alert -Title "Eksik Alan" -Message "Bir index seçin."; 
        return 
    }

    $wimFile  = $TxtWimFile.Text
    $mntDir   = $TxtMountFolder.Text
    $idx      = $selectedItem.IndexNumber
    $roRemove = $ChkRemoveReadOnly.IsChecked
    $roMount  = $ChkReadOnly.IsChecked

    # ═══ DURUM 1: Zaten "Mounted" — kaldırmadan direkt aktifleştir ═══
    if ($selectedItem.MountStatus -eq "Mounted" -and $selectedItem.MountPath -ne "") {
        $existingPath = $selectedItem.MountPath
        $global:WIMMounted              = $true
        $global:StrMountedImageLocation = $existingPath
        $global:StrWIM                  = $wimFile
        $global:StrIndex                = $idx
        if ($TxtMountFolder.Text -eq "" -or $TxtMountFolder.Text -ne $existingPath) {
            $TxtMountFolder.Text = $existingPath
        }
        Set-Status -Text "Mounted" -Color "#16A34A"
        Write-Log "Mevcut mount aktifleştirildi: $existingPath [#$idx]" -Level "OK"
        Show-Alert -Title "Bağlantı Aktif" -Message "Bu index zaten mount edilmiş:`n$existingPath`n`nDoğrudan kullanıma alındı, unmount gerekmedi."
        return
    }

    # ═══ DURUM 2: "Remount!" — dism /Remount-Image ile kurtar ═══
    if ($selectedItem.MountStatus -eq "Remount!" -and $selectedItem.MountPath -ne "") {
        $existingPath = $selectedItem.MountPath
        Write-Log "Yeniden bağlanma gerekiyor: $existingPath" -Level "WARN"
        $script:PendingMntDir  = $existingPath
        $script:PendingWimFile = $wimFile
        $script:PendingIdx     = $idx
        $selectedItem.MountStatus      = "Mounting..."
        $selectedItem.MountStatusColor = "#F59E0B"
        $ListViewMountIndex.Items.Refresh()
        $script:MountingItem = $selectedItem
        Set-Status -Text "Remount..." -Color "#F59E0B"
        Start-DismJob -DismArgs "/Remount-Image /MountDir:`"$existingPath`"" -StatusMessage "Yeniden bağlanıyor" -OnComplete {
            param($exitCode)
            if ($exitCode -eq 0) {
                $global:WIMMounted              = $true
                $global:StrMountedImageLocation = $script:PendingMntDir
                $global:StrWIM                  = $script:PendingWimFile
                $global:StrIndex                = $script:PendingIdx
                $TxtMountFolder.Text = $script:PendingMntDir
                Set-Status -Text "Mounted" -Color "#16A34A"
                $mi = $global:MountIndexItems | Where-Object { $_.IndexNumber -eq $script:PendingIdx } | Select-Object -First 1
                if ($mi) { $mi.MountStatus = "Mounted"; $mi.MountStatusColor = "#16A34A" }
                $ListViewMountIndex.Items.Refresh()
                $script:MountingItem = $null
                Show-Alert -Title "Başarılı" -Message "WIM yeniden bağlandı:`n$($script:PendingMntDir)"
            } else {
                Write-Log "Remount başarısız (kod: $exitCode). Cleanup yapılıyor..." -Level "WARN"
                Start-DismJob -DismArgs "/Cleanup-Wim" -StatusMessage "Cleanup" -OnComplete {
                    param($c2)
                    $mi = $global:MountIndexItems | Where-Object { $_.IndexNumber -eq $script:PendingIdx } | Select-Object -First 1
                    if ($mi) { $mi.MountStatus = "Unmounted"; $mi.MountStatusColor = "#9CA3AF"; $mi.MountPath = "" }
                    $ListViewMountIndex.Items.Refresh()
                    $script:MountingItem = $null
                    Show-Alert -Title "Remount Başarısız" -Message "Yeniden bağlantı kurulamadı.`n`nLütfen 'Temizlik' butonunu kullanın, ardından tekrar mount edin."
                }
            }
        }
        return
    }

    # ═══ DURUM 3: Unmounted — normal mount akışı ═══
    if ($mntDir -eq "") { Show-Alert -Title "Eksik Alan" -Message "Lütfen bir mount dizini belirtin."; return }

    # Dosya ve dizin doğrulama
    if (-not (Test-WimFile -Path $wimFile)) { return }
    if (-not (Prepare-MountDirectory -Path $mntDir)) { return }

    # Read-Only dosya kontrolü (UI thread'de — hızlı)
    if ((Get-ItemProperty -Path $wimFile).IsReadOnly) {
        if (-not $roRemove) {
            Show-Alert -Title "Salt Okunur Dosya" -Message "WIM dosyası salt okunur. 'Dosya RO Kaldır' seçeneğini işaretleyerek tekrar deneyin."
            return
        }
        Set-ItemProperty -Path $wimFile -Name IsReadOnly -Value $false
        Write-Log "Salt-okunur özelliği kaldırıldı." -Level "OK"
    }

    Set-Status -Text "Mount işlemi..." -Color "#F59E0B"
    Write-Log "Mount başlıyor → $wimFile [Index:$idx] → $mntDir" -Level "RUN"

    # Pending değerleri global'e yaz — OnComplete timer tick'inde okur
    $script:PendingMntDir  = $mntDir
    $script:PendingWimFile = $wimFile
    $script:PendingIdx     = $idx

    # Rozeti hemen "Mounting..." yap — işlem başladığını göster
    $pendingItem = $global:MountIndexItems | Where-Object { $_.IndexNumber -eq $idx } | Select-Object -First 1
    if ($pendingItem) {
        $pendingItem.MountStatus      = "Mounting..."
        $pendingItem.MountStatusColor = "#F59E0B"
        $ListViewMountIndex.Items.Refresh()
    }
    $script:MountingItem = $pendingItem

    $roFlag    = if ($roMount) { " /ReadOnly" } else { "" }
    $mountArgs = "/Mount-Image /ImageFile:`"$wimFile`" /Index:$idx /MountDir:`"$mntDir`"$roFlag"

    Start-DismJob -DismArgs $mountArgs -StatusMessage "Mount ediliyor" -OnComplete {
        param($exitCode)
        if ($exitCode -eq 0) {
            $global:WIMMounted              = $true
            $global:StrMountedImageLocation = $script:PendingMntDir
            $global:StrWIM                  = $script:PendingWimFile
            $global:StrIndex                = $script:PendingIdx
            Set-Status -Text "Mounted" -Color "#10B981"

            # ListView'daki ilgili index'in durumunu güncelle
            $mountedItem = $global:MountIndexItems | Where-Object { $_.IndexNumber -eq $script:PendingIdx } | Select-Object -First 1
            if ($mountedItem) {
                $mountedItem.MountStatus      = "Mounted"
                $mountedItem.MountStatusColor = "#16A34A"
                $ListViewMountIndex.Items.Refresh()
            }
            $script:MountingItem = $null

            Show-Alert -Title "Başarılı" -Message "WIM imaj dosyası başarıyla mount edildi:`n$($script:PendingMntDir)"
        } else {
            $global:WIMMounted = $false
            Set-Status -Text "Hata" -Color "#EF4444"
            # Rozeti hata durumuna döndür
            if ($null -ne $script:MountingItem) {
                $script:MountingItem.MountStatus      = "Unmounted"
                $script:MountingItem.MountStatusColor = "#9CA3AF"
                $ListViewMountIndex.Items.Refresh()
                $script:MountingItem = $null
            }
            $errorMsg = "Mount işlemi başarısız.`n`nDISM Çıkış Kodu: $exitCode`n`n"
            $errorMsg += "Olası Nedenler:`n"
            $errorMsg += "• Mount dizini erişilemez`n"
            $errorMsg += "• WIM bozuk veya kilitli`n"
            $errorMsg += "• Önceki mount kalıntıları (Cleanup deneyin)`n"
            $errorMsg += "• Yetersiz disk alanı`n`n"
            $errorMsg += "DISM Log'u inceleyin."
            Show-Alert -Title "Mount Hatası" -Message $errorMsg
        }
    }
})

function Unmount-WIM {
    param([bool]$Save)
    if (-not (Assert-WimMounted)) { return }
    
    $mntPath = $global:StrMountedImageLocation
    
    # ReadOnly mount kontrolü - yeni helper ile
    $mountInfo = Get-MountedImageInfo -MountDir $mntPath
    
    if ($mountInfo.IsMounted -and $Save -and $mountInfo.IsReadOnly) {
        Write-Log "UYARI: İmaj ReadOnly mount edilmiş, Commit yapılamaz." -Level "WARN"
        $continue = Show-Confirm -Title "Salt Okunur Mount" `
            -Message "İmaj salt okunur modda mount edildi. Değişiklikler kaydedilemez.`n`nKaydetmeden unmount edilsin mi?" `
            -Icon "⚠️"
        
        if (-not $continue) {
            return
        }
        $Save = $false
    }
    
    $commitFlag = if ($Save) { "/Commit" } else { "/Discard" }
    $action     = if ($Save) { "kaydet" } else { "iptal et" }
    Write-Log "Unmount başlıyor ($action)..." -Level "RUN"
    Set-Status -Text "Unmount..." -Color "#F59E0B"

    # Rozeti hemen "Unmounting..." yap
    $unmountingItem = $global:MountIndexItems | Where-Object { $_.IndexNumber -eq $global:StrIndex } | Select-Object -First 1
    if ($unmountingItem) {
        $unmountingItem.MountStatus      = "Unmounting..."
        $unmountingItem.MountStatusColor = "#F59E0B"
        $ListViewMountIndex.Items.Refresh()
    }
    $script:MountingItem = $unmountingItem

    Start-DismJob -DismArgs "/Unmount-Image /MountDir:`"$mntPath`" $commitFlag" `
                  -StatusMessage "Unmount" -OnComplete {
        param($exitCode)
        if ($exitCode -eq 0) {
            $global:WIMMounted = $false
            Set-Status -Text "Hazır" -Color "#10B981"

            # ListView'daki unmount edilen index'in durumunu güncelle
            $unmountedItem = $global:MountIndexItems | Where-Object { $_.IndexNumber -eq $global:StrIndex } | Select-Object -First 1
            if ($unmountedItem) {
                $unmountedItem.MountStatus      = "Unmounted"
                $unmountedItem.MountStatusColor = "#9CA3AF"
                $ListViewMountIndex.Items.Refresh()
            }
            $script:MountingItem = $null
            $global:StrMountedImageLocation = ""

            # Mount dizinini temizle
            try {
                $items = Get-ChildItem -Path $mntPath -Force -ErrorAction SilentlyContinue
                if ($items.Count -eq 0) {
                    Write-Log "Mount dizini başarıyla temizlendi." -Level "OK"
                }
            } catch {}
        } else {
            Write-Log "Unmount başarısız (Kod: $exitCode) — Zorla temizleme deneniyor..." -Level "ERR"
            # Önce Cleanup-Wim
            Start-DismJob -DismArgs "/Cleanup-Wim" -StatusMessage "Cleanup" -OnComplete {
                param($c2)
                # Sonra tekrar unmount /Discard dene
                Start-DismJob -DismArgs "/Unmount-Image /MountDir:`"$global:StrMountedImageLocation`" /Discard" `
                              -StatusMessage "Zorla Unmount" -OnComplete {
                    param($c3)
                    $global:WIMMounted = $false
                    Set-Status -Text "Hazır" -Color "#10B981"
                    
                    # Zorla unmount'ta da durumu güncelle
                    $fi = $global:MountIndexItems | Where-Object { $_.IndexNumber -eq $global:StrIndex } | Select-Object -First 1
                    if ($fi) {
                        $fi.MountStatus      = "Unmounted"
                        $fi.MountStatusColor = "#9CA3AF"
                        $ListViewMountIndex.Items.Refresh()
                    }
                    $script:MountingItem = $null
                    $global:StrMountedImageLocation = ""
                    if ($c3 -ne 0) {
                        Show-Alert -Title "Unmount Hatası" -Message "İmaj unmount edilemedi.`n`nManuel olarak:`n1. PowerShell (Admin) açın`n2. DISM.EXE /Cleanup-Wim`n3. Mount klasörünü silin`n`nMount Dizini: $mntPath"
                    }
                }
            }
        }
    }
}

$BtnUnmountSave.Add_Click({
    if (-not (Assert-NotBusy)) { return }
    Unmount-WIM -Save $true
})
$BtnUnmountDiscard.Add_Click({
    if (-not (Assert-NotBusy)) { return }
    Unmount-WIM -Save $false
})

$BtnOpenFolder.Add_Click({
    if ($global:StrMountedImageLocation -ne "" -and (Test-Path $global:StrMountedImageLocation)) {
        Start-Process explorer.exe $global:StrMountedImageLocation
    } else { Show-Alert -Title "Dizin Yok" -Message "Mount dizini bulunamadı veya henüz mount yapılmadı." }
})

function Start-NextUnmount {
    if ($script:CleanupIndex -lt $script:CleanupMountDirs.Count) {
        $dir = $script:CleanupMountDirs[$script:CleanupIndex]
        Start-DismJob -DismArgs "/Unmount-Image /MountDir:`"$dir`" /Discard" `
                      -StatusMessage "Unmount ($($script:CleanupIndex + 1)/$($script:CleanupMountDirs.Count))" `
                      -OnComplete {
            param($ec)
            if ($ec -ne 0) { Write-Log "Unmount hatası ($dir): kod $ec" -Level "WARN" }
            $script:CleanupIndex++
            Start-NextUnmount
        }
    } else {
        Write-Log "Tüm unmount işlemleri tamamlandı, cleanup başlıyor..." -Level "OK"
        Start-DismJob -DismArgs "/Cleanup-Wim" -StatusMessage "WIM Cleanup" -OnComplete {
            param($ec2)
            foreach ($dir in $script:CleanupMountDirs) {
                if (Test-Path $dir) {
                    try {
                        $items = Get-ChildItem -Path $dir -Force -ErrorAction SilentlyContinue
                        if ($items.Count -eq 0) {
                            Remove-Item -Path $dir -Force -ErrorAction Stop
                            Write-Log "Mount dizini silindi: $dir" -Level "OK"
                        } else {
                            Write-Log "Mount dizini boş değil, elle silin: $dir ($($items.Count) dosya)" -Level "WARN"
                        }
                    } catch {
                        Write-Log "Mount dizini silinemedi: $dir — $_" -Level "WARN"
                    }
                }
            }
            foreach ($item in $global:MountIndexItems) {
                if ($item.MountStatus -eq "Cleaning..." -or $item.MountStatus -match "%") {
                    $item.MountStatus      = "Unmounted"
                    $item.MountStatusColor = "#9CA3AF"
                }
            }
            $ListViewMountIndex.Items.Refresh()
            $script:MountingItem = $null
            $global:WIMMounted = $false
            $global:StrMountedImageLocation = ""
            Set-Status -Text "Ready" -Color "#10B981"
            Show-Alert -Title "İşlem Tamamlandı" -Message "WIM kayıtları temizlendi."
        }
    }
}

$BtnCleanupWim.Add_Click({
    if (-not (Assert-NotBusy)) { return }

    $continue = Show-Confirm -Title "WIM Temizleme" `
        -Message "Tüm mount edilmiş WIM dosyaları unmount edilecek ve kayıt defterleri temizlenecektir. Kaydedilmemiş değişiklikler kaybolacaktır.`n`nDevam edilsin mi?" `
        -Icon "⚠️"

    if (-not $continue) {
        Write-Log "Cleanup işlemi kullanıcı tarafından iptal edildi" -Level "INFO"
        return
    }

    Write-Log "Tam WIM Cleanup başlatılıyor (Unmount + Cleanup)..." -Level "RUN"
    
    # Adım 1: Mounted image bilgilerini al
    try {
        $mountedImages = Get-WindowsImage -Mounted -ErrorAction SilentlyContinue
        if ($mountedImages) {
            Write-Log "$($mountedImages.Count) adet mount bulundu, unmount ediliyor..." -Level "WARN"
            
            # Her birini sırayla unmount et (Discard)
            $mountDirs = @()
            foreach ($img in $mountedImages) {
                $mountDirs += $img.Path
                Write-Log "Unmount: $($img.Path)" -Level "RUN"
            }

            # Tüm Mounted rozetleri "Cleaning..." yap
            foreach ($item in $global:MountIndexItems) {
                if ($item.MountStatus -eq "Mounted" -or $item.MountStatus -match "%") {
                    $item.MountStatus      = "Cleaning..."
                    $item.MountStatusColor = "#7C3AED"
                }
            }
            $ListViewMountIndex.Items.Refresh()
            # Cleanup sırasında animasyon için MountingItem'ı ilk mounted item'a bağla
            $script:MountingItem = $global:MountIndexItems | Where-Object { $_.MountStatus -eq "Cleaning..." } | Select-Object -First 1

            # İlk unmount'u başlat
            if ($mountDirs.Count -gt 0) {
                $script:CleanupMountDirs = $mountDirs
                $script:CleanupIndex = 0
                Start-NextUnmount
                return
            }
        }
    } catch {
        Write-Log "Mount bilgisi alınamadı: $_" -Level "ERR"
    }

    # Mount yoksa sadece cleanup yap
    Write-Log "Aktif mount bulunamadı, sadece cleanup yapılıyor..." -Level "INFO"
    Start-DismJob -DismArgs "/Cleanup-Wim" -StatusMessage "WIM Cleanup" -OnComplete {
        param($ec)
        $global:WIMMounted = $false
        $script:MountingItem = $null
        Set-Status -Text "Ready" -Color "#10B981"
        Show-Alert -Title "İşlem Tamamlandı" -Message "WIM kayıtları temizlendi."
    }
})


# ═══════════════════════════════════════════════════════
# PG_1 : DRIVER SERVICING
# ═══════════════════════════════════════════════════════
$BtnChooseDriverFolder.Add_Click({
    $f = Select-Folder
    if ($f -ne "") { $TxtDriverFolder.Text = $f }
})

# Select All checkbox handler
$ChkSelectAllDrivers.Add_Checked({
    foreach ($item in $global:DriverItems) {
        $item.IsSelected = $true
    }
    $ListViewDrivers.Items.Refresh()
})

$ChkSelectAllDrivers.Add_Unchecked({
    foreach ($item in $global:DriverItems) {
        $item.IsSelected = $false
    }
    $ListViewDrivers.Items.Refresh()
})

# Seçilen sürücüleri kaldır
$BtnRemoveSelectedDrivers.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    
    $selectedDrivers = $global:DriverItems | Where-Object { $_.IsSelected }
    if ($selectedDrivers.Count -eq 0) {
        Show-Alert -Title "Uyarı" -Message "Kaldırılacak sürücü seçin."
        return
    }
    
    $count = $selectedDrivers.Count
    $result = Show-Confirm -Title "Sürücü Kaldırma Onayı" `
        -Message "$count sürücü kaldırılacak. Devam edilsin mi?" `
        -Icon "⚠️"
    
    if (-not $result) { return }
    
    Write-Log "$count sürücü kaldırılıyor..." -Level "INFO"
    
    # Kuyruğa ekle
    $script:DriverRemoveQueue = New-Object System.Collections.Queue
    foreach ($drv in $selectedDrivers) {
        $script:DriverRemoveQueue.Enqueue($drv.DriverName)
    }
    
    # İlk sürücüyü başlat
    $script:DriverRemoveTotal = $script:DriverRemoveQueue.Count
    Remove-NextDriver
})

function Remove-NextDriver {
    if ($script:DriverRemoveQueue.Count -eq 0) {
        Write-Log "✓ Tüm sürücüler kaldırıldı." -Level "OK"
        Set-Status -Text "Ready" -Color "#10B981"
        
        # DEĞİŞTİRİLDİ: Listeyi yenileme komutu WPF Ana UI thread'ine (Dispatcher) güvenli şekilde iletiliyor
        $window.Dispatcher.InvokeAsync([action]{
            $BtnListDrivers.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }) | Out-Null
        
        return
    }
    
    $driverName = $script:DriverRemoveQueue.Dequeue()
    $remaining = $script:DriverRemoveQueue.Count
    $current = $script:DriverRemoveTotal - $remaining
    
    $drvArgs = "/Image:`"$global:StrMountedImageLocation`" /Remove-Driver /Driver:`"$driverName`""
    Write-Log "[$current/$script:DriverRemoveTotal] $driverName kaldırılıyor..." -Level "RUN"
    
    Start-DismJob -DismArgs $drvArgs -StatusMessage "Sürücü kaldırılıyor ($current/$script:DriverRemoveTotal)" -OnComplete {
        param($exitCode)
        if ($exitCode -eq 0) {
            Write-Log "✓ $driverName kaldırıldı." -Level "OK"
        } else {
            Write-Log "✗ $driverName kaldırılamadı (ExitCode: $exitCode)" -Level "ERR"
        }
        Remove-NextDriver
    }
}

$BtnAddDriver.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    if ($TxtDriverFolder.Text -eq "") { Show-Alert -Title "Eksik Alan" -Message "Lütfen sürücü klasörünü belirtin."; return }
    $drvArgs = "/Image:`"$global:StrMountedImageLocation`" /Add-Driver /Driver:`"$($TxtDriverFolder.Text)`""
    if ($ChkForceUnsigned.IsChecked) { $drvArgs += " /ForceUnsigned" }
    if ($ChkRecurse.IsChecked)       { $drvArgs += " /Recurse" }
    Write-Log "DISM $drvArgs" -Level "RUN"
    Start-DismJob -DismArgs $drvArgs -StatusMessage "Sürücü ekleniyor..."
})

$BtnListDrivers.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    if (-not (Assert-NotBusy)) { return }
    $global:IsBusy = $true
    
    $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Visible
    $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Visible
    $BtnCancelJob.Visibility       = [System.Windows.Visibility]::Visible
    
    $CmbDriverProvider.IsEnabled = $false
    $CmbDriverProvider.Items.Clear()
    $CmbDriverProvider.Items.Add("Tüm Sağlayıcılar") | Out-Null
    $CmbDriverProvider.SelectedIndex = 0
    
    $global:DriverItems.Clear()
    $global:AllDriverItems.Clear()
    $ListViewDrivers.Items.Refresh()

    Write-Log "3. parti sürücüler listeleniyor..." -Level "INFO"
    Set-Progress -Percent 10 -Message "Sürücüler listeleniyor..."
    
    $imgPath = $global:StrMountedImageLocation
    
    $script:DriverListJob = Start-Job -ScriptBlock {
        param($mountPath)
        & DISM.EXE /Image:"$mountPath" /Get-Drivers /English
    } -ArgumentList $imgPath
    
    $script:DriverListTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:DriverListTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:DriverListTimer.Add_Tick({
        if ($script:DriverListJob.State -notin @('Completed','Failed','Stopped')) { return }
        
        $script:DriverListTimer.Stop()
        
        try {
            $output = Receive-Job $script:DriverListJob -ErrorAction Stop
            Remove-Job $script:DriverListJob -Force
            
            $currentDriver = $null
            $driverCount = 0
            
            foreach ($line in $output) {
                $line = $line.Trim()
                
                if ($line -match '^Published Name\s*:\s*(.+)$') {
                    if ($currentDriver) {
                        $global:AllDriverItems.Add($currentDriver)
                        $driverCount++
                    }
                    $currentDriver = [DriverItem]::new()
                    $currentDriver.DriverName = $matches[1].Trim()
                    $currentDriver.IsSelected = $false
                    $currentDriver.ProviderName = "-"
                    $currentDriver.Description = "-"
                    $currentDriver.ClassName = "-"
                    $currentDriver.Version = "-"
                }
                elseif ($line -match '^Original File Name\s*:\s*(.+)$') {
                    if ($currentDriver) { $currentDriver.Description = $matches[1].Trim() }
                }
                elseif ($line -match '^Provider Name\s*:\s*(.+)$') {
                    if ($currentDriver) { $currentDriver.ProviderName = $matches[1].Trim() }
                }
                elseif ($line -match '^Class Name\s*:\s*(.+)$') {
                    if ($currentDriver) { $currentDriver.ClassName = $matches[1].Trim() }
                }
                elseif ($line -match '^Version\s*:\s*(.+)$') {
                    if ($currentDriver) { $currentDriver.Version = $matches[1].Trim() }
                }
            }
            
            if ($currentDriver) {
                $global:AllDriverItems.Add($currentDriver)
                $driverCount++
            }
            
            $providerList = @("Tüm Sağlayıcılar") + ($global:AllDriverItems | 
                Select-Object -ExpandProperty ProviderName -Unique | 
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object)
            
            $window.Dispatcher.Invoke([action]{
                $CmbDriverProvider.IsEnabled = $false
                $CmbDriverProvider.Items.Clear()
                foreach ($p in $providerList) {
                    $CmbDriverProvider.Items.Add($p) | Out-Null
                }
                
                $CmbDriverProvider.IsEnabled = $true
                $CmbDriverProvider.SelectedIndex = 0
                
                $BtnCancelJob.Visibility       = [System.Windows.Visibility]::Collapsed
                $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Collapsed
                $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Collapsed
            })
            
            Write-Log "$driverCount adet 3. parti sürücü listelendi." -Level "OK"
            Set-Progress -Percent 0 -Message "Sistem Hazır."
        } catch {
            Write-Log "Sürücü listesi hatası veya iptal edildi." -Level "ERR"
            Set-Progress -Percent 0 -Message "Hata / İptal."
            
            $window.Dispatcher.Invoke([action]{
                $BtnCancelJob.Visibility       = [System.Windows.Visibility]::Collapsed
                $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Collapsed
                $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Collapsed
            })
        } finally {
            $global:IsBusy = $false
        }
    })
    $script:DriverListTimer.Start()
})

$BtnChooseOnlineExportPath.Add_Click({
    $dest = Select-Folder
    if ($dest -ne "") {
        $TxtOnlineExportPath.Text = $dest
    }
})

$CmbDriverProvider.Add_SelectionChanged({
    if ($CmbDriverProvider.SelectedItem -eq $null) { return }
    if (-not $CmbDriverProvider.IsEnabled) { return }  # ComboBox devre dışıyken event'i işleme
    
    $selectedProvider = $CmbDriverProvider.SelectedItem.ToString()
    
    $global:DriverItems.Clear()
    
    if ($selectedProvider -eq "Tüm Sağlayıcılar") {
        # Tüm sürücüleri göster
        foreach ($drv in $global:AllDriverItems) {
            $global:DriverItems.Add($drv)
        }
    } else {
        # Sadece seçili provider'ı göster
        foreach ($drv in $global:AllDriverItems) {
            if ($drv.ProviderName -eq $selectedProvider) {
                $global:DriverItems.Add($drv)
            }
        }
    }
    
    $ListViewDrivers.Items.Refresh()
    
    # Seçili sürücü sayısını güncelle
    $script:DriverCheckTimer.Stop()
    $script:DriverCheckTimer.Start()
})

$BtnExportDriverOnline.Add_Click({
    $dest = $TxtOnlineExportPath.Text.Trim()
    
    if ([string]::IsNullOrWhiteSpace($dest)) {
        Show-Alert -Title "Uyarı" -Message "Lütfen hedef klasörü seçin."
        return
    }
    
    if (-not (Test-Path $dest)) {
        Show-Alert -Title "Hata" -Message "Hedef klasör bulunamadı."
        return
    }
    
    $drvArgs = "/Online /Export-Driver /Destination:`"$dest`""
    Write-Log "Online sürücü dışa aktarma: $dest" -Level "INFO"
    Start-DismJob -DismArgs $drvArgs -StatusMessage "Online sürücüler dışa aktarılıyor..."
})

# ═══════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════
# PG_2 : PACKAGE SERVICING
# ═══════════════════════════════════════════════════════

# ── Yardımcı: State → Label + Renk ──────────────────────────────────────────
function Get-PackageStateInfo {
    param([string]$State)
    switch -Regex ($State) {
        'Installed'   { return @{ Label = "Installed";   Color = "#16A34A" } }
        'Staged'      { return @{ Label = "Staged";      Color = "#D97706" } }
        'Superseded'  { return @{ Label = "Superseded";  Color = "#7C3AED" } }
        'PermanentlyEnabled' { return @{ Label = "Permanent"; Color = "#0369A1" } }
        'PartiallyInstalled' { return @{ Label = "Partial";   Color = "#D97706" } }
        default       { return @{ Label = $State;        Color = "#6B7280" } }
    }
}

# ── Yardımcı: Paket adından versiyon + mimari çıkar ─────────────────────────
function Parse-PackageName {
    param([string]$Name)
    $version = ""
    $arch    = ""
    # Örn: Microsoft-Windows-NetFx3-OnDemand-Package~31bf3856ad364e35~amd64~~10.0.19041.1
    if ($Name -match '~([^~]+)~~([^~]+)$') {
        $arch    = $Matches[1] -replace 'amd64','x64' -replace 'x86','x86' -replace 'arm64','ARM64'
        $version = $Matches[2]
    } elseif ($Name -match '(\d+\.\d+\.\d+[\.\d]*)') {
        $version = $Matches[1]
    }
    return @{ Version = $version; Architecture = $arch }
}

# ── Yardımcı: İstatistik güncelle ───────────────────────────────────────────
function Update-PackageStats {
    if ($null -eq $TxtPkgTotal) { return }
    $total    = $global:AllPackageItems.Count
    $installed = ($global:AllPackageItems | Where-Object { $_.State -match 'Installed' }).Count
    $selected  = ($global:PackageItems    | Where-Object { $_.IsSelected }).Count
    $TxtPkgTotal.Text     = "Toplam: $total"
    $TxtPkgInstalled.Text = "Installed: $installed"
    $TxtPkgSelected.Text  = "Seçili: $selected"
}

# ── Yardımcı: Filtre uygula ──────────────────────────────────────────────────
function Apply-PackageFilter {
    $search   = if ($null -ne $TxtPackageSearch)    { $TxtPackageSearch.Text.Trim() }       else { "" }
    $stateIdx = if ($null -ne $CmbPackageStateFilter) { $CmbPackageStateFilter.SelectedIndex } else { 0 }

    $global:PackageItems.Clear()
    foreach ($item in $global:AllPackageItems) {
        if ($search -ne "" -and $item.PackageName -notmatch [regex]::Escape($search)) { continue }
        $pass = switch ($stateIdx) {
            1 { $item.State -match 'Installed'  }
            2 { $item.State -match 'Staged'     }
            3 { $item.State -match 'Superseded' }
            4 { $item.State -notmatch 'Installed|Staged|Superseded' }
            default { $true }
        }
        if ($pass) { $global:PackageItems.Add($item) }
    }
    $vis = if ($global:PackageItems.Count -eq 0) { "Visible" } else { "Collapsed" }
    if ($null -ne $LblPackagesEmpty) { $LblPackagesEmpty.Visibility = $vis }
    Update-PackageStats
}

# ── Dosya seçiciler ──────────────────────────────────────────────────────────
$BtnChoosePackage.Add_Click({
    $f = Select-File -Filter "Paket Dosyaları (*.cab;*.msu)|*.cab;*.msu|CAB (*.cab)|*.cab|MSU (*.msu)|*.msu"
    if ($f -ne "") { $TxtPackagePath.Text = $f }
})

$BtnChoosePackageFolder.Add_Click({
    $folder = Select-Folder -Description "CAB/MSU dosyalarını içeren klasörü seçin"
    if ($folder -ne "") { $TxtPackagePath.Text = $folder }
})

# ── Paket ekle ───────────────────────────────────────────────────────────────
$BtnAddPackage.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    $path = $TxtPackagePath.Text.Trim()
    if ($path -eq "") { Show-Alert -Title "Eksik Alan" -Message "Lütfen bir CAB/MSU dosyası veya klasörü seçin."; return }

    # Klasör mü, dosya mı?
    $isFolder = Test-Path $path -PathType Container
    $isFile   = Test-Path $path -PathType Leaf

    if (-not $isFolder -and -not $isFile) {
        Show-Alert -Title "Bulunamadı" -Message "Belirtilen yol bulunamadı:`n$path"
        return
    }

    # Klasör seçildiyse içindeki tüm CAB/MSU'ları listele
    if ($isFolder) {
        $pkgFiles = @(Get-ChildItem -Path $path -Include "*.cab","*.msu" -Recurse -File -ErrorAction SilentlyContinue)
        if ($pkgFiles.Count -eq 0) {
            Show-Alert -Title "Dosya Yok" -Message "Seçilen klasörde .cab veya .msu dosyası bulunamadı."
            return
        }
        $confirm = Show-Confirm -Title "Klasör Paket Ekleme" `
            -Message "$($pkgFiles.Count) paket dosyası bulundu. Tümü eklensin mi?`n`nKlasör: $path" -Icon "📦"
        if (-not $confirm) { return }

        $script:PkgAddQueue = [System.Collections.Queue]::new()
        $script:PkgAddTotal = $pkgFiles.Count
        $script:PkgAddDone  = 0
        foreach ($f in $pkgFiles) { $script:PkgAddQueue.Enqueue($f.FullName) }
        Add-NextPackage
        return
    }

    # Tek dosya
    $pkgArgs = "/Image:`"$global:StrMountedImageLocation`" /Add-Package /PackagePath:`"$path`""
    if ($ChkIgnoreCheck.IsChecked)    { $pkgArgs += " /IgnoreCheck" }
    if ($ChkPreventPending.IsChecked) { $pkgArgs += " /PreventPending" }
    if ($ChkNoRestart.IsChecked)      { $pkgArgs += " /NoRestart" }
    Write-Log "DISM $pkgArgs" -Level "RUN"
    Start-DismJob -DismArgs $pkgArgs -StatusMessage "Paket ekleniyor..." -OnComplete {
        param($ec)
        if ($ec -eq 0) {
            Write-Log "Paket başarıyla eklendi." -Level "OK"
            $BtnListPackages.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        }
    }
})

function Add-NextPackage {
    if ($script:PkgAddQueue.Count -eq 0) {
        Write-Log "Klasör paketi ekleme tamamlandı ($($script:PkgAddTotal) adet)." -Level "OK"
        $BtnListPackages.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        return
    }
    $filePath = $script:PkgAddQueue.Dequeue()
    $current  = $script:PkgAddTotal - $script:PkgAddQueue.Count
    $pkgArgs  = "/Image:`"$global:StrMountedImageLocation`" /Add-Package /PackagePath:`"$filePath`""
    if ($ChkIgnoreCheck.IsChecked)    { $pkgArgs += " /IgnoreCheck" }
    if ($ChkPreventPending.IsChecked) { $pkgArgs += " /PreventPending" }
    if ($ChkNoRestart.IsChecked)      { $pkgArgs += " /NoRestart" }
    Write-Log "[$current/$($script:PkgAddTotal)] Ekleniyor: $(Split-Path $filePath -Leaf)" -Level "RUN"
    Start-DismJob -DismArgs $pkgArgs -StatusMessage "Paket ekleniyor ($current/$($script:PkgAddTotal))" -OnComplete {
        param($ec)
        $script:PkgAddDone++
        if ($ec -ne 0) { Write-Log "Hata (kod: $ec): $(Split-Path $filePath -Leaf)" -Level "WARN" }
        Add-NextPackage
    }
}

# ── Arama + Filtre ────────────────────────────────────────────────────────────
$TxtPackageSearch.Add_TextChanged({ Apply-PackageFilter })
$CmbPackageStateFilter.Add_SelectionChanged({ Apply-PackageFilter })

# ── Seç / Kaldır ─────────────────────────────────────────────────────────────
$BtnPkgSelectAll.Add_Click({
    foreach ($item in $global:PackageItems) { $item.IsSelected = $true }
    $ListViewPackages.Items.Refresh(); Update-PackageStats
})
$BtnPkgSelectNone.Add_Click({
    foreach ($item in $global:AllPackageItems) { $item.IsSelected = $false }
    $ListViewPackages.Items.Refresh(); Update-PackageStats
})
$ChkSelectAllPkgs.Add_Checked({
    foreach ($item in $global:PackageItems) { $item.IsSelected = $true }
    $ListViewPackages.Items.Refresh(); Update-PackageStats
})
$ChkSelectAllPkgs.Add_Unchecked({
    foreach ($item in $global:PackageItems) { $item.IsSelected = $false }
    $ListViewPackages.Items.Refresh(); Update-PackageStats
})

# ── Listele ───────────────────────────────────────────────────────────────────
$BtnListPackages.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    if (-not (Assert-NotBusy))    { return }

    $global:IsBusy = $true
    $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Visible
    $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Visible
    $global:AllPackageItems.Clear()
    $global:PackageItems.Clear()
    $LblPackagesEmpty.Visibility = "Collapsed"
    Set-Progress -Percent 10 -Message "Paketler listeleniyor..."
    Write-Log "Paketler listeleniyor..." -Level "INFO"

    # Yüklü hive'lar varsa paket listesi sırasında kilit çakışması olur.
    # Geçici olarak tüm hive'ları boşalt; işlem bitince yeniden yükle.
    $script:PkgTempUnloadedHives = @()
    if ($script:LoadedHives.Count -gt 0) {
        Write-Log "Paket listesi için hive'lar geçici olarak kaldırılıyor..." -Level "INFO"
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        foreach ($h in @($script:LoadedHives)) {
            $unloadResult = & reg unload "$($h.Key)" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $script:PkgTempUnloadedHives += $h
            }
        }
        $script:LoadedHives.Clear()
        Update-HiveStatusBar
    }

    $mnt = $global:StrMountedImageLocation
    $script:PkgJob = Start-Job -ScriptBlock {
        param($mntPath)
        try {
            Import-Module DISM -ErrorAction Stop
            $pkgs = Get-WindowsPackage -Path $mntPath -ErrorAction Stop
            foreach ($p in $pkgs) {
                "$($p.PackageName)|$($p.PackageState)"
            }
            "__DONE__"
        } catch {
            "__ERR__:$($_.Exception.Message)"
        }
    } -ArgumentList $mnt

    $script:PkgTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:PkgTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:PkgTimer.Add_Tick({
        if ($script:PkgJob.State -notin @('Completed','Failed','Stopped')) { return }
        $script:PkgTimer.Stop()
        try {
            $lines = @(Receive-Job $script:PkgJob -ErrorAction Stop)
            Remove-Job $script:PkgJob -Force

            foreach ($line in $lines) {
                if ($line -eq "__DONE__") { break }
                if ($line.StartsWith("__ERR__:")) {
                    Write-Log "Paket listesi hatası: $($line.Substring(8))" -Level "ERR"
                    break
                }
                $parts = $line -split "\|", 2
                if ($parts.Count -lt 2) { continue }
                $si   = Get-PackageStateInfo -State $parts[1]
                $pInfo = Parse-PackageName   -Name  $parts[0]
                $item = [PackageItem]::new()
                $item.IsSelected    = $false
                $item.PackageName   = $parts[0]
                $item.State         = $parts[1]
                $item.StateLabel    = $si.Label
                $item.StateColor    = $si.Color
                $item.Version       = $pInfo.Version
                $item.Architecture  = $pInfo.Architecture
                $global:AllPackageItems.Add($item)
            }
            # Eski global liste uyumu için (Remove handler kullanıyor)
            $global:PackageNames = $global:AllPackageItems | ForEach-Object { $_.PackageName }
            Apply-PackageFilter
            Write-Log "$($global:AllPackageItems.Count) paket yüklendi." -Level "OK"
        } catch {
            Write-Log "Paket listesi alınamadı: $($_.Exception.Message)" -Level "ERR"
        } finally {
            # Geçici olarak kaldırılan hive'ları yeniden yükle
            if ($script:PkgTempUnloadedHives.Count -gt 0) {
                Write-Log "Hive'lar yeniden yükleniyor..." -Level "INFO"
                foreach ($h in $script:PkgTempUnloadedHives) {
                    $reloadResult = & reg load "$($h.Key)" "$($h.Path)" 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $script:LoadedHives.Add($h)
                        Write-Log "Hive yeniden yüklendi: $($h.Name) → $($h.Key)" -Level "OK"
                    } else {
                        Write-Log "Hive yeniden yüklenemedi: $($h.Name) — $reloadResult" -Level "WARN"
                    }
                }
                $script:PkgTempUnloadedHives = @()
                Update-HiveStatusBar
            }
            $global:IsBusy = $false
            $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Collapsed
            $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Collapsed
            Set-Progress -Percent 0 -Message "Sistem Hazır."
        }
    })
    $script:PkgTimer.Start()
})

# ── Paket Detayı ─────────────────────────────────────────────────────────────
$BtnPkgGetInfo.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    $selected = @($global:PackageItems | Where-Object { $_.IsSelected })
    if ($selected.Count -eq 0) {
        Show-Alert -Title "Seçim Yok" -Message "Detay görmek için bir paket seçin."
        return
    }
    if ($selected.Count -gt 3) {
        Show-Alert -Title "Çok Fazla Seçim" -Message "Detay için en fazla 3 paket seçin."
        return
    }
    if (-not (Assert-NotBusy)) { return }
    $global:IsBusy = $true
    $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Visible
    $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Visible
    Set-Progress -Percent 10 -Message "Paket detayı alınıyor..."

    $mnt   = $global:StrMountedImageLocation
    $names = $selected | ForEach-Object { $_.PackageName }

    $script:PkgInfoJob = Start-Job -ScriptBlock {
        param($mntPath, $pkgNames)
        try {
            Import-Module DISM -ErrorAction Stop
            $out = @()
            foreach ($n in $pkgNames) {
                $p = Get-WindowsPackage -Path $mntPath -PackageName $n -ErrorAction Stop
                $out += "=== $($p.PackageName) ==="
                $out += "Durum         : $($p.PackageState)"
                $out += "Sürüm         : $($p.Version)"
                $out += "Açıklama      : $($p.Description)"
                $out += "Şirket        : $($p.Company)"
                $out += "Oluşturma     : $($p.CreationTime)"
                $out += "Yükleme Zamanı: $($p.InstallTime)"
                $out += "Restart Gerekli: $($p.RestartNeeded)"
                $out += ""
            }
            return $out
        } catch {
            return "__ERR__:$($_.Exception.Message)"
        }
    } -ArgumentList $mnt, $names

    $script:PkgInfoTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:PkgInfoTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:PkgInfoTimer.Add_Tick({
        if ($script:PkgInfoJob.State -notin @('Completed','Failed','Stopped')) { return }
        $script:PkgInfoTimer.Stop()
        try {
            $lines = @(Receive-Job $script:PkgInfoJob -ErrorAction Stop)
            Remove-Job $script:PkgInfoJob -Force
            if ($lines[0] -and $lines[0].StartsWith("__ERR__:")) {
                Write-Log "Detay alınamadı: $($lines[0].Substring(8))" -Level "ERR"
            } else {
                foreach ($l in $lines) { Write-Log $l -Level "INFO" }
                Write-Log "Paket detayı OUTPUT LOG'a yazıldı." -Level "OK"
            }
        } catch {
            Write-Log "Detay hatası: $($_.Exception.Message)" -Level "ERR"
        } finally {
            $global:IsBusy = $false
            $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Collapsed
            $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Collapsed
            Set-Progress -Percent 0 -Message "Sistem Hazır."
        }
    })
    $script:PkgInfoTimer.Start()
})

# ── İsme Göre Kaldır ─────────────────────────────────────────────────────────
$BtnRemovePackageByName.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    $name = $TxtRemovePackageName.Text.Trim()
    if ($name -eq "") { Show-Alert -Title "Eksik Alan" -Message "Kaldırılacak paket adını girin."; return }
    $pkgArgs = "/Image:`"$global:StrMountedImageLocation`" /Remove-Package /PackageName:`"$name`""
    Write-Log "DISM $pkgArgs" -Level "RUN"
    Start-DismJob -DismArgs $pkgArgs -StatusMessage "Paket kaldırılıyor..." -OnComplete {
        param($ec)
        if ($ec -eq 0) {
            $TxtRemovePackageName.Text = ""
            $BtnListPackages.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        }
    }
})

# ── Seçilileri Kaldır ────────────────────────────────────────────────────────
function Remove-NextPackage {
    if ($script:PkgRemoveQueue.Count -eq 0) {
        Write-Log "Paket kaldırma tamamlandı ($($script:PkgRemoveDone) adet)." -Level "OK"
        $BtnListPackages.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        return
    }
    $pkg = $script:PkgRemoveQueue.Dequeue()
    $current = $script:PkgRemoveTotal - $script:PkgRemoveQueue.Count
    Write-Log "[$current/$($script:PkgRemoveTotal)] Kaldırılıyor: $pkg" -Level "RUN"
    Start-DismJob -DismArgs "/Image:`"$script:PkgRemoveMntPath`" /Remove-Package /PackageName:`"$pkg`"" `
                  -StatusMessage "Kaldırılıyor ($current/$($script:PkgRemoveTotal))" -OnComplete {
        param($ec)
        $script:PkgRemoveDone++
        if ($ec -ne 0) { Write-Log "Hata (kod: $ec): $pkg" -Level "WARN" }
        Remove-NextPackage
    }
}

$BtnRemoveSelectedPackages.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    $selected = @($global:PackageItems | Where-Object { $_.IsSelected })
    if ($selected.Count -eq 0) { Show-Alert -Title "Seçim Yok" -Message "Kaldırmak için listeden paket seçin."; return }

    $confirm = Show-Confirm -Title "Paket Kaldırma" `
        -Message "$($selected.Count) paket kaldırılacak.`n`nDevam edilsin mi?" -Icon "⚠️"
    if (-not $confirm) { return }

    $script:PkgRemoveMntPath = $global:StrMountedImageLocation
    $script:PkgRemoveQueue   = [System.Collections.Queue]::new()
    $script:PkgRemoveTotal   = $selected.Count
    $script:PkgRemoveDone    = 0
    foreach ($item in $selected) { $script:PkgRemoveQueue.Enqueue($item.PackageName) }
    Remove-NextPackage
})

# ── Listeyi Dışa Aktar ────────────────────────────────────────────────────────
$BtnPkgExportList.Add_Click({
    if ($global:AllPackageItems.Count -eq 0) {
        Show-Alert -Title "Liste Boş" -Message "Önce paket listesini yükleyin."
        return
    }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title  = "Paket Listesini Kaydet"
    $dlg.Filter = "CSV (*.csv)|*.csv|Metin (*.txt)|*.txt"
    $dlg.FileName = "Packages_$(Get-Date -Format 'yyyyMMdd_HHmm')"
    if ($dlg.ShowDialog($window) -ne $true) { return }

    try {
        $ext = [System.IO.Path]::GetExtension($dlg.FileName).ToLower()
        if ($ext -eq ".csv") {
            "PackageName,State,Version,Architecture" | Set-Content $dlg.FileName -Encoding UTF8
            foreach ($item in $global:AllPackageItems) {
                "`"$($item.PackageName)`",`"$($item.State)`",`"$($item.Version)`",`"$($item.Architecture)`"" |
                    Add-Content $dlg.FileName -Encoding UTF8
            }
        } else {
            foreach ($item in $global:AllPackageItems) {
                "$($item.PackageName)  [$($item.State)]" | Add-Content $dlg.FileName -Encoding UTF8
            }
        }
        Write-Log "Paket listesi dışa aktarıldı: $($dlg.FileName)" -Level "OK"
        Show-Alert -Title "Tamamlandı" -Message "Paket listesi kaydedildi:`n$($dlg.FileName)"
    } catch {
        Write-Log "Dışa aktarma hatası: $($_.Exception.Message)" -Level "ERR"
        Show-Alert -Title "Hata" -Message "Dosya kaydedilemedi:`n$($_.Exception.Message)"
    }
})

# ── Seçim istatistik timer ────────────────────────────────────────────────────
$script:PkgSelectTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PkgSelectTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:PkgSelectTimer.Add_Tick({
    if ($global:PackageItems.Count -eq 0) { return }
    Update-PackageStats
})
$script:PkgSelectTimer.Start()


# ═══════════════════════════════════════════════════════
# PG_14 : OFFLINE REGISTRY
# ═══════════════════════════════════════════════════════

# ── Yüklü hive takibi ────────────────────────────────────────────────────────
$script:LoadedHives = [System.Collections.Generic.List[hashtable]]::new()
# @{ Name = "SOFTWARE"; Key = "HKLM\_OFFLINE_SOFTWARE" }
$script:PkgTempUnloadedHives = @()

function Update-HiveStatusBar {
    if ($script:LoadedHives.Count -eq 0) {
        $TxtRegHiveStatus.Text = "Hiç hive yüklü değil."
        $BtnRegUnloadAll.Visibility = "Collapsed"
        $RegHiveStatusBorder.Background = "#F0FDF4"
        $RegHiveStatusBorder.BorderBrush = "#BBF7D0"
    } else {
        $names = $script:LoadedHives | ForEach-Object { "► $($_.Name)  ($($_.Key))" }
        $TxtRegHiveStatus.Text = ($names -join "     ")
        $BtnRegUnloadAll.Visibility = "Visible"
        $RegHiveStatusBorder.Background = "#EFF6FF"
        $RegHiveStatusBorder.BorderBrush = "#BFDBFE"
    }
}

function Get-HivePath {
    param([string]$HiveName)
    $base = $TxtRegMountDir.Text.TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($base)) {
        Show-Alert -Title "Eksik Alan" -Message "Önce mount dizinini belirtin."
        return $null
    }
    $map = @{
        "SOFTWARE"   = "Windows\System32\config\SOFTWARE"
        "SYSTEM"     = "Windows\System32\config\SYSTEM"
        "DEFAULT"    = "Windows\System32\config\DEFAULT"
        "SAM"        = "Windows\System32\config\SAM"
        "NTUSER.DAT" = "Users\Default\NTUSER.DAT"
    }
    $rel = $map[$HiveName]
    if (-not $rel) { return $null }
    $full = Join-Path $base $rel
    if (-not (Test-Path $full)) {
        Show-Alert -Title "Dosya Bulunamadı" -Message "Hive dosyası bulunamadı:`n$full"
        return $null
    }
    return $full
}

function Load-Hive {
    param([string]$HiveName)
    # Zaten yüklü mü?
    if ($script:LoadedHives | Where-Object { $_.Name -eq $HiveName }) {
        Show-Alert -Title "Zaten Yüklü" -Message "$HiveName hive'ı zaten yüklü."
        return
    }
    $hivePath = Get-HivePath -HiveName $HiveName
    if ($null -eq $hivePath) { return }

    $keyName = "_OFFLINE_$($HiveName -replace '\.DAT','')"
    $regKey  = "HKLM\$keyName"

    $result = & reg load "$regKey" "$hivePath" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $script:LoadedHives.Add(@{ Name = $HiveName; Key = $regKey; Path = $hivePath })
        Write-Log "Hive yüklendi: $HiveName → $regKey" -Level "OK"
        Update-HiveStatusBar
    } else {
        Write-Log "Hive yüklenemedi: $HiveName — $result" -Level "ERR"
        Show-Alert -Title "Hata" -Message "Hive yüklenemedi: $HiveName`n`n$result"
    }
}

function Unload-Hive {
    param([string]$HiveName)
    $entry = $script:LoadedHives | Where-Object { $_.Name -eq $HiveName } | Select-Object -First 1
    if (-not $entry) { return }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    $result = & reg unload "$($entry.Key)" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $script:LoadedHives.Remove($entry) | Out-Null
        Write-Log "Hive kaldırıldı: $HiveName" -Level "OK"
        Update-HiveStatusBar
    } else {
        Write-Log "Hive kaldırılamadı: $HiveName — $result" -Level "WARN"
        Show-Alert -Title "Uyarı" -Message "Hive kaldırılamadı: $HiveName`n`n$result`n`nRegistryEditorı kapatın ve tekrar deneyin."
    }
}

# ── Mount dizini: WIM bağlıysa otomatik doldur ────────────────────────────────
$window.FindName("Nav_14").Add_Checked({
    if ([string]::IsNullOrWhiteSpace($TxtRegMountDir.Text) -and $global:WIMMounted) {
        $TxtRegMountDir.Text = $global:StrMountedImageLocation
    }
})

# ── Kontroller ────────────────────────────────────────────────────────────────
$BtnRegBrowseMountDir.Add_Click({
    $f = Select-Folder -Description "WIM mount dizinini seçin"
    if ($f -ne "") { $TxtRegMountDir.Text = $f }
})

$BtnRegLoadSoftware.Add_Click({ Load-Hive "SOFTWARE"   })
$BtnRegLoadSystem.Add_Click({   Load-Hive "SYSTEM"     })
$BtnRegLoadDefault.Add_Click({  Load-Hive "DEFAULT"    })
$BtnRegLoadSam.Add_Click({      Load-Hive "SAM"        })
$BtnRegLoadNtuser.Add_Click({   Load-Hive "NTUSER.DAT" })

$BtnRegUnloadAll.Add_Click({
    $confirm = Show-Confirm -Title "Tümünü Kaldır" `
        -Message "$($script:LoadedHives.Count) hive kaldırılacak. Kaydedilmemiş değişiklikler korunur.`n`nDevam edilsin mi?" `
        -Icon "⚠️"
    if (-not $confirm) { return }
    $names = @($script:LoadedHives | ForEach-Object { $_.Name })
    foreach ($n in $names) { Unload-Hive $n }
})

# ── .REG İÇE AKTAR ───────────────────────────────────────────────────────────
$BtnRegImportBrowse.Add_Click({
    $f = Select-File -Filter "Registry Dosyası (*.reg)|*.reg"
    if ($f -ne "") { $TxtRegImportFile.Text = $f }
})


# ── .REG PARSE & UYGULA ──────────────────────────────────────────────────────
# .reg dosyasını satır satır parse ederek her key/value'yu reg.exe ile yazar.
# Job ScriptBlock — Start-Job ile arka planda çalışır, UI donmaz.
$script:RegImportJobSB = {
    param([string]$RegFilePath, [hashtable]$OfflineMap)

    function Out-RegLog { param([string]$Msg, [string]$Level = "INFO")
        Write-Output "__LOG__:[$Level] $Msg"
    }

    try {
        $rawLines = [System.IO.File]::ReadAllLines($RegFilePath, [System.Text.Encoding]::Unicode)
        if ($rawLines.Count -le 1) {
            $rawLines = [System.IO.File]::ReadAllLines($RegFilePath, [System.Text.Encoding]::UTF8)
        }
    } catch {
        $rawLines = Get-Content -Path $RegFilePath -Encoding Unicode -ErrorAction SilentlyContinue
        if (-not $rawLines) { $rawLines = Get-Content -Path $RegFilePath -Encoding UTF8 -ErrorAction SilentlyContinue }
    }

    $lines2 = [System.Collections.Generic.List[string]]::new()
    $buffer = ""
    foreach ($raw in $rawLines) {
        $trimmed = $raw.TrimEnd()
        if ($trimmed.EndsWith("\")) { $buffer += $trimmed.TrimEnd("\") }
        else { $lines2.Add($buffer + $trimmed) | Out-Null; $buffer = "" }
    }
    if ($buffer -ne "") { $lines2.Add($buffer) | Out-Null }

    $currentKey = ""; $ok = 0; $skip = 0; $fail = 0
    $deleteKey = 0; $deleteOk = 0; $deleteFail = 0; $totalValues = 0

    function Resolve-OfflineKey2 {
        param([string]$FullKey)
        $isDelete = $FullKey.StartsWith("-")
        if ($isDelete) { $FullKey = $FullKey.TrimStart("-") }
        $FullKey = $FullKey `
            -replace '(?i)^HKEY_LOCAL_MACHINE\\', 'HKLM\' `
            -replace '(?i)^HKEY_CURRENT_USER\\',  'HKCU\' `
            -replace '(?i)^HKEY_CLASSES_ROOT\\',  'HKCR\' `
            -replace '(?i)^HKEY_USERS\\',         'HKU\'  `
            -replace '(?i)^HKEY_CURRENT_CONFIG\\','HKCC\'
        if ($FullKey -match '(?i)^HKLM\\') {
            $sub = $FullKey.Substring(5)
            foreach ($hiveName in @("SOFTWARE","SYSTEM","DEFAULT","SAM","NTUSER")) {
                $subUpper = $sub.ToUpperInvariant(); $hiveUpper = $hiveName.ToUpperInvariant()
                if ($subUpper.StartsWith($hiveUpper + "\") -or $subUpper -eq $hiveUpper) {
                    if ($OfflineMap.ContainsKey($hiveName)) {
                        $rest = if ($sub.Length -gt $hiveName.Length) { $sub.Substring($hiveName.Length) } else { "" }
                        return @{ Key = "$($OfflineMap[$hiveName])$rest"; Delete = $isDelete; Mapped = $true }
                    }
                }
            }
            return @{ Key = $FullKey; Delete = $isDelete; Mapped = $false }
        }
        elseif ($FullKey -match '(?i)^HKCU\\') {
            if ($OfflineMap.ContainsKey("NTUSER")) {
                $sub  = $FullKey.Substring(5)
                $rest = if ($sub.Length -gt 0) { "\$sub" } else { "" }
                return @{ Key = "$($OfflineMap['NTUSER'])$rest"; Delete = $isDelete; Mapped = $true }
            }
            return @{ Key = $FullKey; Delete = $isDelete; Mapped = $false }
        }
        return @{ Key = $FullKey; Delete = $isDelete; Mapped = $false }
    }

    function Invoke-RegExe2 {
        param([string]$RegArgs)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "reg.exe"; $psi.Arguments = $RegArgs
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit(8000) | Out-Null
        return @{ Exit = $p.ExitCode; Err = $p.StandardError.ReadToEnd().Trim() }
    }

    foreach ($line2 in $lines2) {
        if ([string]::IsNullOrWhiteSpace($line2)) { continue }
        $trimLine = $line2.Trim()
        if ($trimLine.StartsWith(";")) { continue }
        if ($trimLine -eq "Windows Registry Editor Version 5.00") { continue }

        if ($trimLine.StartsWith("[") -and $trimLine.EndsWith("]")) {
            $inner    = $trimLine.Substring(1, $trimLine.Length - 2)
            $resolved = Resolve-OfflineKey2 -FullKey $inner
            if ($resolved.Delete) {
                if (-not $resolved.Mapped) { Out-RegLog "  [ATLA] Key silme — hive yüklü değil: $inner" "WARN"; $skip++; $currentKey = ""; continue }
                $r = Invoke-RegExe2 "delete `"$($resolved.Key)`" /f"
                if ($r.Exit -eq 0) { Out-RegLog "  [-] $($resolved.Key) silindi" "OK"; $deleteOk++ }
                else {
                    if ($r.Err -match "bulunamadı|not found|does not exist") { Out-RegLog "  [-] $($resolved.Key) zaten yok" "INFO" }
                    else { Out-RegLog "  [!] $($resolved.Key) silinemedi: $($r.Err)" "WARN"; $deleteFail++ }
                }
                $deleteKey++; $currentKey = ""; continue
            }
            if (-not $resolved.Mapped) { Out-RegLog "  [ATLA] Hive yüklü değil: $inner" "WARN"; $skip++; $currentKey = ""; continue }
            $currentKey = $resolved.Key
            $null = Invoke-RegExe2 "add `"$currentKey`" /f"
            continue
        }

        if ($currentKey -eq "") { continue }
        $valueName = $null; $rawVal = $null
        if ($trimLine.StartsWith("@=")) { $valueName = ""; $rawVal = $trimLine.Substring(2) }
        elseif ($trimLine -match '^"([^"]*)"=(.+)$') { $valueName = $Matches[1]; $rawVal = $Matches[2] }
        else { continue }

        $totalValues++
        $displayName = if ($valueName -eq "") { "(Default)" } else { $valueName }

        if ($rawVal.StartsWith("hex(7):")) {
            $hexParts = ($rawVal.Substring(7) -split ',') | Where-Object { $_ -ne "" }
            $bytes2   = $hexParts | ForEach-Object { [Convert]::ToByte($_.Trim(), 16) }
            $parts2   = if ($bytes2.Count -ge 2) {
                [System.Text.Encoding]::Unicode.GetString([byte[]]$bytes2) -split "`0" | Where-Object { $_ -ne "" }
            } else { @() }
            try {
                $null = New-Item -Path "Registry::$currentKey" -Force -ErrorAction SilentlyContinue
                $propName2 = if ($valueName -eq "") { "(Default)" } else { $valueName }
                $null = New-ItemProperty -Path "Registry::$currentKey" -Name $propName2 -Value $parts2 -PropertyType MultiString -Force -ErrorAction Stop
                $dv = if ($parts2.Count -eq 0) { "(boş)" } else { $parts2 -join " | " }
                Out-RegLog "  [+] $currentKey -> $displayName = [$dv]" "OK"; $ok++
            } catch { Out-RegLog "  [!] $currentKey -> $displayName (MULTI_SZ): $($_.Exception.Message)" "WARN"; $fail++ }
            continue
        }

        $valueType = $null; $valueData = $null
        if ($rawVal.StartsWith("dword:")) {
            $valueType = "REG_DWORD"; $valueData = "0x" + $rawVal.Substring(6).Trim()
        } elseif ($rawVal.StartsWith("hex(b):")) {
            $valueType = "REG_QWORD"
            $hb = ($rawVal.Substring(7) -replace ',','') -replace '\s',''
            $valueData = [Convert]::ToInt64($hb, 16).ToString()
        } elseif ($rawVal.StartsWith("hex(2):")) {
            $valueType = "REG_EXPAND_SZ"
            $hp2 = ($rawVal.Substring(7) -split ',') | Where-Object { $_ -ne "" }
            $b2  = $hp2 | ForEach-Object { [Convert]::ToByte($_.Trim(), 16) }
            $valueData = [System.Text.Encoding]::Unicode.GetString([byte[]]$b2).TrimEnd("`0")
        } elseif ($rawVal.StartsWith("hex:")) {
            $valueType = "REG_BINARY"; $valueData = ($rawVal.Substring(4) -replace ',','') -replace '\s',''
        } elseif ($rawVal.StartsWith('"') -and $rawVal.EndsWith('"')) {
            $valueType = "REG_SZ"
            $valueData = $rawVal.Substring(1, $rawVal.Length - 2) -replace '\\\\','\\' -replace '\\"','"'
        } else {
            $skip++; Out-RegLog "  [ATLA] Tanımlanamayan format: $trimLine" "WARN"; continue
        }

        $nameArg = if ($valueName -eq "") { "/ve" } else { "/v `"$valueName`"" }
        $r2 = Invoke-RegExe2 "add `"$currentKey`" $nameArg /t $valueType /d `"$valueData`" /f"
        if ($r2.Exit -eq 0) { Out-RegLog "  [+] $currentKey -> $displayName = $valueData" "OK"; $ok++ }
        else { Out-RegLog "  [!] $currentKey -> $displayName : $($r2.Err)" "WARN"; $fail++ }
    }

    Write-Output "__DONE__:$ok|$fail|$skip|$deleteKey|$deleteOk|$deleteFail|$totalValues"
}

$script:RegImportJob   = $null
$script:RegImportTimer = $null

$BtnRegImport.Add_Click({
    $regFile = $TxtRegImportFile.Text.Trim()
    if ($regFile -eq "") { Show-Alert -Title "Eksik Alan" -Message "Içe aktarılacak .reg dosyasını seçin."; return }
    if (-not (Test-Path $regFile)) { Show-Alert -Title "Bulunamadı" -Message ".reg dosyası bulunamadı:`n$regFile"; return }
    if ($script:LoadedHives.Count -eq 0) { Show-Alert -Title "Hive Yüklü Değil" -Message "Önce en az bir hive yükleyin."; return }
    if ($global:IsBusy) { Show-Alert -Title "Meşgul" -Message "Şu anda başka bir işlem devam ediyor."; return }

    $loadedNames = ($script:LoadedHives | ForEach-Object { $_.Name }) -join ", "
    $confirm = Show-Confirm -Title ".REG Içe Aktar" `
        -Message ".reg dosyası yüklü hive'lara uygulanacak.`n`nDosya: $regFile`nYüklü hive'lar: $loadedNames`n`nHer key/value ayrı ayrı loglanacak. Devam edilsin mi?" -Icon "warning"
    if (-not $confirm) { return }

    $offlineMapForJob = @{}
    foreach ($h in $script:LoadedHives) {
        $n = $h.Name -replace '\.DAT',''
        $offlineMapForJob[$n] = $h.Key
    }

    $global:IsBusy = $true
    $BtnRegImport.IsEnabled = $false

    Write-Log "─── .REG Içe Aktarma Başladı: $(Split-Path $regFile -Leaf) ───" -Level "INFO"

    $script:RegImportJob = Start-Job -ScriptBlock $script:RegImportJobSB -ArgumentList $regFile, $offlineMapForJob

    $script:RegImportTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:RegImportTimer.Interval = [TimeSpan]::FromMilliseconds(200)

    $script:RegImportTimer.Add_Tick({
        $outLines = Receive-Job -Job $script:RegImportJob -ErrorAction SilentlyContinue

        foreach ($ol in $outLines) {
            if ($ol -match '^__DONE__:(.+)$') {
                $parts2 = $Matches[1] -split '\|'

                $okC = [int]$parts2[0]
                $failC = [int]$parts2[1]
                $skipC = [int]$parts2[2]
                $delKey = [int]$parts2[3]
                $delOk = [int]$parts2[4]
                $delFail = [int]$parts2[5]
                $total = [int]$parts2[6]

                $script:RegImportTimer.Stop()
                Remove-Job -Job $script:RegImportJob -Force -ErrorAction SilentlyContinue

                $script:RegImportJob = $null
                $script:RegImportTimer = $null

                $global:IsBusy = $false
                $BtnRegImport.IsEnabled = $true

                Write-Log "─── .REG Içe Aktarma Tamamlandı ───" -Level "OK"

                $sp = @("Toplam değer: $total", "Başarılı: $okC")
                if ($delOk   -gt 0) { $sp += "Silinen key: $delOk" }
                if ($failC   -gt 0) { $sp += "Hatalı: $failC" }
                if ($delFail -gt 0) { $sp += "Silinemeyen: $delFail" }
                if ($skipC   -gt 0) { $sp += "Atlanan: $skipC" }

                Write-Log ("  " + ($sp -join " | ")) -Level "OK"

                $msg = "Içe aktarma tamamlandı.`n`nToplam değer   : $total`nBaşarılı       : $okC`n"
                if ($delOk   -gt 0) { $msg += "Silinen key    : $delOk`n" }
                if ($failC   -gt 0) { $msg += "Hatalı         : $failC`n" }
                if ($delFail -gt 0) { $msg += "Silinemeyen    : $delFail`n" }
                if ($skipC   -gt 0) { $msg += "Atlanan        : $skipC`n" }

                $msg += "`nDetaylar için OUTPUT LOG'u inceleyin."

                Show-Alert -Title "Tamamlandı" -Message $msg
                return
            }
            elseif ($ol -match '^__LOG__:\[(\w+)\] (.+)$') {
                Write-Log $Matches[2] -Level $Matches[1]
            }
            elseif ($ol -match '^__LOG__:(.+)$') {
                Write-Log $Matches[1]
            }
        }

        if ($script:RegImportJob -and $script:RegImportJob.State -eq "Failed") {
            $script:RegImportTimer.Stop()

            $errMsg = $script:RegImportJob.ChildJobs[0].JobStateInfo.Reason.Message

            Remove-Job -Job $script:RegImportJob -Force -ErrorAction SilentlyContinue

            $script:RegImportJob = $null
            $script:RegImportTimer = $null

            $global:IsBusy = $false
            $BtnRegImport.IsEnabled = $true

            Write-Log ".reg içe aktarma hatası: $errMsg" -Level "ERR"
            Show-Alert -Title "Hata" -Message "Içe aktarma başarısız:`n$errMsg"
        }
    })

    $script:RegImportTimer.Start()
})

$Tweaks = @(
    @{
        Check = $ChkTweakCortana
        Label = "Cortana"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\Windows Search"; N="AllowCortana"; T="REG_DWORD"; V="0" }
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\Windows Search"; N="DisableWebSearch"; T="REG_DWORD"; V="1" }
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\Windows Search"; N="ConnectedSearchUseWeb"; T="REG_DWORD"; V="0" }
        )
    }
    @{
        Check = $ChkTweakActivityHistory
        Label = "Etkinlik Geçmişi"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\System"; N="EnableActivityFeed"; T="REG_DWORD"; V="0" }
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\System"; N="PublishUserActivities"; T="REG_DWORD"; V="0" }
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\System"; N="UploadUserActivities"; T="REG_DWORD"; V="0" }
        )
    }
    @{
        Check = $ChkTweakAdId
        Label = "Reklam Kimliği"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo"; N="DisabledByGroupPolicy"; T="REG_DWORD"; V="1" }
        )
    }
    @{
        Check = $ChkTweakFeedback
        Label = "Geri Bildirim"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\DataCollection"; N="DoNotShowFeedbackNotifications"; T="REG_DWORD"; V="1" }
        )
    }
    @{
        Check = $ChkTweakAppCompat
        Label = "Uygulama Uyumluluk Telemetri"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\AppCompat"; N="AITEnable"; T="REG_DWORD"; V="0" }
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\AppCompat"; N="DisableInventory"; T="REG_DWORD"; V="1" }
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\AppCompat"; N="DisablePCA"; T="REG_DWORD"; V="1" }
        )
    }
    @{
        Check = $ChkTweakDefender
        Label = "Windows Defender RealtimeMonitoring"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows Defender"; N="DisableAntiSpyware"; T="REG_DWORD"; V="1" }
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection"; N="DisableRealtimeMonitoring"; T="REG_DWORD"; V="1" }
        )
    }
    @{
        Check = $ChkTweakSmartScreen
        Label = "SmartScreen"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\System"; N="EnableSmartScreen"; T="REG_DWORD"; V="0" }
            @{ P="HKLM\_OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"; N="SmartScreenEnabled"; T="REG_SZ"; V="Off" }
        )
    }
    @{
        Check = $ChkTweakUac
        Label = "UAC Seviye Düşür"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; N="ConsentPromptBehaviorAdmin"; T="REG_DWORD"; V="0" }
            @{ P="HKLM\_OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; N="PromptOnSecureDesktop"; T="REG_DWORD"; V="0" }
        )
    }
    @{
        Check = $ChkTweakAutoplay
        Label = "AutoPlay/AutoRun"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\Explorer"; N="NoAutoplayfornonVolume"; T="REG_DWORD"; V="1" }
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\Explorer"; N="NoDriveTypeAutoRun"; T="REG_DWORD"; V="255" }
        )
    }
    @{
        Check = $ChkTweakWuAuto
        Label = "Otomatik Güncelleme"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; N="NoAutoUpdate"; T="REG_DWORD"; V="0" }
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; N="AUOptions"; T="REG_DWORD"; V="2" }
        )
    }
    @{
        Check = $ChkTweakDeliveryOpt
        Label = "Delivery Optimization"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"; N="DODownloadMode"; T="REG_DWORD"; V="0" }
        )
    }
    @{
        Check = $ChkTweakMsrt
        Label = "MSRT"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\MRT"; N="DontOfferThroughWUAU"; T="REG_DWORD"; V="1" }
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\MRT"; N="DontReportInfectionInformation"; T="REG_DWORD"; V="1" }
        )
    }
    @{
        Check = $ChkTweakVerboseBoot
        Label = "Verbose Boot"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; N="VerboseStatus"; T="REG_DWORD"; V="1" }
        )
    }
    @{
        Check = $ChkTweakAnimations
        Label = "Animasyonlar"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; N="AnimateWindows"; T="REG_DWORD"; V="0" }
        )
    }
    @{
        Check = $ChkTweakNewsInterests
        Label = "Haberler ve İlgi Alanları"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\Windows Feeds"; N="EnableFeeds"; T="REG_DWORD"; V="0" }
        )
    }
    @{
        Check = $ChkTweakStartSugg
        Label = "Başlat Menüsü Önerileri"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\CloudContent"; N="DisableWindowsConsumerFeatures"; T="REG_DWORD"; V="1" }
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\CloudContent"; N="DisableSoftLanding"; T="REG_DWORD"; V="1" }
        )
    }
    @{
        Check = $ChkTweakSearchTaskbar
        Label = "Görev Çubuğu Arama"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\Windows Search"; N="SearchboxTaskbarMode"; T="REG_DWORD"; V="1" }
        )
    }
    @{
        Check = $ChkTweakTaskView
        Label = "Görev Görünümü"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; N="ShowTaskViewButton"; T="REG_DWORD"; V="0" }
        )
    }
    @{
        Check = $ChkTweakCopilot
        Label = "Copilot"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; N="TurnOffWindowsCopilot"; T="REG_DWORD"; V="1" }
        )
    }
    @{
        Check = $ChkTweakNbns
        Label = "NBNS / LLMNR"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SYSTEM\CurrentControlSet\Services\NetBT\Parameters"; N="NodeType"; T="REG_DWORD"; V="2" }
            @{ P="HKLM\_OFFLINE_SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"; N="EnableMulticast"; T="REG_DWORD"; V="0" }
        )
    }
    @{
        Check = $ChkTweakIpv6
        Label = "IPv6"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters"; N="DisabledComponents"; T="REG_DWORD"; V="255" }
        )
    }
    @{
        Check = $ChkTweakHibernation
        Label = "Hazırda Bekletme"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SYSTEM\CurrentControlSet\Control\Session Manager\Power"; N="HibernateEnabled"; T="REG_DWORD"; V="0" }
        )
    }
    @{
        Check = $ChkTweakRemoteReg
        Label = "Uzak Kayıt Defteri"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SYSTEM\CurrentControlSet\Services\RemoteRegistry"; N="Start"; T="REG_DWORD"; V="4" }
        )
    }
    @{
        Check = $ChkTweakLmHash
        Label = "LM Hash"
        Keys  = @(
            @{ P="HKLM\_OFFLINE_SYSTEM\CurrentControlSet\Control\Lsa"; N="NoLMHash"; T="REG_DWORD"; V="1" }
        )
    }
)

$BtnRegSelectAllTweaks.Add_Click({
    $defs = Get-TweakDefinitions
    foreach ($d in $defs) {
        if ($null -ne $d.Check) { $d.Check.IsChecked = $true }
    }
})

$BtnRegApplySelected.Add_Click({
    if ($script:LoadedHives.Count -eq 0) {
        Show-Alert -Title "Hive Yüklü Değil" -Message "Önce SOFTWARE ve/veya SYSTEM hive'ını yükleyin."
        return
    }

    $defs     = Get-TweakDefinitions
    $selected = @($defs | Where-Object { $null -ne $_.Check -and $_.Check.IsChecked })

    if ($selected.Count -eq 0) {
        Show-Alert -Title "Seçim Yok" -Message "Uygulanacak en az bir ayar seçin."
        return
    }

    $labels  = ($selected | ForEach-Object { "• $($_.Label)" }) -join "`n"
    $confirm = Show-Confirm -Title "Preset Tweaks Uygula" `
        -Message "$($selected.Count) ayar uygulanacak:`n$labels`n`nDevam edilsin mi?" -Icon "⚙️"
    if (-not $confirm) { return }

    $ok = 0; $fail = 0
    foreach ($tweak in $selected) {
        foreach ($k in $tweak.Keys) {
            # Key'in var olduğundan emin ol — cmd /c ile tırnak sorunlarını önle
            $null = cmd /c "reg add `"$($k.P)`" /f" 2>&1
            $result = cmd /c "reg add `"$($k.P)`" /v `"$($k.N)`" /t $($k.T) /d `"$($k.V)`" /f" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $ok++
            } else {
                Write-Log "Tweak hatası [$($tweak.Label)] $($k.N): $result" -Level "WARN"
                $fail++
            }
        }
    }

    Write-Log "Preset tweaks tamamlandı: $ok başarılı, $fail hatalı." -Level "OK"
    $msg = "$($selected.Count) ayar uygulandı.`n✓ Başarılı değer: $ok"
    if ($fail -gt 0) { $msg += "`n⚠ Hatalı değer: $fail (OUTPUT LOG'u inceleyin)" }
    Show-Alert -Title "Tamamlandı" -Message $msg
})

# ── HİVE ARAMA ───────────────────────────────────────────────────────────────
$BtnRegSearch.Add_Click({
    $query = $TxtRegSearchQuery.Text.Trim()
    if ($query -eq "") { Show-Alert -Title "Eksik Alan" -Message "Arama metnini girin."; return }

    $hiveName = $CmbRegSearchHive.SelectedItem.Content
    $hiveEntry = $script:LoadedHives | Where-Object { $_.Name -eq $hiveName } | Select-Object -First 1

    if (-not $hiveEntry) {
        Show-Alert -Title "Hive Yüklü Değil" -Message "$hiveName hive'ı yüklü değil. Önce yükleyin."
        return
    }

    $LstRegSearchResults.Items.Clear()
    $LstRegSearchResults.Items.Add("Aranıyor: '$query' in $($hiveEntry.Key) ...") | Out-Null

    $rootKey = $hiveEntry.Key

    if (-not (Assert-NotBusy)) { return }
    $global:IsBusy = $true
    $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Visible
    $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Visible
    Set-Progress -Percent 10 -Message "Registry aranıyor..."

    $script:RegSearchJob = Start-Job -ScriptBlock {
        param($root, $q)
        try {
            $results = @()
            $out = & reg query "$root" /s /f "$q" 2>&1
            $currentKey = ""
            foreach ($line in $out) {
                if ($line -match '^HKLM\\') {
                    $currentKey = $line.Trim()
                } elseif ($line -match '^\s+\S') {
                    if ($currentKey) {
                        $results += "$currentKey`n    $($line.Trim())"
                    }
                }
                if ($results.Count -ge 200) {
                    $results += "... (ilk 200 sonuç gösteriliyor)"
                    break
                }
            }
            if ($results.Count -eq 0) { $results += "(Sonuç bulunamadı)" }
            return $results
        } catch {
            return @("HATA: $($_.Exception.Message)")
        }
    } -ArgumentList $rootKey, $query

    $script:RegSearchTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:RegSearchTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:RegSearchTimer.Add_Tick({
        if ($script:RegSearchJob.State -notin @('Completed','Failed','Stopped')) { return }
        $script:RegSearchTimer.Stop()
        try {
            $results = @(Receive-Job $script:RegSearchJob -ErrorAction Stop)
            Remove-Job $script:RegSearchJob -Force
            $LstRegSearchResults.Items.Clear()
            foreach ($r in $results) { $LstRegSearchResults.Items.Add($r) | Out-Null }
            Write-Log "Registry arama tamamlandı: $($results.Count) sonuç." -Level "OK"
        } catch {
            Write-Log "Registry arama hatası: $($_.Exception.Message)" -Level "ERR"
        } finally {
            $global:IsBusy = $false
            $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Collapsed
            $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Collapsed
            Set-Progress -Percent 0 -Message "Sistem Hazır."
        }
    })
    $script:RegSearchTimer.Start()
})

# ── Pencere kapanırken hive'ları temizle ─────────────────────────────────────
# (window.Add_Closing içine eklenecek cleanup zaten var — LoadedHives unload)
$window.Add_Closing({
    foreach ($h in @($script:LoadedHives)) {
        try {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            & reg unload "$($h.Key)" 2>&1 | Out-Null
        } catch {}
    }
} )

# ═══════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════
# PG_3 : FEATURES ON DEMAND
# ═══════════════════════════════════════════════════════

# ── Yardımcı: State → Label + Renk ──────────────────────────────────────────
function Get-FeatureStateInfo {
    param([string]$State)
    switch -Regex ($State) {
        'Enabled'        { return @{ Label = "Etkin";      Color = "#16A34A" } }
        'EnablePending'  { return @{ Label = "Etkin↑";     Color = "#D97706" } }
        'DisablePending' { return @{ Label = "Devre↓";     Color = "#D97706" } }
        'Removed'        { return @{ Label = "Kaldırıldı"; Color = "#B91C1C" } }
        default          { return @{ Label = "Devre Dışı"; Color = "#6B7280" } }
    }
}

# ── Yardımcı: İstatistik çubuğunu güncelle ──────────────────────────────────
function Update-FeatureStats {
    if ($null -eq $TxtFeatureCount) { return }
    $total    = $global:AllFeatureItems.Count
    $enabled  = ($global:AllFeatureItems | Where-Object { $_.State -match 'Enabled' }).Count
    $disabled = $total - $enabled
    $selected = ($global:FeatureItems    | Where-Object { $_.IsSelected }).Count
    $TxtFeatureCount.Text    = "Toplam: $total"
    $TxtFeatureEnabled.Text  = "Etkin: $enabled"
    $TxtFeatureDisabled.Text = "Devre Dışı: $disabled"
    $TxtFeatureSelected.Text = "Seçili: $selected"
}

# ── Yardımcı: Filtre uygula ──────────────────────────────────────────────────
function Apply-FeatureFilter {
    $search    = if ($null -ne $TxtFeatureSearch)      { $TxtFeatureSearch.Text.Trim() }     else { "" }
    $stateIdx  = if ($null -ne $CmbFeatureStateFilter) { $CmbFeatureStateFilter.SelectedIndex } else { 0 }

    $global:FeatureItems.Clear()
    foreach ($item in $global:AllFeatureItems) {
        # Metin filtresi
        if ($search -ne "" -and
            $item.FeatureName  -notmatch [regex]::Escape($search) -and
            $item.DisplayName  -notmatch [regex]::Escape($search)) { continue }
        # Durum filtresi
        $pass = switch ($stateIdx) {
            1 { $item.State -match 'Enabled' }
            2 { $item.State -notmatch 'Enabled' -and $item.State -ne 'Removed' }
            3 { $item.State -match 'Pending' }
            default { $true }
        }
        if ($pass) { $global:FeatureItems.Add($item) }
    }
    $vis = if ($global:FeatureItems.Count -eq 0) { "Visible" } else { "Collapsed" }
    if ($null -ne $LblFeaturesEmpty) { $LblFeaturesEmpty.Visibility = $vis }
    Update-FeatureStats
}

# ── Kaynak gözat ─────────────────────────────────────────────────────────────
$BtnFeatureSourceBrowse.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title  = "Kaynak dosyayı seçin"
    $dlg.Filter = "Desteklenen Dosyalar (*.cab;*.wim;*.esd)|*.cab;*.wim;*.esd|CAB Dosyası (*.cab)|*.cab|WIM Dosyası (*.wim)|*.wim|ESD Dosyası (*.esd)|*.esd|Tüm Dosyalar (*.*)|*.*"
    if ($dlg.ShowDialog() -eq $true) { $TxtFeatureSource.Text = $dlg.FileName }
})

$TxtFeatureSource.Add_TextChanged({
    $has = ($TxtFeatureSource.Text.Trim() -ne "")
    $BtnInstallFromSource.IsEnabled = $has
})

# ── Kaynaktan Yükle ──────────────────────────────────────────────────────────
$BtnInstallFromSource.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    if (-not (Assert-NotBusy))    { return }

    $srcPath = $TxtFeatureSource.Text.Trim()
    if ($srcPath -eq "") {
        Show-Alert -Title "Kaynak Yok" -Message "Önce bir .cab / .wim / .esd kaynak dosyası seçin."
        return
    }
    if (-not (Test-Path $srcPath)) {
        Show-Alert -Title "Dosya Bulunamadı" -Message "Seçilen kaynak dosyası mevcut değil:`n$srcPath"
        return
    }

    # Seçili feature varsa onları, yoksa listede görünen tümünü hedef al
    $targets = @($global:FeatureItems | Where-Object { $_.IsSelected })
    if ($targets.Count -eq 0) {
        Show-Alert -Title "Seçim Yok" -Message "Kaynaktan yüklemek için listeden en az bir özellik seçin."
        return
    }

    $names   = ($targets | ForEach-Object { $_.FeatureName }) -join ", "
    $confirm = Show-Confirm -Title "Kaynaktan Yükle" `
        -Message "$($targets.Count) özellik şu kaynaktan yüklenecek:`n$srcPath`n`nÖzellikler: $names`n`nDevam edilsin mi?" `
        -Icon "📦"
    if (-not $confirm) { return }

    # Kuyruğa al ve işlemi başlat — Invoke-FeatureAction ile aynı altyapı
    $script:FeatureActionQueue  = [System.Collections.Queue]::new()
    $script:FeatureActionVerb   = "Enable"
    $script:FeatureActionTotal  = $targets.Count
    $script:FeatureActionDone   = 0
    foreach ($item in $targets) { $script:FeatureActionQueue.Enqueue($item.FeatureName) }

    # Kaynak yolu geçici olarak overridelanır — mevcut TxtFeatureSource zaten dolu
    Invoke-NextFeatureAction
})

# ── Arama filtresi ────────────────────────────────────────────────────────────
$TxtFeatureSearch.Add_TextChanged({ Apply-FeatureFilter })
$CmbFeatureStateFilter.Add_SelectionChanged({ Apply-FeatureFilter })

# ── Listele ───────────────────────────────────────────────────────────────────
$BtnListFeatures.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    if (-not (Assert-NotBusy))    { return }

    $global:IsBusy = $true
    $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Visible
    $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Visible
    $global:AllFeatureItems.Clear()
    $global:FeatureItems.Clear()
    $LblFeaturesEmpty.Visibility = "Collapsed"
    $TxtFeatureCount.Text = "Toplam: —"
    $TxtFeatureEnabled.Text = "Etkin: —"
    $TxtFeatureDisabled.Text = "Devre Dışı: —"
    $TxtFeatureSelected.Text = "Seçili: 0"

    Set-Progress -Percent 10 -Message "Özellikler listeleniyor..."
    Write-Log "Features listeleniyor: $global:StrMountedImageLocation" -Level "INFO"

    $mnt = $global:StrMountedImageLocation
    $script:FeatureListJob = Start-Job -ScriptBlock {
        param($mountPath)
        try {
            Import-Module DISM -ErrorAction Stop
            $features = Get-WindowsOptionalFeature -Path $mountPath -ErrorAction Stop
            foreach ($f in $features) {
                "$($f.FeatureName)|$($f.DisplayName)|$($f.State)"
            }
            "__DONE__"
        } catch {
            "__ERR__:$($_.Exception.Message)"
        }
    } -ArgumentList $mnt

    $script:FeatureListTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:FeatureListTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:FeatureListTimer.Add_Tick({
        if ($script:FeatureListJob.State -notin @('Completed','Failed','Stopped')) { return }
        $script:FeatureListTimer.Stop()
        try {
            $lines = @(Receive-Job $script:FeatureListJob -ErrorAction Stop)
            Remove-Job $script:FeatureListJob -Force

            foreach ($line in $lines) {
                if ($line -eq "__DONE__") { break }
                if ($line.StartsWith("__ERR__:")) {
                    Write-Log "Özellik listesi hatası: $($line.Substring(8))" -Level "ERR"
                    break
                }
                $parts = $line -split "\|", 3
                if ($parts.Count -lt 3) { continue }
                $si = Get-FeatureStateInfo -State $parts[2]
                $item = [FeatureItem]::new()
                $item.IsSelected  = $false
                $item.FeatureName = $parts[0]
                $item.DisplayName = if ($parts[1]) { $parts[1] } else { $parts[0] }
                $item.State       = $parts[2]
                $item.StateLabel  = $si.Label
                $item.StateColor  = $si.Color
                $global:AllFeatureItems.Add($item)
            }
            Apply-FeatureFilter
            Write-Log "$($global:AllFeatureItems.Count) özellik yüklendi." -Level "OK"
        } catch {
            Write-Log "Özellik listesi alınamadı: $($_.Exception.Message)" -Level "ERR"
        } finally {
            $global:IsBusy = $false
            $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Collapsed
            $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Collapsed
            Set-Progress -Percent 0 -Message "Sistem Hazır."
        }
    })
    $script:FeatureListTimer.Start()
})

# ── Seçilileri işle (Enable / Disable) ───────────────────────────────────────
function Invoke-FeatureAction {
    param([string]$Action)   # "Enable" veya "Disable"

    if (-not (Assert-WimMounted)) { return }
    $selected = @($global:FeatureItems | Where-Object { $_.IsSelected })
    if ($selected.Count -eq 0) {
        Show-Alert -Title "Seçim Yok" -Message "İşlem yapılacak en az bir özellik seçin."
        return
    }

    $verb   = if ($Action -eq "Enable") { "etkinleştirilecek" } else { "devre dışı bırakılacak" }
    $names  = ($selected | ForEach-Object { $_.FeatureName }) -join ", "
    $confirm = Show-Confirm -Title "Özellik İşlemi" `
        -Message "$($selected.Count) özellik ${verb}:`n$names`n`nDevam edilsin mi?" -Icon "⚙️"
    if (-not $confirm) { return }

    # İşlem kuyruğu oluştur
    $script:FeatureActionQueue  = [System.Collections.Queue]::new()
    $script:FeatureActionVerb   = $Action
    $script:FeatureActionTotal  = $selected.Count
    $script:FeatureActionDone   = 0
    foreach ($item in $selected) { $script:FeatureActionQueue.Enqueue($item.FeatureName) }
    Invoke-NextFeatureAction
}

function Invoke-NextFeatureAction {
    if ($script:FeatureActionQueue.Count -eq 0) {
        Write-Log "Tüm özellik işlemleri tamamlandı ($($script:FeatureActionTotal) adet)." -Level "OK"
        # Listeyi güncelle
        $BtnListFeatures.RaiseEvent([System.Windows.RoutedEventArgs]::new(
            [System.Windows.Controls.Button]::ClickEvent))
        return
    }

    $name = $script:FeatureActionQueue.Dequeue()
    $current = $script:FeatureActionTotal - $script:FeatureActionQueue.Count
    $dismCmd = if ($script:FeatureActionVerb -eq "Enable") { "/Enable-Feature" } else { "/Disable-Feature" }
    
    $fArgs = "/Image:`"$global:StrMountedImageLocation`" $dismCmd /FeatureName:`"$name`""
    
    if ($script:FeatureActionVerb -eq "Enable") {
        if ($ChkFeatureAll.IsChecked) { $fArgs += " /All" }
        if ($ChkFeatureLimitAccess.IsChecked) { $fArgs += " /LimitAccess" }
        
        if ($TxtFeatureSource.Text -ne "") {
            $srcPath = $TxtFeatureSource.Text.Trim()
            if (Test-Path $srcPath -PathType Leaf) {
                $ext = [System.IO.Path]::GetExtension($srcPath).ToLower()
                if ($ext -eq ".wim") {
                    $fArgs += " /Source:wim:`"$srcPath`":1"
                } elseif ($ext -eq ".esd") {
                    $fArgs += " /Source:esd:`"$srcPath`":1"
                } else {
                    # Eğer .cab vb. bir dosya seçildiyse doğrudan dosya yolunu değil, bulunduğu klasörü vermeliyiz
                    $srcDir = Split-Path $srcPath -Parent
                    $fArgs += " /Source:`"$srcDir`""
                }
            } else {
                # Klasör seçildiyse doğrudan kullan
                $fArgs += " /Source:`"$srcPath`""
            }
        }
    }

    Write-Log "[$current/$($script:FeatureActionTotal)] $($script:FeatureActionVerb): $name" -Level "RUN"
    
    Start-DismJob -DismArgs $fArgs -StatusMessage "$name ($current/$($script:FeatureActionTotal))" -OnComplete {
        param($ec)
        $script:FeatureActionDone++
        if ($ec -ne 0) {
            Write-Log "$name işlemi başarısız (kod: $ec)" -Level "WARN"
        }
        Invoke-NextFeatureAction
    }
}

$BtnEnableFeature.Add_Click({  Invoke-FeatureAction -Action "Enable"  })
$BtnDisableFeature.Add_Click({ Invoke-FeatureAction -Action "Disable" })

# ── Özellik Detayı ────────────────────────────────────────────────────────────
$BtnFeatureInfo.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    
    $selected = @($global:FeatureItems | Where-Object { $_.IsSelected })
    if ($selected.Count -eq 0) {
        Show-Alert -Title "Seçim Yok" -Message "Detay görmek için bir özellik seçin."
        return
    }
    if ($selected.Count -gt 3) {
        Show-Alert -Title "Çok Fazla Seçim" -Message "Detay için en fazla 3 özellik seçin."
        return
    }
    if (-not (Assert-NotBusy)) { return }
    
    $global:IsBusy = $true
    $BusyOverlayMenu.Visibility = [System.Windows.Visibility]::Visible
    $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Visible
    Set-Progress -Percent 10 -Message "Özellik detayı alınıyor..."
    
    $mnt = $global:StrMountedImageLocation
    $names = $selected | ForEach-Object { $_.FeatureName }
    
    $script:FeatureInfoJob = Start-Job -ScriptBlock {
        param($mountPath, $featureNames)
        try {
            Import-Module DISM -ErrorAction Stop
            $out = @()
            foreach ($name in $featureNames) {
                $f = Get-WindowsOptionalFeature -Path $mountPath -FeatureName $name -ErrorAction Stop
                $out += "=== $($f.FeatureName) ==="
                $out += "Durum       : $($f.State)"
                $out += "Açıklama    : $($f.Description)"
                
                # --- CustomProperties (Özel Eylemler) Çözümlemesi ---
                if ($null -ne $f.CustomProperties -and @($f.CustomProperties).Count -gt 0) {
                    $cpList = @()
                    foreach ($cp in $f.CustomProperties) {
                        # Her bir özelliğin Name ve Value değerini birleştir
                        $cpList += "$($cp.Name)=$($cp.Value)"
                    }
                    $out += "Özel Eyleml : $($cpList -join ' | ')"
                } else {
                    $out += "Özel Eyleml : Yok"
                }
                
                $out += ""
            }
            return $out
        } catch {
            return "__ERR__:$($_.Exception.Message)"
        }
    } -ArgumentList $mnt, $names
    
    $script:FeatureInfoTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:FeatureInfoTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:FeatureInfoTimer.Add_Tick({
        if ($script:FeatureInfoJob.State -notin @('Completed','Failed','Stopped')) { return }
        
        $script:FeatureInfoTimer.Stop()
        try {
            $lines = @(Receive-Job $script:FeatureInfoJob -ErrorAction Stop)
            Remove-Job $script:FeatureInfoJob -Force
            
            if ($lines[0] -and $lines[0].StartsWith("__ERR__:kr")) {
                 Write-Log "Detay alınamadı: $($lines[0].Substring(8))" -Level "ERR"
            } elseif ($lines[0] -and $lines[0].StartsWith("__ERR__:")){
                 Write-Log "Detay alınamadı: $($lines[0].Substring(8))" -Level "ERR"
            } else {
                foreach ($l in $lines) { Write-Log $l -Level "INFO" }
                Write-Log "Özellik detayı OUTPUT LOG'a yazıldı." -Level "OK"
            }
        } catch {
            Write-Log "Detay hatası: $($_.Exception.Message)" -Level "ERR"
        } finally {
            $global:IsBusy = $false
            $BusyOverlayMenu.Visibility = [System.Windows.Visibility]::Collapsed
            $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Collapsed
            Set-Progress -Percent 0 -Message "Sistem Hazır."
        }
    })
    $script:FeatureInfoTimer.Start()
})

# ── Seçim değişimi → istatistik güncelle ─────────────────────────────────────
$script:FeatureSelectTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:FeatureSelectTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:FeatureSelectTimer.Add_Tick({
    if ($global:FeatureItems.Count -eq 0) { return }
    Update-FeatureStats
})
$script:FeatureSelectTimer.Start()

# ═══════════════════════════════════════════════════════
# PG_4 : EDITION MANAGEMENT
# ═══════════════════════════════════════════════════════
$BtnSetProductKey.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    if ($TxtProductKey.Text -eq "") { Show-Alert -Title "Eksik Alan" -Message "Ürün anahtarını girin."; return }
    $eArgs = "/Image:`"$global:StrMountedImageLocation`" /Set-ProductKey:$($TxtProductKey.Text)"
    Write-Log "DISM $eArgs" -Level "RUN"
    Start-DismJob -DismArgs $eArgs -StatusMessage "Ürün anahtarı atanıyor..."
})

$BtnSetEdition.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    if ($TxtEdition.Text -eq "") { Show-Alert -Title "Eksik Alan" -Message "Hedef sürüm adını girin."; return }
    $eArgs = "/Image:`"$global:StrMountedImageLocation`" /Set-Edition:$($TxtEdition.Text)"
    Write-Log "DISM $eArgs" -Level "RUN"
    Start-DismJob -DismArgs $eArgs -StatusMessage "Sürüm yükseltiliyor..."
})

$BtnShowCurrentEdition.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    $eArgs = "/Image:`"$global:StrMountedImageLocation`" /Get-CurrentEdition"
    Write-Log "DISM $eArgs" -Level "RUN"
    Start-DismJob -DismArgs $eArgs -StatusMessage "Sürüm/Edition"
})

$BtnShowTargetEdition.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    $eArgs = "/Image:`"$global:StrMountedImageLocation`" /Get-TargetEditions"
    Write-Log "DISM $eArgs" -Level "RUN"
    Start-DismJob -DismArgs $eArgs -StatusMessage "Sürüm/Edition"
})

# ═══════════════════════════════════════════════════════
# PG_5 : AUTOMATED SETUP
# ═══════════════════════════════════════════════════════
$TxtUnattendXml      = $window.FindName("TxtUnattendXml")
$BtnChooseUnattendXml= $window.FindName("BtnChooseUnattendXml")
$BtnApplyUnattendXml = $window.FindName("BtnApplyUnattendXml")

$BtnChooseUnattendXml.Add_Click({
    $f = Select-File -Filter "XML Dosyaları (*.xml)|*.xml|Tüm Dosyalar (*.*)|*.*" -Title "Unattend XML Seçin"
    if ($f -ne "") { $TxtUnattendXml.Text = $f }
})

$BtnApplyUnattendXml.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    if ($TxtUnattendXml.Text -eq "") { Show-Alert -Title "Eksik Alan" -Message "Lütfen bir Unattend.xml dosyası seçin."; return }
    $uArgs = "/Image:`"$global:StrMountedImageLocation`" /Apply-Unattend:`"$($TxtUnattendXml.Text)`""
    Write-Log "DISM $uArgs" -Level "RUN"
    Start-DismJob -DismArgs $uArgs -StatusMessage "Unattend.xml uygulanıyor..."
})

# ═══════════════════════════════════════════════════════
# PG_6 : CAPTURE OS IMAGE
# ═══════════════════════════════════════════════════════
$TxtCaptureSource       = $window.FindName("TxtCaptureSource")
$TxtCaptureDestDir      = $window.FindName("TxtCaptureDestDir")
$TxtCaptureFileName     = $window.FindName("TxtCaptureFileName")
$TxtCaptureWimName      = $window.FindName("TxtCaptureWimName")
$TxtCaptureDesc         = $window.FindName("TxtCaptureDesc")
$CmbCaptureCompression  = $window.FindName("CmbCaptureCompression")
$ChkCaptureVerify       = $window.FindName("ChkCaptureVerify")
$BtnCaptureBrowseSource = $window.FindName("BtnCaptureBrowseSource")
$BtnCaptureBrowseDest   = $window.FindName("BtnCaptureBrowseDest")
$BtnCaptureCreate       = $window.FindName("BtnCaptureCreate")
$BtnCaptureAppend       = $window.FindName("BtnCaptureAppend")
$BtnCaptureClear        = $window.FindName("BtnCaptureClear")
$BtnGenerateFileName    = $window.FindName("BtnGenerateFileName")
$PnlCaptureOptions      = $window.FindName("PnlCaptureOptions")

# Capture sayfasi adim adim aktiflesme mantigi
# Adim 1: Kaynak sec  -> Adim 2 + Imaj Adi/Aciklama aktif (analiz doldurur)
# Adim 2: Hedef sec   -> Adim 3 (Dosya Adi + Generate) aktif
# Adim 3: Dosya dolu  -> Sikistirma + Butonlar aktif
# Ortak kisa WIM dosya adi uretici
# Imaj Adi + Aciklama + Kaynak harf -> Win11_LTSC_24H2_C_20260328.wim
function New-CaptureName {
    $raw  = $TxtCaptureWimName.Text.Trim()
    $desc = $TxtCaptureDesc.Text.Trim()
    $src  = $TxtCaptureSource.Text.Trim()
    if ($raw -eq '') { $raw = 'Windows_Backup' }

    # OS nesli: sadece WinXX / WinPE / WinSrv al, geri kalanini tamamen at
    $short = $raw
    $short = $short -replace 'Microsoft\s+', ''
    $short = $short -replace 'Windows\s+Server.*',   'WinSrv'
    $short = $short -replace 'Windows\s+PE.*',        'WinPE'
    $short = $short -replace 'Windows\s+(\d+).*',    'Win$1'
    $short = $short -replace 'Windows.*',             'Win'
    # Sadece ilk token, alfanumerik
    $short = (($short -split '\s+')[0]) -replace '[^A-Za-z0-9]', ''

    # Edition: Aciklama alanindaki EditionID'den
    $edShort = switch -Regex ($desc) {
        'IoTEnterpriseS'   { 'LTSC'; break }
        'Enterprise'       { 'Ent';  break }
        'Professional'     { 'Pro';  break }
        'Education'        { 'Edu';  break }
        'Home'             { 'Home'; break }
        'ServerDatacenter' { 'DC';   break }
        'ServerStandard'   { 'Std';  break }
        default            { '' }
    }

    # Versiyon: sadece Aciklama'dan al (raw'da da varsa ciftlenmesin diye)
    $ver = ''
    if ($desc -match '(\d{2}H\d)') { $ver = $Matches[1] }
    elseif ($raw -match '(\d{2}H\d)') { $ver = $Matches[1] }

    # Kaynak suruc harfi
    $srcLetter = ''
    if ($src -match '^([A-Za-z]):') { $srcLetter = $Matches[1].ToUpper() }

    $date  = (Get-Date).ToString('yyyyMMdd')
    $parts = @($short, $edShort, $ver, $srcLetter, $date) | Where-Object { $_ -ne '' }
    return ($parts -join '_') + '.wim'
}

function Update-CaptureForm {
    # Kontroller henüz bağlanmamışsa çık
    if ($null -eq $BtnCaptureBrowseSource) { return }
    # Islem devam ediyorsa tum formu kilitle
    if ($global:IsBusy) {
        $BtnCaptureBrowseSource.IsEnabled = $false
        $TxtCaptureDestDir.IsEnabled      = $false
        $BtnCaptureBrowseDest.IsEnabled   = $false
        $TxtCaptureFileName.IsEnabled     = $false
        $BtnGenerateFileName.IsEnabled    = $false
        $TxtCaptureWimName.IsEnabled      = $false
        $TxtCaptureDesc.IsEnabled         = $false
        $PnlCaptureOptions.IsEnabled      = $false
        $BtnCaptureCreate.IsEnabled       = $false
        $BtnCaptureAppend.IsEnabled       = $false
        return
    }

    $srcOk  = ($TxtCaptureSource.Text.Trim()   -ne '')
    $dstOk  = ($TxtCaptureDestDir.Text.Trim()  -ne '')
    $fileOk = ($TxtCaptureFileName.Text.Trim() -ne '')
    $nameOk = ($TxtCaptureWimName.Text.Trim()  -ne '' -and $TxtCaptureDesc.Text.Trim() -ne '')

    $BtnCaptureBrowseSource.IsEnabled = $true

    # Adim 2: Hedef dizin
    $TxtCaptureDestDir.IsEnabled    = $srcOk
    $BtnCaptureBrowseDest.IsEnabled = $srcOk

    # Imaj Adi + Aciklama
    $TxtCaptureWimName.IsEnabled = $srcOk
    $TxtCaptureDesc.IsEnabled    = $srcOk

    # Adim 3: Dosya adi + Generate
    $TxtCaptureFileName.IsEnabled  = $srcOk -and $dstOk
    $BtnGenerateFileName.IsEnabled = $srcOk -and $dstOk

    # Adim 4: Sikistirma + Butonlar
    $allOk = $srcOk -and $dstOk -and $fileOk -and $nameOk
    $PnlCaptureOptions.IsEnabled  = $allOk
    $BtnCaptureCreate.IsEnabled   = $allOk
    $BtnCaptureAppend.IsEnabled   = $allOk
}

$BtnCaptureBrowseSource.Add_Click({
    # Sadece kok suruculer listelenir (C:\, D:\ vs.)
    $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }

    # XAML tabanli dialog - tum elemanlar garantili gorunur
    [xml]$dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Kaynak Surucuyu Secin" Width="460" Height="340"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize" Background="White">
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Capture yapilacak kok surucu:" FontSize="11" Margin="0,0,0,8"/>
        <ListBox x:Name="DriveLB" Grid.Row="1" FontFamily="Consolas" FontSize="11"
                 BorderBrush="#D1D5DB" BorderThickness="1" Margin="0,0,0,8"/>
        <TextBlock Grid.Row="2" FontSize="10" Foreground="#6B7280" TextWrapping="Wrap" Margin="0,0,0,12"
                   Text="Not: Yalnizca kok dizin (C:\, D:\) capture edilebilir."/>
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnDlgOk" Content="Sec" Width="88" Height="28" Margin="0,0,8,0"
                    Background="#4A6278" Foreground="White" FontWeight="SemiBold">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border CornerRadius="4" Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Button.Template>
            </Button>
            <Button x:Name="BtnDlgCnl" Content="Iptal" Width="88" Height="28">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border CornerRadius="4" BorderBrush="#D1D5DB" BorderThickness="1" Background="White">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Button.Template>
            </Button>
        </StackPanel>
    </Grid>
</Window>
"@
    $dlgReader = New-Object System.Xml.XmlNodeReader $dlgXaml
    $dlg       = [Windows.Markup.XamlReader]::Load($dlgReader)
    $dlg.Owner = $window
    $lb        = $dlg.FindName('DriveLB')
    $dlg.FindName('BtnDlgOk').Add_Click({  $dlg.DialogResult = $true;  $dlg.Close() })
    $dlg.FindName('BtnDlgCnl').Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })

    $driveObjects = @()
    foreach ($d in $drives) {
        $letter = $d.Name.TrimEnd('\\')
        $label  = if ($d.VolumeLabel -ne '') { $d.VolumeLabel } else { 'Etiketsiz' }
        $type   = switch ($d.DriveType) {
            'Fixed'    { 'Sabit Disk' }
            'Removable'{ 'Cikartilabilir' }
            'Network'  { 'Ag Surucusu' }
            'CDRom'    { 'Optik' }
            default    { "$($d.DriveType)" }
        }
        $sizGB  = [math]::Round($d.TotalSize / 1GB, 1)
        $freeGB = [math]::Round($d.AvailableFreeSpace / 1GB, 1)
        $lb.Items.Add("$letter   $(($label).PadRight(16)) [$type]   $sizGB GB  ($freeGB GB bos)") | Out-Null
        $driveObjects += $d
    }
    $lb.SelectedIndex = 0

    if ($dlg.ShowDialog() -ne $true -or $lb.SelectedIndex -lt 0) { return }
    $selectedDrive = $driveObjects[$lb.SelectedIndex]
    $f = $selectedDrive.Name.TrimEnd('\\')
    $TxtCaptureSource.Text = $f
    Update-CaptureForm

    # Kaynak dizini analiz et, imaj adi ve aciklamayi otomatik doldur
    # Kullanici daha sonra duzenleyebilir
    Write-Log "Kaynak sistem analiz ediliyor: $f" -Level "INFO"
    $srcPath = $f.TrimEnd('\\')

    $script:AnalysisJob = Start-Job -ScriptBlock {
        param($p)
        $result = @{ Name = ''; Desc = '' }
        try {
            # 1. SOFTWARE hive'dan ProductName, DisplayVersion, EditionID oku
            $hive  = Join-Path $p 'Windows\System32\config\SOFTWARE'
            $productName = ''
            $edition     = ''
            $build       = ''
            $ubr         = ''
            $arch        = ''
            if (Test-Path $hive) {
                reg load 'HKLM\_CAPTURE_SW' $hive 2>$null | Out-Null
                Start-Sleep -Milliseconds 300
                $productName = (Get-ItemProperty 'HKLM:\_CAPTURE_SW\Microsoft\Windows NT\CurrentVersion' -Name 'ProductName'    -ErrorAction SilentlyContinue).ProductName
                $edition     = (Get-ItemProperty 'HKLM:\_CAPTURE_SW\Microsoft\Windows NT\CurrentVersion' -Name 'EditionID'      -ErrorAction SilentlyContinue).EditionID
                $build       = (Get-ItemProperty 'HKLM:\_CAPTURE_SW\Microsoft\Windows NT\CurrentVersion' -Name 'CurrentBuild'   -ErrorAction SilentlyContinue).CurrentBuild
                $ubr         = (Get-ItemProperty 'HKLM:\_CAPTURE_SW\Microsoft\Windows NT\CurrentVersion' -Name 'UBR'           -ErrorAction SilentlyContinue).UBR
                $displayVer  = (Get-ItemProperty 'HKLM:\_CAPTURE_SW\Microsoft\Windows NT\CurrentVersion' -Name 'DisplayVersion' -ErrorAction SilentlyContinue).DisplayVersion
                reg unload 'HKLM\_CAPTURE_SW' 2>$null | Out-Null
            }

            # 2. Mimari: System32 varsa x64, SysWOW64 yoksa x86 say
            if (Test-Path (Join-Path $p 'Windows\SysWOW64')) { $arch = 'x64' }
            elseif (Test-Path (Join-Path $p 'Windows\System32')) { $arch = 'x86' }

            # 3. DisplayVersion düzeltmesi - Windows 10 vs 11
            # Windows 10'da 24H2 gibi sürümler yok - build numarasından belirle
            if ($productName -match 'Windows 10') {
                # Windows 10: DisplayVersion genelde yok veya yanlış
                # Build bazlı mapping (standard Windows 10 builds only)
                $displayVer = switch ([int]$build) {
                    { $_ -ge 26000 } { ''; break }  # 26000+ builds are Windows 11 - don't map for Win10
                    { $_ -ge 19045 } { '22H2'; break }
                    { $_ -ge 19044 } { '21H2'; break }
                    { $_ -ge 19043 } { '21H1'; break }
                    { $_ -ge 19042 } { '20H2'; break }
                    { $_ -ge 19041 } { '2004'; break }
                    default { '' }
                }
            }
            # Windows 11: DisplayVersion registry'den zaten doğru gelir
            # Eğer boşsa build'den çıkar
            elseif ($productName -match 'Windows 11') {
                if (-not $displayVer) {
                    $displayVer = switch ([int]$build) {
                        { $_ -ge 26100 } { '24H2'; break }
                        { $_ -ge 22631 } { '23H2'; break }
                        { $_ -ge 22621 } { '22H2'; break }
                        { $_ -ge 22000 } { '21H2'; break }
                        default { '' }
                    }
                }
            }

            # 4. Temiz isim olustur
            $name = if ($productName) { $productName } else { 'Windows Backup' }
            if ($displayVer) { $name = "$name $displayVer" }

            $descParts = @()
            if ($edition) { $descParts += $edition }
            if ($build)   {
                $buildStr = "Build $build"
                if ($ubr)  { $buildStr += ".$ubr" }
                $descParts += $buildStr
            }
            if ($arch) { $descParts += $arch }
            $descParts += (Get-Date).ToString('yyyy-MM-dd')
            $desc = $descParts -join ' | '

            $result.Name = $name
            $result.Desc = $desc
        } catch {
            $result.Name = 'Windows Backup'
            $result.Desc = (Get-Date).ToString('yyyy-MM-dd')
        }
        return $result
    } -ArgumentList $srcPath

    $script:AnalysisTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:AnalysisTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:AnalysisTimer.Add_Tick({
        $job = $script:AnalysisJob
        if ($job.State -notin @('Completed','Failed','Stopped')) { return }
        $script:AnalysisTimer.Stop()
        try {
            $r = Receive-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            if ($r -and $r.Name -ne '') {
                $TxtCaptureWimName.Text = $r.Name
                $TxtCaptureDesc.Text    = $r.Desc
                Write-Log "Sistem bilgisi alindi: $($r.Name) | $($r.Desc)" -Level "OK"
                # Hedef dizin zaten seciliyse dosya adini da otomatik uret
                if ($TxtCaptureDestDir.Text.Trim() -ne '') {
                    $base  = $r.Name -replace '[\\/:*?"<>|]','' -replace '\s+','_' -replace '_+','_'
                    $base  = $base.Trim('_')
                    $base  = [System.IO.Path]::GetFileNameWithoutExtension($base)
                    $stamp = (Get-Date).ToString('yyyyMMdd_HHmm')
                    $TxtCaptureFileName.Text = "${base}_${stamp}.wim"
                }
                Update-CaptureForm
            } else {
                Write-Log "Sistem bilgisi alinamadi - secilen surucude Windows yuklu degil. Imaj adi ve aciklamayi manuel girin." -Level "WARN"
                # Alanları boşalt
                $TxtCaptureWimName.Text = ""
                $TxtCaptureDesc.Text = ""
                Update-CaptureForm
            }
        } catch {
            Write-Log "Analiz hatasi: $($_.Exception.Message)" -Level "ERR"
        }
    })
    $script:AnalysisTimer.Start()
})
$BtnCaptureBrowseDest.Add_Click({
    $f = Select-Folder
    if ($f -eq '') { return }
    # Kaynak ile ayni surucude olmamali
    $srcRoot = [System.IO.Path]::GetPathRoot($TxtCaptureSource.Text).TrimEnd('\\')
    $dstRoot = [System.IO.Path]::GetPathRoot($f).TrimEnd('\\')
    if ($srcRoot -ne '' -and $dstRoot -ieq $srcRoot) {
        Show-Alert -Title 'Gecersiz Hedef' -Message "Hedef dizin, kaynak surucu ($srcRoot) ile ayni olamaz.`nLutfen farkli bir surucuyu secin."
        return
    }
    $TxtCaptureDestDir.Text = $f
    # Dosya adi bossa otomatik uret
    if ($TxtCaptureFileName.Text.Trim() -eq '') {
        $TxtCaptureFileName.Text = New-CaptureName
    }
    Update-CaptureForm
})

$TxtCaptureFileName.Add_TextChanged({ Update-CaptureForm })
$TxtCaptureWimName.Add_TextChanged({ Update-CaptureForm })
$TxtCaptureDesc.Add_TextChanged({ Update-CaptureForm })

$BtnGenerateFileName.Add_Click({
    $raw  = $TxtCaptureWimName.Text.Trim()
    $desc = $TxtCaptureDesc.Text.Trim()
    $src  = $TxtCaptureSource.Text.Trim()
    if ($raw -eq '') { $raw = 'Windows_Backup' }

    # Ortak parcalar
    $short = $raw
    $short = $short -replace 'Microsoft\s+', ''
    $short = $short -replace 'Windows\s+Server.*',  'WinSrv'
    $short = $short -replace 'Windows\s+PE.*',       'WinPE'
    $short = $short -replace 'Windows\s+(\d+).*',   'Win$1'
    $short = $short -replace 'Windows.*',            'Win'
    $short = (($short -split '\s+')[0]) -replace '[^A-Za-z0-9]', ''

    $edShort = switch -Regex ($desc) {
        'IoTEnterpriseS'   { 'LTSC'; break }
        'Enterprise'       { 'Ent';  break }
        'Professional'     { 'Pro';  break }
        'Education'        { 'Edu';  break }
        'Home'             { 'Home'; break }
        'ServerDatacenter' { 'DC';   break }
        'ServerStandard'   { 'Std';  break }
        default            { '' }
    }

    $ver = ''
    if ($desc -match '(\d{2}H\d)') { $ver = $Matches[1] }
    elseif ($raw -match '(\d{2}H\d)') { $ver = $Matches[1] }

    $build = ''
    if ($desc -match 'Build\s+(\d+\.?\d*)') { $build = "b$($Matches[1])" }

    $srcLetter = ''
    if ($src -match '^([A-Za-z]):') { $srcLetter = $Matches[1].ToUpper() }

    $date  = (Get-Date).ToString('yyyyMMdd')
    $dateL = (Get-Date).ToString('yyyy-MM-dd')
    $time  = (Get-Date).ToString('HHmm')

    # 5 format önerisi
    $suggestions = @(
        ((@($short,$edShort,$ver,$srcLetter,$date)              | Where-Object {$_ -ne ''}) -join '_'),
        ((@($short,$edShort,$ver)                               | Where-Object {$_ -ne ''}) -join '_'),
        ((@($short,$edShort,$build,$srcLetter,$date)            | Where-Object {$_ -ne ''}) -join '_'),
        "Backup_${srcLetter}_${date}",
        ((@($short,$edShort,$ver,$srcLetter,"${dateL}_${time}") | Where-Object {$_ -ne ''}) -join '_')
    )
    $suggestions = $suggestions | ForEach-Object { ($_ -replace '_+','_').Trim('_') + '.wim' }

    [xml]$dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Dosya Adi Secin" Width="480" Height="295"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="White">
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Format secin veya alttaki alandan duzenleyin:"
                   FontSize="11" Margin="0,0,0,8"/>
        <ListBox x:Name="SuggestLB" Grid.Row="1" FontFamily="Consolas" FontSize="11"
                 BorderBrush="#D1D5DB" BorderThickness="1" Margin="0,0,0,8"/>
        <TextBox x:Name="CustomName" Grid.Row="2" FontFamily="Consolas" FontSize="11"
                 Height="26" Padding="6,0" Margin="0,0,0,10"
                 BorderBrush="#D1D5DB" BorderThickness="1" VerticalContentAlignment="Center"/>
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnPickOk"  Content="Kullan" Width="88" Height="28" Margin="0,0,8,0"
                    Background="#4A6278" Foreground="White" FontWeight="SemiBold">
                <Button.Template><ControlTemplate TargetType="Button">
                    <Border CornerRadius="4" Background="{TemplateBinding Background}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                </ControlTemplate></Button.Template>
            </Button>
            <Button x:Name="BtnPickCnl" Content="Iptal" Width="88" Height="28">
                <Button.Template><ControlTemplate TargetType="Button">
                    <Border CornerRadius="4" BorderBrush="#D1D5DB" BorderThickness="1" Background="White">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                </ControlTemplate></Button.Template>
            </Button>
        </StackPanel>
    </Grid>
</Window>
"@
    $dlgReader = New-Object System.Xml.XmlNodeReader $dlgXaml
    $dlg       = [Windows.Markup.XamlReader]::Load($dlgReader)
    $dlg.Owner = $window
    $lb        = $dlg.FindName('SuggestLB')
    $customBox = $dlg.FindName('CustomName')

    foreach ($item in $suggestions) { $lb.Items.Add($item) | Out-Null }
    $lb.SelectedIndex = 0
    $customBox.Text   = $suggestions[0]

    $lb.Add_SelectionChanged({
        if ($lb.SelectedIndex -ge 0) { $customBox.Text = $suggestions[$lb.SelectedIndex] }
    })

    $dlg.FindName('BtnPickOk').Add_Click({  $dlg.DialogResult = $true;  $dlg.Close() })
    $dlg.FindName('BtnPickCnl').Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })

    if ($dlg.ShowDialog() -ne $true) { return }

    $chosen = $customBox.Text.Trim()
    if ($chosen -eq '') { return }
    $validExts = @('.wim','.esd','.swm')
    if ($validExts -notcontains [System.IO.Path]::GetExtension($chosen).ToLower()) { $chosen += '.wim' }
    $TxtCaptureFileName.Text = $chosen
    Update-CaptureForm
})




function Invoke-Capture {
    param([bool]$Append)
    if ($TxtCaptureSource.Text -eq "")   { Show-Alert -Title "Eksik Alan" -Message "Kaynak dizini seçin."; return }
    if ($TxtCaptureDestDir.Text -eq "")  { Show-Alert -Title "Eksik Alan" -Message "Hedef dizini seçin."; return }
    if ($TxtCaptureFileName.Text -eq "") { Show-Alert -Title "Eksik Alan" -Message "Dosya adını girin."; return }
    if ($TxtCaptureWimName.Text -eq "")  { Show-Alert -Title "Eksik Alan" -Message "Imaj adini girin."; return }
    if ($TxtCaptureDesc.Text -eq "")     { Show-Alert -Title "Eksik Alan" -Message "Aciklama girin."; return }

    $fname = $TxtCaptureFileName.Text.Trim()
    # Tum uzantilari soy, son gecerli uzantiyi koru (wim/esd/swm), yoksa .wim ekle
    $validExts  = @('.wim', '.esd', '.swm')
    $fnameClean = $fname
    # Birden fazla uzanti olabilir (xx.wim.wim) - hepsini soy
    while ($validExts -contains [System.IO.Path]::GetExtension($fnameClean).ToLower()) {
        $fnameClean = [System.IO.Path]::GetFileNameWithoutExtension($fnameClean)
    }
    # Son uzanti gecerli mi? Yoksa .wim ekle
    $lastExt = [System.IO.Path]::GetExtension($fname).ToLower()
    $finalExt = if ($validExts -contains $lastExt) { $lastExt } else { '.wim' }
    $fnameClean = $fnameClean.TrimEnd('.')
    if ($fnameClean -eq '') { $fnameClean = 'capture' }
    $fname     = $fnameClean + $finalExt
    $destFile  = Join-Path $TxtCaptureDestDir.Text $fname
    $compress  = ($CmbCaptureCompression.SelectedItem).Content
    $capSrc    = $TxtCaptureSource.Text.TrimEnd('\')
    $capName   = $TxtCaptureWimName.Text
    $capDesc   = $TxtCaptureDesc.Text.Replace('"', "'")
    $capVerify = $ChkCaptureVerify.IsChecked
    $capAppend = $Append

    $sysDrive  = $env:SystemDrive
    $capRoot   = [System.IO.Path]::GetPathRoot($capSrc).TrimEnd('\')
    $isOnline  = ($capRoot -ieq $sysDrive)

    if ($isOnline) {
        # Online mod: VSS snapshot al, shadow path'i DISM'e ver
        # Referans: imagecapture.bat - Win32_ShadowCopy.Create() + mklink /d mantigi
        Write-Log "Online mod algilandi - VSS snapshot olusturuluyor..." -Level "INFO"
        if (-not (Assert-NotBusy)) { return }
        $global:IsBusy          = $true
        $global:CancelRequested = $false
        $BtnCancelJob.Visibility = [System.Windows.Visibility]::Visible
        $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Visible
        $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Visible
        Update-CaptureForm
        Set-Progress -Percent 5 -Message "VSS snapshot olusturuluyor..."

        $destFileCopy  = $destFile
        $capSrcCopy    = $capSrc + "\"
        $capNameCopy   = $capName
        $capDescCopy   = $capDesc
        $compressCopy  = $compress
        $capVerifyCopy = $capVerify
        $capAppendCopy = $capAppend

        $script:VssJob = Start-Job -ScriptBlock {
            param($capSrc, $destFile, $capName, $capDesc, $compress, $capVerify, $capAppend)

            # 1. VSS snapshot olustur (imagecapture.bat referans: Win32_ShadowCopy.Create)
            $shadowPath = $null
            $mountDir   = $null
            try {
                $vol    = $capSrc.TrimEnd('\') + "\"
                $result = (Get-WmiObject -List Win32_ShadowCopy).Create($vol, "ClientAccessible")
                if ($result.ReturnValue -eq 0) {
                    $shadow     = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $result.ShadowID }
                    $shadowPath = $shadow.DeviceObject
                    Write-Output "[VSS] Snapshot olusturuldu: $shadowPath"
                } else {
                    Write-Output "[VSS_FAIL] ReturnValue=$($result.ReturnValue)"
                }
            } catch {
                Write-Output "[VSS_FAIL] $($_.Exception.Message)"
            }

            if ($null -ne $shadowPath) {
                # 2. mklink /d ile gecici klasore bagla (imagecapture.bat referans)
                $mountDir = Join-Path $env:TEMP ("vss_mount_" + [System.Diagnostics.Process]::GetCurrentProcess().Id)
                if (Test-Path $mountDir) { Remove-Item $mountDir -Force -Recurse -ErrorAction SilentlyContinue }
                $mk = cmd /c "mklink /d `"$mountDir`" `"$shadowPath\`"" 2>&1
                Write-Output "[VSS] Mount: $mk"

                if (Test-Path $mountDir) {
                    Write-Output "[VSS] Baglandi: $mountDir"
                    $captureDir = $mountDir
                } else {
                    Write-Output "[VSS_MOUNTFAIL] mklink basarisiz, dogrudan capture deneniyor..."
                    $captureDir = $capSrc.TrimEnd('\') + "\"
                }
            } else {
                # VSS basarisiz - dogrudan dene (Error 32 riski var)
                Write-Output "[VSS] Snapshot alinamadi. Dogrudan capture deneniyor..."
                $captureDir = $capSrc.TrimEnd('\') + "\"
            }

            # 3. DISM calistir
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName               = "DISM.EXE"
            if ($capAppend) {
                $psi.Arguments = "/Append-Image /ImageFile:`"$destFile`" /CaptureDir:`"$captureDir`" /Name:`"$capName`" /Description:`"$capDesc`""
            } else {
                $psi.Arguments = "/Capture-Image /ImageFile:`"$destFile`" /CaptureDir:`"$captureDir`" /Name:`"$capName`" /Description:`"$capDesc`" /Compress:$compress"
            }
            if ($capVerify) { $psi.Arguments += " /Verify" }
            $psi.UseShellExecute        = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow         = $true
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            Write-Output "[DISM_CMD] DISM.EXE $($psi.Arguments)"
            $proc.Start() | Out-Null
            Write-Output "__PID__:$($proc.Id)"  # UI thread'e PID bildir
            while (-not $proc.StandardOutput.EndOfStream) {
                $line = $proc.StandardOutput.ReadLine()
                if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Output $line.Trim() }
            }
            $errTxt = $proc.StandardError.ReadToEnd()
            if (-not [string]::IsNullOrWhiteSpace($errTxt)) {
                foreach ($el in ($errTxt -split "`n")) {
                    if (-not [string]::IsNullOrWhiteSpace($el)) { Write-Output "  $($el.Trim())" }
                }
            }
            $proc.WaitForExit()
            $ec = $proc.ExitCode

            # 4. Temizlik: mklink ve VSS snapshot sil (imagecapture.bat referans)
            if ($null -ne $mountDir -and (Test-Path $mountDir)) {
                cmd /c "rmdir `"$mountDir`"" 2>&1 | Out-Null
                Write-Output "[VSS] Mount kaldirildi."
            }
            if ($null -ne $shadowPath) {
                try {
                    $shadow = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.DeviceObject -eq $shadowPath }
                    if ($shadow) { $shadow.Delete(); Write-Output "[VSS] Snapshot silindi." }
                } catch { Write-Output "[VSS] Snapshot silinemedi: $($_.Exception.Message)" }
            }

            Write-Output "__EXIT__:$ec"
        } -ArgumentList $capSrcCopy, $destFileCopy, $capNameCopy, $capDescCopy, $compressCopy, $capVerifyCopy, $capAppendCopy

        $script:VssTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:VssTimer.Interval = [TimeSpan]::FromMilliseconds(100)
        $script:PendingDestFile = $destFile

        $script:VssTimer.Add_Tick({
            $lines = $script:VssJob | Receive-Job
            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }

                if ($line.StartsWith("__PID__:")) {
                    $script:VssDismPid = [int]($line.Substring(8))
                    continue
                }
                if ($line.StartsWith("[DISM_CMD]")) {
                    Write-Log $line.Substring(10).Trim() -Level "RUN"
                    continue
                }
                if ($line.StartsWith("[VSS]") -or $line.StartsWith("[VSS_")) {
                    Write-Log $line -Level "INFO"
                    $global:_Console.AppendText("`r`n  $line")
                    $global:_Console.ScrollToEnd()
                    continue
                }

                if ($line.StartsWith("__EXIT__:")) {
                    $script:VssTimer.Stop()
                    $ec = [int]($line.Substring(9))
                    Remove-Job -Job $script:VssJob -Force -ErrorAction SilentlyContinue
                    $BtnCancelJob.Visibility = [System.Windows.Visibility]::Collapsed
                    $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Collapsed
                    $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Collapsed
                    if ($global:CancelRequested) {
                        Write-Log "Islem kullanici tarafindan iptal edildi." -Level "ERR"
                        Set-Progress -Percent 0 -Message "Iptal edildi."
                    } elseif ($ec -eq 0) {
                        Write-Log "Tamamlandi. (Cikis: $ec)" -Level "OK"
                        Set-Progress -Percent 100 -Message "Tamamlandi."
                    } else {
                        Write-Log "Hata. (Cikis: $ec)" -Level "ERR"
                        Set-Progress -Percent 0 -Message "Hata (kod: $ec)"
                    }
                    Start-Sleep -Milliseconds 400
                    Set-Progress -Percent 0 -Message "Sistem Hazir."
                    $global:IsBusy          = $false
                    $global:CancelRequested = $false
                    Update-CaptureForm
                    if ($ec -eq 0 -and -not $global:CancelRequested) { Show-Alert -Title "Tamamlandi" -Message "Imaj yakalama tamamlandi:`n$($script:PendingDestFile)" }
                    return
                }

                $pct = -1
                if ($line -match "(\d+(?:\.\d+)?)\s*%") {
                    $pct = [int][Math]::Floor([double]$Matches[1])
                }
                $global:_Console.AppendText("`r`n  $line")
                $global:_Console.ScrollToEnd()
                if ($pct -ge 0 -and $pct -le 100) {
                    $global:_PBar.Value  = $pct
                    $global:_PctLbl.Text = "$pct%"
                    $global:_MsgLbl.Text = "Imaj yakalaniyor $pct%"
                }
            }
        })
        $script:VssTimer.Start()

    } else {
        # Offline mod (WinPE veya baska surucü): normal DISM
        if ($capAppend) {
            $capArgs = "/Append-Image /ImageFile:`"$destFile`" /CaptureDir:`"$capSrc`" /Name:`"$capName`" /Description:`"$capDesc`""
        } else {
            $src = if ($capSrc.Length -ne 3) { "`"$capSrc`"" } else { $capSrc }
            $capArgs = "/Capture-Image /ImageFile:`"$destFile`" /CaptureDir:$src /Name:`"$capName`" /Description:`"$capDesc`" /Compress:$compress"
        }
        if ($capVerify) { $capArgs += " /Verify" }
        Write-Log "DISM $capArgs" -Level "RUN"
        $script:PendingDestFile = $destFile
        Start-DismJob -DismArgs $capArgs -StatusMessage "Imaj yakalaniyor" -OnComplete {
            param($ec)
            if ($ec -eq 0) { Show-Alert -Title "Tamamlandi" -Message "Imaj yakalama tamamlandi:`n$($script:PendingDestFile)" }
        }
    }
}


$BtnCaptureCreate.Add_Click({ Invoke-Capture -Append $false })
$BtnCaptureAppend.Add_Click({
    # Hedef dizindeki WIM/ESD dosyalarini tara, kullaniciya sec
    $destDir = $TxtCaptureDestDir.Text.Trim()

    if ($destDir -eq '' -or -not (Test-Path $destDir)) {
        # Hedef dizin yoksa dosya secici ac
        $picked = Select-File -Filter "Image Dosyalari (*.wim;*.esd)|*.wim;*.esd" -Title "Eklenecek WIM/ESD dosyasini secin"
        if ($picked -eq '') { return }
        $TxtCaptureDestDir.Text   = [System.IO.Path]::GetDirectoryName($picked)
        $TxtCaptureFileName.Text  = [System.IO.Path]::GetFileName($picked)
        Invoke-Capture -Append $true
        return
    }

    # Dizindeki tum wim/esd dosyalarini listele
    $imageFiles = @(Get-ChildItem -Path $destDir -Include '*.wim','*.esd' -File -ErrorAction SilentlyContinue)

    if ($imageFiles.Count -eq 0) {
        # Dizinde dosya yok - secici ac
        $picked = Select-File -Filter "Image Dosyalari (*.wim;*.esd)|*.wim;*.esd" -Title "Eklenecek WIM/ESD dosyasini secin"
        if ($picked -eq '') { return }
        $TxtCaptureDestDir.Text   = [System.IO.Path]::GetDirectoryName($picked)
        $TxtCaptureFileName.Text  = [System.IO.Path]::GetFileName($picked)
        Invoke-Capture -Append $true
        return
    }

    if ($imageFiles.Count -eq 1) {
        # Tek dosya varsa direkt sec
        $TxtCaptureFileName.Text = $imageFiles[0].Name
        Write-Log "Append hedefi otomatik secildi: $($imageFiles[0].Name)" -Level "INFO"
        Invoke-Capture -Append $true
        return
    }

    # Birden fazla dosya var - liste goster
    $listWindow = New-Object System.Windows.Window
    $listWindow.Title           = 'Hedef WIM Dosyasi Secin'
    $listWindow.Width           = 460
    $listWindow.Height          = 280
    $listWindow.WindowStartupLocation = 'CenterOwner'
    $listWindow.Owner           = $window
    $listWindow.ResizeMode      = 'NoResize'
    $listWindow.Background      = [System.Windows.Media.Brushes]::White

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '16'
    $r0 = New-Object System.Windows.Controls.RowDefinition; $r0.Height = 'Auto'
    $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = '*'
    $r2 = New-Object System.Windows.Controls.RowDefinition; $r2.Height = 'Auto'
    $grid.RowDefinitions.Add($r0)
    $grid.RowDefinitions.Add($r1)
    $grid.RowDefinitions.Add($r2)

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text       = "'$destDir' dizininde $($imageFiles.Count) imaj bulundu. Eklenecek dosyayi secin:"
    $lbl.FontSize   = 11
    $lbl.TextWrapping = 'Wrap'
    $lbl.Margin     = '0,0,0,10'
    [System.Windows.Controls.Grid]::SetRow($lbl, 0)
    $grid.Children.Add($lbl) | Out-Null

    $lb = New-Object System.Windows.Controls.ListBox
    $lb.FontSize    = 11
    $lb.BorderBrush = [System.Windows.Media.Brushes]::LightGray
    foreach ($f in $imageFiles) {
        $sizeMB = [math]::Round($f.Length / 1MB, 0)
        $lb.Items.Add("$($f.Name)  ($sizeMB MB)") | Out-Null
    }
    $lb.SelectedIndex = 0
    [System.Windows.Controls.Grid]::SetRow($lb, 1)
    $grid.Children.Add($lb) | Out-Null

    $btnPanel = New-Object System.Windows.Controls.StackPanel
    $btnPanel.Orientation = 'Horizontal'
    $btnPanel.HorizontalAlignment = 'Right'
    $btnPanel.Margin = '0,10,0,0'
    [System.Windows.Controls.Grid]::SetRow($btnPanel, 2)

    $btnOk = New-Object System.Windows.Controls.Button
    $btnOk.Content  = 'Sec'
    $btnOk.Width    = 80
    $btnOk.Height   = 26
    $btnOk.Margin   = '0,0,8,0'
    $btnOk.Background = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(0x4A,0x62,0x78)
    $btnOk.Foreground = [System.Windows.Media.Brushes]::White
    $btnOk.Add_Click({ $listWindow.DialogResult = $true; $listWindow.Close() })

    $btnCancel = New-Object System.Windows.Controls.Button
    $btnCancel.Content = 'Iptal'
    $btnCancel.Width   = 80
    $btnCancel.Height  = 26
    $btnCancel.Add_Click({ $listWindow.DialogResult = $false; $listWindow.Close() })

    $btnPanel.Children.Add($btnOk)     | Out-Null
    $btnPanel.Children.Add($btnCancel) | Out-Null
    $grid.Children.Add($btnPanel)      | Out-Null
    $listWindow.Content = $grid

    $result = $listWindow.ShowDialog()
    if ($result -ne $true -or $lb.SelectedIndex -lt 0) { return }

    $selectedFile = $imageFiles[$lb.SelectedIndex].Name
    $TxtCaptureFileName.Text = $selectedFile
    Write-Log "Append hedefi secildi: $selectedFile" -Level "INFO"
    Invoke-Capture -Append $true
})

# Formu Temizle butonu
$BtnCaptureClear.Add_Click({
    # Tüm alanları temizle
    $TxtCaptureSource.Text = ""
    $TxtCaptureDestDir.Text = ""
    $TxtCaptureFileName.Text = ""
    $TxtCaptureWimName.Text = ""
    $TxtCaptureDesc.Text = ""
    $CmbCaptureCompression.SelectedIndex = 0
    $ChkCaptureVerify.IsChecked = $false
    
    Write-Log "Capture formu temizlendi" -Level "INFO"
    Update-CaptureForm
})

# ═══════════════════════════════════════════════════════
# PG_7 : DEPLOY OS IMAGE
# ═══════════════════════════════════════════════════════
$TxtApplySource        = $window.FindName("TxtApplySource")
$ListViewApplyIndex    = $window.FindName("ListViewApplyIndex")
$TxtApplyDest          = $window.FindName("TxtApplyDest")
$TxtApplyDisk          = $window.FindName("TxtApplyDisk")
$ChkApplyVerify        = $window.FindName("ChkApplyVerify")
$ChkApplyCompact       = $window.FindName("ChkApplyCompact")
$BtnApplyBrowseSource  = $window.FindName("BtnApplyBrowseSource")
$BtnApplyBrowseDest    = $window.FindName("BtnApplyBrowseDest")
$BtnApplyDiskSelect    = $window.FindName("BtnApplyDiskSelect")
$BtnRefreshDisks       = $window.FindName("BtnRefreshDisks")
$BtnApplyImage         = $window.FindName("BtnApplyImage")
$RdoApplyToVolume      = $window.FindName("RdoApplyToVolume")
$RdoApplyToDisk        = $window.FindName("RdoApplyToDisk")
$RdoFirmwareUEFI       = $window.FindName("RdoFirmwareUEFI")
$RdoFirmwareBIOS       = $window.FindName("RdoFirmwareBIOS")
$PnlApplyVolume        = $window.FindName("PnlApplyVolume")
$PnlApplyDisk          = $window.FindName("PnlApplyDisk")
$LblDetectedFirmware   = $window.FindName("LblDetectedFirmware")
$ChkCreateRecovery     = $window.FindName("ChkCreateRecovery")
$TxtWindowsSize        = $window.FindName("TxtWindowsSize")
$ChkCreateDataDisk     = $window.FindName("ChkCreateDataDisk")
$TxtDataDiskLabel      = $window.FindName("TxtDataDiskLabel")
$ChkAddToBcd           = $window.FindName("ChkAddToBcd")
$LblBcdWarning         = $window.FindName("LblBcdWarning")
$RdoApplyToVhd         = $window.FindName("RdoApplyToVhd")
$PnlApplyVhd           = $window.FindName("PnlApplyVhd")
$TxtVhdPath            = $window.FindName("TxtVhdPath")
$TxtVhdSize            = $window.FindName("TxtVhdSize")
$BtnVhdBrowse          = $window.FindName("BtnVhdBrowse")
$RdoVhdFixed           = $window.FindName("RdoVhdFixed")
$RdoVhdDynamic         = $window.FindName("RdoVhdDynamic")
$ChkUseUnattend        = $window.FindName("ChkUseUnattend")
$PnlUnattend           = $window.FindName("PnlUnattend")
$TxtUnattendApply      = $window.FindName("TxtUnattendApply")
$BtnUnattendApplyBrowse= $window.FindName("BtnUnattendApplyBrowse")

# ListView için Data Class (Deploy için)
class IndexApplyItem {
    [int]    $IndexNumber
    [string] $IndexName
    [string] $Description
    [string] $SizeText
}
$global:ApplyIndexItems = New-Object System.Collections.ObjectModel.ObservableCollection[IndexApplyItem]
$ListViewApplyIndex.ItemsSource = $global:ApplyIndexItems
$LblDiskInfo              = $window.FindName("LblDiskInfo")
$LblPartitionPreview      = $window.FindName("LblPartitionPreview")
$PartitionVisualPreview   = $window.FindName("PartitionVisualPreview")
$PartitionBarContainer    = $window.FindName("PartitionBarContainer")
$PartitionLegend          = $window.FindName("PartitionLegend")
$LegendBorder             = $window.FindName("LegendBorder")



# Mod degisince panelleri goster/gizle
$RdoApplyToVolume.Add_Checked({
    $PnlApplyVolume.Visibility = [System.Windows.Visibility]::Visible
    $PnlApplyDisk.Visibility   = [System.Windows.Visibility]::Collapsed
    $PnlApplyVhd.Visibility    = [System.Windows.Visibility]::Collapsed
})
$RdoApplyToDisk.Add_Checked({
    $PnlApplyVolume.Visibility = [System.Windows.Visibility]::Collapsed
    $PnlApplyDisk.Visibility   = [System.Windows.Visibility]::Visible
    $PnlApplyVhd.Visibility    = [System.Windows.Visibility]::Collapsed
    $fw = Detect-Firmware
    $LblDetectedFirmware.Text = $fw
    if ($fw -eq 'UEFI') { $RdoFirmwareUEFI.IsChecked = $true } else { $RdoFirmwareBIOS.IsChecked = $true }
    Write-Log "Algilanan firmware: $fw" -Level "INFO"
})
$RdoApplyToVhd.Add_Checked({
    $PnlApplyVolume.Visibility = [System.Windows.Visibility]::Collapsed
    $PnlApplyDisk.Visibility   = [System.Windows.Visibility]::Collapsed
    $PnlApplyVhd.Visibility    = [System.Windows.Visibility]::Visible
})

# Unattend checkbox
$ChkUseUnattend.Add_Checked({
    $PnlUnattend.Visibility = [System.Windows.Visibility]::Visible
})
$ChkUseUnattend.Add_Unchecked({
    $PnlUnattend.Visibility = [System.Windows.Visibility]::Collapsed
})

# Unattend dosya seçici
$BtnUnattendApplyBrowse.Add_Click({
    $f = Select-File -Filter "XML Dosyaları (*.xml)|*.xml|Tüm Dosyalar (*.*)|*.*" -Title "Unattend.xml Seç"
    if ($f -ne "") { $TxtUnattendApply.Text = $f }
})

# VHD dosya seçici
$BtnVhdBrowse.Add_Click({
    $f = Select-SaveFile -Filter "VHD Dosyaları (*.vhd;*.vhdx)|*.vhd;*.vhdx" -Title "VHD/VHDX Dosyası"
    if ($f -ne "") { $TxtVhdPath.Text = $f }
})

# Bölümlendirme seçenekleri değişince önizleme güncelle
$ChkCreateRecovery.Add_Checked({ Update-PartitionPreview })
$ChkCreateRecovery.Add_Unchecked({ Update-PartitionPreview })

$ChkAddToBcd.Add_Checked({
    $LblBcdWarning.Visibility = [System.Windows.Visibility]::Visible
})
$ChkAddToBcd.Add_Unchecked({
    $LblBcdWarning.Visibility = [System.Windows.Visibility]::Collapsed
})

$script:TxtWindowsSizeHandler = { Update-PartitionPreview }
$TxtWindowsSize.Add_TextChanged($script:TxtWindowsSizeHandler)

$ChkCreateDataDisk.Add_Checked({
    # Windows boyutu boşsa (= tüm disk) Data bölümü anlamlı değil — kullanıcıyı bilgilendir
    $winTxt = $TxtWindowsSize.Text.Trim()
    $parsed = 0
    $validWin = (-not [string]::IsNullOrWhiteSpace($winTxt)) -and ([int]::TryParse($winTxt, [ref]$parsed)) -and ($parsed -gt 0)
    if (-not $validWin) {
        Show-Alert -Title "Bilgi" -Message "Data bölümü oluşturmak için önce 'Windows Boyutu' alanına GB cinsinden bir değer girin.`n`nWindows boyutu boş bırakılırsa disk alanının tamamı Windows bölümüne ayrılır ve Data bölümü için yer kalmaz."
        # Checkbox'ı geri al
        $ChkCreateDataDisk.IsChecked = $false
        return
    }
    Update-PartitionPreview
})
$ChkCreateDataDisk.Add_Unchecked({
    Update-PartitionPreview
})

$TxtDataDiskLabel.Add_TextChanged({ Update-PartitionPreview })

$RdoFirmwareUEFI.Add_Checked({ Update-PartitionPreview })
$RdoFirmwareBIOS.Add_Checked({ Update-PartitionPreview })

# Refresh butonu — diskpart ile disk listesini log'a yaz
$BtnRefreshDisks.Add_Click({
    if (-not (Assert-NotBusy)) { return }
    $global:IsBusy = $true
    Set-Progress -Percent 10 -Message "Disk bilgisi alınıyor..."
    Write-Log "Diskler taranıyor..." -Level "INFO"

    $script:DiskRefreshJob = Start-Job -ScriptBlock {
        $tmp = [System.IO.Path]::GetTempFileName() + ".txt"
        "list disk`nexit" | Set-Content $tmp -Encoding ASCII
        $out = & diskpart /s $tmp 2>&1
        Remove-Item $tmp -ErrorAction SilentlyContinue
        return $out
    }

    $script:DiskRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:DiskRefreshTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:DiskRefreshTimer.Add_Tick({
        if ($script:DiskRefreshJob.State -notin @('Completed','Failed','Stopped')) { return }
        $script:DiskRefreshTimer.Stop()
        try {
            $lines = @(Receive-Job $script:DiskRefreshJob -ErrorAction SilentlyContinue)
            Remove-Job $script:DiskRefreshJob -Force -ErrorAction SilentlyContinue
            $diskLines = $lines | Where-Object { $_ -match '^\s+Disk\s+\d+' }
            if ($diskLines) {
                Write-Log "Mevcut diskler:" -Level "INFO"
                foreach ($dl in $diskLines) { Write-Log $dl.Trim() -Level "INFO" }
            } else {
                Write-Log "Disk listesi alınamadı veya disk bulunamadı." -Level "WARN"
            }
        } catch {
            Write-Log "Disk yenileme hatası: $($_.Exception.Message)" -Level "ERR"
        } finally {
            $global:IsBusy = $false
            Set-Progress -Percent 0 -Message "Sistem Hazır."
        }
    })
    $script:DiskRefreshTimer.Start()
})


# Firmware algilama (imagerestore.bat referans)
function Detect-Firmware {
    # WinPE kontrolu
    $miniNT = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name MiniNT -ErrorAction SilentlyContinue
    if ($miniNT) {
        $peFw = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction SilentlyContinue).PEFirmwareType
        if ($peFw -eq 2) { return 'UEFI' } else { return 'BIOS' }
    }
    # Online: SecureBoot anahtari sadece UEFI'de var
    $sb = Get-Item 'HKLM:\System\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue
    if ($sb) { return 'UEFI' }
    # bcdedit ile .efi kontrolu
    $bcd = & bcdedit /enum '{current}' 2>$null
    if ($bcd -match '\.efi') { return 'UEFI' }
    return 'BIOS'
}

# Disk secim dialog yardimci
function Show-DiskPickerDialog {
    param([string]$Title = "Hedef Diski Secin", [string]$WarningText = "")
    $dpXaml = [xml]@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="520" Height="340"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="White">
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="$Title" FontSize="11" Margin="0,0,0,8"/>
        <ListBox x:Name="DiskLB" Grid.Row="1" FontFamily="Consolas" FontSize="11"
                 BorderBrush="#D1D5DB" BorderThickness="1" Margin="0,0,0,8"/>
        <TextBlock Grid.Row="2" Text="$WarningText" FontSize="10" Foreground="#EF4444"
                   TextWrapping="Wrap" Margin="0,0,0,10"/>
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnDpOk" Content="Sec" Width="88" Height="28" Margin="0,0,8,0"
                    Background="#4A6278" Foreground="White" FontWeight="SemiBold">
                <Button.Template><ControlTemplate TargetType="Button">
                    <Border CornerRadius="4" Background="{TemplateBinding Background}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                </ControlTemplate></Button.Template>
            </Button>
            <Button x:Name="BtnDpCnl" Content="Iptal" Width="88" Height="28">
                <Button.Template><ControlTemplate TargetType="Button">
                    <Border CornerRadius="4" BorderBrush="#D1D5DB" BorderThickness="1" Background="White">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                </ControlTemplate></Button.Template>
            </Button>
        </StackPanel>
    </Grid>
</Window>
"@
    $r = New-Object System.Xml.XmlNodeReader $dpXaml
    $d = [Windows.Markup.XamlReader]::Load($r)
    $d.Owner = $window
    $lb = $d.FindName('DiskLB')
    $d.FindName('BtnDpOk').Add_Click({  $d.DialogResult = $true;  $d.Close() })
    $d.FindName('BtnDpCnl').Add_Click({ $d.DialogResult = $false; $d.Close() })
    return @{ Dialog = $d; ListBox = $lb }
}


# Apply Index listesini yükle (async - UI donmaz)
function Load-ApplyIndexList {
    param([string]$FilePath)

    $global:ApplyIndexItems.Clear()

    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path $FilePath)) { return }

    Set-Progress -Percent 10 -Message "WIM analiz ediliyor..."
    Write-Log "Index'ler yükleniyor: $FilePath" -Level "INFO"

    $script:ApplyIndexJob = Start-Job -ScriptBlock {
        param($p)
        try {
            Import-Module DISM -ErrorAction Stop
            $images = Get-WindowsImage -ImagePath $p -ErrorAction Stop
            $out = @()
            foreach ($img in $images) {
                $out += "$($img.ImageIndex)|$($img.ImageName)|$($img.ImageDescription)|$($img.ImageSize)"
            }
            return $out
        } catch {
            return "__ERR__:$($_.Exception.Message)"
        }
    } -ArgumentList $FilePath

    $script:ApplyIndexTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ApplyIndexTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:ApplyIndexTimer.Add_Tick({
        if ($script:ApplyIndexJob.State -notin @('Completed','Failed','Stopped')) { return }
        $script:ApplyIndexTimer.Stop()
        try {
            $results = @(Receive-Job $script:ApplyIndexJob -ErrorAction Stop)
            Remove-Job $script:ApplyIndexJob -Force

            if ($results.Count -eq 1 -and $results[0] -is [string] -and $results[0].StartsWith("__ERR__:")) {
                Write-Log "WIM okunamadı: $($results[0].Substring(8))" -Level "ERR"
                Show-Alert -Title "Hata" -Message "WIM dosyası okunamadı:`n$($results[0].Substring(8))"
                Set-Progress -Percent 0 -Message "Hata."
                return
            }

            foreach ($row in $results) {
                if ([string]::IsNullOrWhiteSpace($row)) { continue }
                $parts = $row -split "\|", 4
                if ($parts.Count -lt 2) { continue }
                $sizeGB = if ($parts.Count -gt 3 -and $parts[3] -match '^\d+$') {
                    [Math]::Round([uint64]$parts[3] / 1GB, 2)
                } else { 0 }
                $item = [IndexApplyItem]@{
                    IndexNumber = [int]$parts[0]
                    IndexName   = $parts[1]
                    Description = if ($parts.Count -gt 2 -and $parts[2]) { $parts[2] } else { "Açıklama yok" }
                    SizeText    = "$sizeGB GB"
                }
                $global:ApplyIndexItems.Add($item)
            }

            Write-Log "$($global:ApplyIndexItems.Count) index yüklendi." -Level "OK"
            if ($global:ApplyIndexItems.Count -gt 0) { $ListViewApplyIndex.SelectedIndex = 0 }
        } catch {
            Write-Log "Index listesi yüklenemedi: $($_.Exception.Message)" -Level "ERR"
            Show-Alert -Title "Hata" -Message "WIM dosyası okunamadı:`n$($_.Exception.Message)"
        } finally {
            Set-Progress -Percent 0 -Message "Sistem Hazır."
        }
    })
    $script:ApplyIndexTimer.Start()
}

# WIM Kaynak sec
$BtnApplyBrowseSource.Add_Click({
    $f = Select-File -Filter "Image Dosyalari (*.wim;*.esd)|*.wim;*.esd"
    if ($f -eq "") { return }
    $TxtApplySource.Text = $f
    Load-ApplyIndexList -FilePath $f
    Update-PartitionPreview
})

# ListView selection changed
$ListViewApplyIndex.Add_SelectionChanged({
    Update-PartitionPreview
})

# Bolume uygula - suruc secici
$BtnApplyBrowseDest.Add_Click({
    $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }
    $dlg = Show-DiskPickerDialog -Title "Hedef Bolumu Secin" -WarningText "UYARI: Secilen bolum FORMATLANACAKTIR!"
    $lb = $dlg.ListBox; $d = $dlg.Dialog
    $driveList = @()
    foreach ($dr in $drives) {
        $letter = $dr.Name.TrimEnd('\')
        $label  = if ($dr.VolumeLabel) { $dr.VolumeLabel } else { 'Etiketsiz' }
        $type   = switch ($dr.DriveType) { 'Fixed' {'Sabit'} 'Removable' {'Cikartilabilir'} 'Network' {'Ag'} default {"$($dr.DriveType)"} }
        $fGB    = [math]::Round($dr.AvailableFreeSpace/1GB,1)
        $sGB    = [math]::Round($dr.TotalSize/1GB,1)
        $lb.Items.Add("$letter   $(($label).PadRight(14)) [$type]   $sGB GB  ($fGB GB bos)") | Out-Null
        $driveList += $dr
    }
    $lb.SelectedIndex = 0
    if ($d.ShowDialog() -ne $true -or $lb.SelectedIndex -lt 0) { return }
    $TxtApplyDest.Text = $driveList[$lb.SelectedIndex].Name.TrimEnd('\')
})

# Diske uygula - disk secici
$BtnApplyDiskSelect.Add_Click({
    # diskpart ile disk listesi al
    $tmpScript = [System.IO.Path]::GetTempFileName()
    $tmpOut    = [System.IO.Path]::GetTempFileName()
    "list disk`nexit" | Set-Content $tmpScript -Encoding ASCII
    & diskpart /s $tmpScript | Out-File $tmpOut -Encoding UTF8
    $diskLines = Get-Content $tmpOut | Where-Object { $_ -match '^\s+Disk\s+\d+' }
    Remove-Item $tmpScript, $tmpOut -ErrorAction SilentlyContinue

    $dlg = Show-DiskPickerDialog -Title "Hedef Diski Secin" -WarningText "KRITIK UYARI: Secilen disk tamamen silinip yeniden bolumlenecek! Tum veriler kaybolur!"
    $lb = $dlg.ListBox; $d = $dlg.Dialog

    $diskNumbers = @()
    foreach ($line in $diskLines) {
        $lb.Items.Add($line.Trim()) | Out-Null
        if ($line -match 'Disk\s+(\d+)') { $diskNumbers += [int]$Matches[1] }
    }
    if ($lb.Items.Count -gt 0) { $lb.SelectedIndex = 0 }
    if ($d.ShowDialog() -ne $true -or $lb.SelectedIndex -lt 0) { return }
    $selDiskNum = $diskNumbers[$lb.SelectedIndex]
    $TxtApplyDisk.Text = "$selDiskNum  |  $($lb.Items[$lb.SelectedIndex])"
    $global:SelectedDiskNumber = $selDiskNum
    
    # Önizlemeyi güncelle
    Update-PartitionPreview
})

$BtnApplyImage.Add_Click({
    if ($TxtApplySource.Text -eq '') { Show-Alert -Title 'Eksik Alan' -Message 'WIM/ESD dosyasini secin.'; return }
    if ($global:ApplyIndexItems.Count -eq 0 -or $ListViewApplyIndex.SelectedIndex -lt 0) {
        Show-Alert -Title 'Eksik Alan' -Message 'Gecerli bir index secin.'; return
    }
    $appIdx  = $global:ApplyIndexItems[$ListViewApplyIndex.SelectedIndex].IndexNumber
    $appSrc  = $TxtApplySource.Text
    $imgName = $global:ApplyIndexItems[$ListViewApplyIndex.SelectedIndex].IndexName

    # ── MOD 1: Bolume Uygula ──
    if ($RdoApplyToVolume.IsChecked) {
        if ($TxtApplyDest.Text -eq '') { Show-Alert -Title 'Eksik Alan' -Message 'Hedef surucuyu secin.'; return }
        $appDest    = $TxtApplyDest.Text.TrimEnd('\')
        $appVerify  = $ChkApplyVerify.IsChecked
        $appCompact = $ChkApplyCompact.IsChecked

        $confirm = Show-Confirm -Title "Bölüme Uygulama" `
            -Message "UYARI: '$appDest' sürücü önce FORMATLANACAK, ardından imaj uygulanacaktır!`n`nMevcut tüm veriler silinir.`n`nKaynak : $appSrc`nIndex  : $appIdx - $imgName`nHedef  : $appDest`n`nDevam etmek istiyor musunuz?" `
            -Icon "⚠️"
        if (-not $confirm) { return }

        # Önce bölümü formatla — mevcut dosyalar karışmasın
        try {
            $driveLetter = $appDest.TrimEnd(':').TrimEnd('\')
            Write-Log "Format yapılıyor: ${driveLetter}:" -Level "RUN"
            Format-Volume -DriveLetter $driveLetter -FileSystem NTFS -Confirm:$false -Force | Out-Null
            Write-Log "Format tamamlandı." -Level "OK"
        } catch {
            Show-Alert -Title "Format Hatası" -Message "Bölüm formatlanamadı: $($_.Exception.Message)`n`nİşlem iptal edildi."
            return
        }

        $isRoot = ($appDest -match '^[A-Za-z]:$')
        $dirArg = if ($isRoot) { "${appDest}\" } else { "`"${appDest}\`"" }
        $appArgs = "/Apply-Image /ImageFile:`"$appSrc`" /Index:$appIdx /ApplyDir:$dirArg"
        if ($appVerify)  { $appArgs += ' /Verify' }
        if ($appCompact) { $appArgs += ' /Compact' }
        if ($ChkUseUnattend.IsChecked -and $TxtUnattendApply.Text -ne '') {
            $appArgs += " /Unattend:`"$($TxtUnattendApply.Text)`""
        }
        Write-Log "DISM $appArgs" -Level "RUN"
        Start-DismJob -DismArgs $appArgs -StatusMessage 'Imaj uygulanıyor' -OnComplete {
            param($ec)
            if ($ec -eq 0) {
                # Panther klasörüne unattend.xml kopyala
                if ($ChkUseUnattend.IsChecked -and $TxtUnattendApply.Text -ne '') {
                    try {
                        $pantherDir = "$($TxtApplyDest.Text.TrimEnd('\'))\Windows\Panther"
                        if (-not (Test-Path $pantherDir)) { New-Item -Path $pantherDir -ItemType Directory -Force | Out-Null }
                        Copy-Item -Path $TxtUnattendApply.Text -Destination "$pantherDir\unattend.xml" -Force
                        Write-Log "unattend.xml Panther klasörüne kopyalandı: $pantherDir\unattend.xml" -Level "OK"
                    } catch {
                        Write-Log "UYARI: unattend.xml kopyalanamadı: $($_.Exception.Message)" -Level "WARN"
                    }
                }
                Show-Alert -Title 'Tamamlandi' -Message 'Imaj basariyla uygulandı.'
            }
        }
        return
    }

    # ── MOD 3: VHD/VHDX'e Uygula ──
    if ($RdoApplyToVhd.IsChecked) {
        if ($TxtVhdPath.Text -eq '') { Show-Alert -Title 'Eksik Alan' -Message 'VHD/VHDX dosya yolunu belirtin.'; return }
        $vhdPath    = $TxtVhdPath.Text
        $vhdSizeGB  = 0
        $vhdDynamic = $RdoVhdDynamic.IsChecked
        if ($TxtVhdSize.Text -match '^\d+$') { $vhdSizeGB = [int]$TxtVhdSize.Text }
        $appVerify  = $ChkApplyVerify.IsChecked
        $appCompact = $ChkApplyCompact.IsChecked
        $unattendPath = if ($ChkUseUnattend.IsChecked) { $TxtUnattendApply.Text } else { '' }
        $hasRecovery  = [bool]$ChkCreateRecovery.IsChecked
        # Yeni mi mevcut mu — iptal durumunda silme kararı için
        $script:VhdIsNew = -not (Test-Path $vhdPath)

        $confirm = Show-Confirm -Title "VHD Uygulama" `
            -Message "VHD/VHDX'e imaj uygulanacak.`n`nKaynak : $appSrc`nIndex  : $appIdx - $imgName`nHedef  : $vhdPath`n`nDevam etmek istiyor musunuz?" `
            -Icon "💾"
        if (-not $confirm) { return }

        if (-not (Assert-NotBusy)) { return }
        $global:IsBusy = $true
        $BtnCancelJob.Visibility = [System.Windows.Visibility]::Visible
        $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Visible
        $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Visible
        Set-Progress -Percent 5 -Message 'VHD hazırlanıyor...'

        $script:VhdJob = Start-Job -ScriptBlock {
            param($vhdPath, $vhdSizeGB, $vhdDynamic, $appSrc, $appIdx, $appVerify, $appCompact, $unattendPath, $hasRec)
            function Log { param($m) Write-Output "[LOG] $m" }

            function RunDiskpart {
                param([string]$Script)
                $tmp = [System.IO.Path]::GetTempFileName() + ".txt"
                $Script | Set-Content $tmp -Encoding ASCII
                $out = & diskpart /s $tmp 2>&1
                Remove-Item $tmp -ErrorAction SilentlyContinue
                return $out
            }

            # 1. VHD olustur (gerekiyorsa)
            $isNew = -not (Test-Path $vhdPath)
            if ($isNew) {
                if ($vhdSizeGB -le 0) { Log "HATA: VHD boyutu belirtilmedi."; Write-Output "__EXIT__:1"; return }
                Log "VHD olusturuluyor: $vhdPath ($vhdSizeGB GB)"
                $vhdType = if ($vhdDynamic) { "expandable" } else { "fixed" }
                RunDiskpart "create vdisk file=`"$vhdPath`" maximum=$($vhdSizeGB * 1024) type=$vhdType`nexit" | ForEach-Object { Log $_ }
            } else {
                Log "Mevcut VHD: $vhdPath"
            }

            # 2. Detach + attach
            RunDiskpart "select vdisk file=`"$vhdPath`"`ndetach vdisk`nexit" | Out-Null
            Start-Sleep -Milliseconds 800
            Log "VHD attach ediliyor..."
            RunDiskpart "select vdisk file=`"$vhdPath`"`nattach vdisk`nexit" | ForEach-Object { Log $_ }
            Start-Sleep -Seconds 2

            # 3. Disk numarasini bul
            $listOut = RunDiskpart "select vdisk file=`"$vhdPath`"`nlist disk`nexit"
            $vhdDisk = $null
            foreach ($l in $listOut) {
                if ($l -match '\*\s+Disk\s+(\d+)') { $vhdDisk = [int]$Matches[1]; break }
            }
            if ($vhdDisk -eq $null) { Log "HATA: VHD disk numarasi bulunamadi."; Write-Output "__EXIT__:1"; return }
            Log "VHD disk: $vhdDisk"

            # 4. Initialize (yeni VHD)
            if ($isNew) {
                try { Initialize-Disk -Number $vhdDisk -PartitionStyle GPT -ErrorAction Stop; Log "Disk GPT initialize edildi." }
                catch { Log "Initialize: $($_.Exception.Message)" }
                Start-Sleep -Milliseconds 500
            }

            # 5. GPT bolumlendir: EFI + MSR + Windows [+ Recovery]
            Log "VHD bolumlendiriliyor (GPT)..."
            $ps = "SELECT DISK $vhdDisk`nCLEAN`nCONVERT GPT`n"
            $ps += "CREATE PARTITION EFI SIZE=260`nFORMAT QUICK FS=FAT32 LABEL=`"System`"`nASSIGN LETTER=S`n"
            $ps += "CREATE PARTITION MSR SIZE=16`n"
            if ($hasRec) {
                # Windows bolumunu olustur, sonra SHRINK ile son 1024 MB'i kes, oraya Recovery yaz
                $ps += "CREATE PARTITION PRIMARY`nFORMAT QUICK FS=NTFS LABEL=`"Windows`"`nASSIGN LETTER=W`n"
                $ps += "SHRINK MINIMUM=1024 DESIRED=1024`n"
                $ps += "CREATE PARTITION PRIMARY`nFORMAT QUICK FS=NTFS LABEL=`"Recovery`"`nASSIGN LETTER=R`n"
                $ps += "SET ID=`"de94bba4-06d1-4d40-a16a-bfd50179d6ac`"`nGPT ATTRIBUTES=0x8000000000000001`n"
            } else {
                $ps += "CREATE PARTITION PRIMARY`nFORMAT QUICK FS=NTFS LABEL=`"Windows`"`nASSIGN LETTER=W`n"
            }
            $ps += "EXIT"
            RunDiskpart $ps | ForEach-Object { Log $_ }
            Start-Sleep -Seconds 3
            if (-not (Test-Path "W:\")) { Log "HATA: W: atanamadi."; Write-Output "__EXIT__:1"; return }
            if ($hasRec -and -not (Test-Path "R:\")) { Log "UYARI: R: (Recovery) atanamadi, devam ediliyor..." }
            Log "Windows partition hazir: W:\"

            # 6. DISM Apply
            Log "DISM imaj uygulanıyor -> W:\"
            $dimArgs = "/Apply-Image /ImageFile:`"$appSrc`" /Index:$appIdx /ApplyDir:W:\"
            if ($appVerify)  { $dimArgs += " /Verify" }
            if ($appCompact) { $dimArgs += " /Compact" }
            if ($unattendPath -ne '') { $dimArgs += " /Unattend:`"$unattendPath`"" }
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "DISM.EXE"; $psi.Arguments = $dimArgs
            $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi; $proc.Start() | Out-Null
            Write-Output "__PID__:$($proc.Id)"
            while (-not $proc.StandardOutput.EndOfStream) {
                $line = $proc.StandardOutput.ReadLine()
                if ($line.Trim()) { Write-Output $line.Trim() }
            }
            $proc.WaitForExit(); $ec = $proc.ExitCode
            if ($ec -ne 0) { Log "DISM hata (kod: $ec)"; Write-Output "__EXIT__:$ec"; return }
            Log "DISM tamamlandi."

            # 6b. Panther klasörüne unattend.xml kopyala
            if ($unattendPath -ne '') {
                try {
                    $pantherDir = "W:\Windows\Panther"
                    if (-not (Test-Path $pantherDir)) { New-Item -Path $pantherDir -ItemType Directory -Force | Out-Null }
                    Copy-Item -Path $unattendPath -Destination "$pantherDir\unattend.xml" -Force
                    Log "unattend.xml Panther klasörüne kopyalandı."
                } catch {
                    Log "UYARI: unattend.xml kopyalanamadı: $($_.Exception.Message)"
                }
            }

            # 7. WinRE
            if ($hasRec) {
                Log "WinRE kopyalanıyor..."
                # R: harfi diskpart tarafindan zaten atandi (bolum olusturma sirasinda)
                # Atanmadiysa volume label ile bul ve ata
                if (-not (Test-Path "R:\")) {
                    Log "R: bulunamadi, volume aramasina geciliyor..."
                    $recVolOut = RunDiskpart "list volume`nexit"
                    $recVol = $null
                    foreach ($rv in $recVolOut) {
                        if ($rv -match 'Recovery') { if ($rv -match 'Volume\s+(\d+)') { $recVol = $Matches[1] }; break }
                    }
                    if ($recVol) {
                        RunDiskpart "select volume $recVol`nassign letter=R`nexit" | Out-Null
                        Start-Sleep -Milliseconds 1000
                    }
                }

                if (Test-Path "R:\") {
                    $winreDir = "R:\Recovery\WindowsRE"
                    if (-not (Test-Path $winreDir)) { New-Item -Path $winreDir -ItemType Directory -Force | Out-Null }
                    $winreSrc = "W:\Windows\System32\Recovery\WinRE.wim"
                    if (Test-Path $winreSrc) {
                        Copy-Item $winreSrc "$winreDir\WinRE.wim" -Force
                        $bootSdi = "W:\Windows\Boot\DVD\PCAT\boot.sdi"
                        if (Test-Path $bootSdi) { Copy-Item $bootSdi "$winreDir\boot.sdi" -Force }
                        # ReAgent.xml yaz
                        [System.IO.File]::WriteAllText("W:\Windows\System32\Recovery\ReAgent.xml",
                            "<?xml version='1.0' encoding='utf-8'?>`n<WindowsRE version=`"2.0`"><WinreBCD id=`"{00000000-0000-0000-0000-000000000000}`"/><WinreLocation path=`"\Recovery\WindowsRE`" id=`"0`" offset=`"0`" guid=`"{00000000-0000-0000-0000-000000000000}`"/></WindowsRE>")
                        Log "WinRE kopyalandi."
                    } else { Log "UYARI: WinRE.wim bulunamadi — $winreSrc" }
                    # R: harfini kaldir (gizli bolum olmali)
                    RunDiskpart "select disk $vhdDisk`nlist partition`nexit" | ForEach-Object { Log $_ }
                    $recVolOut2 = RunDiskpart "list volume`nexit"
                    foreach ($rv in $recVolOut2) {
                        if ($rv -match '\bR\b' -and $rv -match 'Volume\s+(\d+)') {
                            RunDiskpart "select volume $($Matches[1])`nremove letter=R`nexit" | Out-Null
                            break
                        }
                    }
                } else { Log "HATA: Recovery bolumu R: harfine atanamadi, WinRE atlaniyor." }
            }


            # 8. bcdboot
            Log "Boot kayıtları oluşturuluyor..."
            & bcdboot "W:\Windows" /s S: /f UEFI 2>&1 | ForEach-Object { Log $_ }

            # 9. EFI ve Windows harflerini kaldir
            RunDiskpart "select disk $vhdDisk`nselect partition 1`nremove letter=S`nexit" | Out-Null
            RunDiskpart "select disk $vhdDisk`nselect partition 3`nremove letter=W`nexit" | Out-Null

            # 10. VHD detach
            Log "VHD detach ediliyor..."
            RunDiskpart "select vdisk file=`"$vhdPath`"`ndetach vdisk`nexit" | ForEach-Object { Log $_ }

            Log "Tum islemler tamamlandi."
            # VDS servisini kapat (diskpart'in arka planda bıraktığı vds.exe)
            Get-Process -Name "vds" -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
            Write-Output "__EXIT__:0"

        } -ArgumentList $vhdPath, $vhdSizeGB, $vhdDynamic, $appSrc, $appIdx, $appVerify, $appCompact, $unattendPath, $hasRecovery

        $script:VhdTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:VhdTimer.Interval = [TimeSpan]::FromMilliseconds(100)
        $script:VhdTimer.Add_Tick({
            $lines = $script:VhdJob | Receive-Job
            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($line.StartsWith("__PID__:")) { $script:VssDismPid = [int]($line.Substring(8)); continue }
                if ($line.StartsWith("__EXIT__:")) {
                    $script:VhdTimer.Stop()
                    $ec = [int]($line.Substring(9))
                    Remove-Job -Job $script:VhdJob -Force -ErrorAction SilentlyContinue
                    $BtnCancelJob.Visibility = [System.Windows.Visibility]::Collapsed
                    $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Collapsed
                    $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Collapsed
                    $global:IsBusy = $false
                    if ($ec -eq 0) {
                        Set-Progress -Percent 100 -Message "Tamamlandı."
                        Show-Alert -Title "Tamamlandı" -Message "İmaj VHD/VHDX'e başarıyla uygulandı.`n`n$($TxtVhdPath.Text)"
                    } else {
                        Set-Progress -Percent 0 -Message "Hata (kod: $ec)"
                        Write-Log "VHD deploy hatasi (kod: $ec)" -Level "ERR"
                        # Hata durumunda VHD'yi detach et
                        $vhdErr = $TxtVhdPath.Text
                        if ($vhdErr -ne '') {
                            Start-Job -ScriptBlock {
                                param($p)
                                $tmp = [System.IO.Path]::GetTempFileName() + ".txt"
                                "select vdisk file=`"$p`"`ndetach vdisk`nexit" | Set-Content $tmp -Encoding ASCII
                                & diskpart /s $tmp 2>&1 | Out-Null
                                Remove-Item $tmp -ErrorAction SilentlyContinue
                            } -ArgumentList $vhdErr | Out-Null
                        }
                    }
                    Start-Sleep -Milliseconds 400
                    Set-Progress -Percent 0 -Message "Sistem Hazır."
                    # VDS servisini kapat
                    Get-Process -Name "vds" -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch {} }
                    return
                }
                if ($line.StartsWith("[LOG]")) {
                    Write-Log $line.Substring(5).Trim() -Level "INFO"
                    $global:_Console.AppendText("`r`n  " + $line.Substring(5).Trim())
                    $global:_Console.ScrollToEnd(); continue
                }
                $pct = -1
                if ($line -match "(\d+(?:\.\d+)?)\s*%") { $pct = [int][Math]::Floor([double]$Matches[1]) }
                $global:_Console.AppendText("`r`n  $line"); $global:_Console.ScrollToEnd()
                if ($pct -ge 0 -and $pct -le 100) {
                    $global:_PBar.Value = $pct; $global:_PctLbl.Text = "$pct%"
                    $global:_MsgLbl.Text = "VHD'ye uygulanıyor $pct%"
                }
            }
        })
        $script:VhdTimer.Start()
        return
    }
    if (-not $global:SelectedDiskNumber -and $global:SelectedDiskNumber -ne 0) {
        Show-Alert -Title 'Eksik Alan' -Message 'Hedef diski secin.'; return
    }
    $diskNum = $global:SelectedDiskNumber
    $fw      = if ($RdoFirmwareUEFI.IsChecked) { 'UEFI' } else { 'BIOS' }

    # C: disk koruması - online modda
    $sysDisk = $null
    try {
        $tmpS = [System.IO.Path]::GetTempFileName()
        $tmpO = [System.IO.Path]::GetTempFileName()
        "list volume`nexit" | Set-Content $tmpS -Encoding ASCII
        & diskpart /s $tmpS | Out-File $tmpO -Encoding UTF8
        $vols = Get-Content $tmpO
        $cLine = $vols | Where-Object { $_ -match '\sC\s' } | Select-Object -First 1
        if ($cLine -and $cLine -match 'Volume\s+(\d+)') {
            $cVolNum = $Matches[1]
            "select volume $cVolNum`nlist disk`nexit" | Set-Content $tmpS -Encoding ASCII
            & diskpart /s $tmpS | Out-File $tmpO -Encoding UTF8
            $cDiskLine = (Get-Content $tmpO | Where-Object { $_ -match '\*\s+Disk' } | Select-Object -First 1)
            if ($cDiskLine -match 'Disk\s+(\d+)') { $sysDisk = [int]$Matches[1] }
        }
        Remove-Item $tmpS, $tmpO -ErrorAction SilentlyContinue
    } catch {}

    if ($sysDisk -ne $null -and $diskNum -eq $sysDisk) {
        Show-Alert -Title 'Koruma' -Message "Secilen Disk $diskNum aktif sistem diskini (C:) iceriyor.`nOnline modda sistem diskini silemezsiniz."
        return
    }

    $diskInfo = $TxtApplyDisk.Text
    $confirm = Show-Confirm -Title "Disk Silme + Geri Yükleme" `
        -Message "KRİTİK UYARI!`n`nDisk $diskNum tamamen silinip yeniden bölümlenecektir!`nTÜM VERİLER KAYBOLACAK!`n`nFirmware : $fw`nKaynak   : $appSrc`nIndex    : $appIdx - $imgName`n`nEMİN MİSİNİZ?" `
        -Icon "🚨"
    if (-not $confirm) { return }

    if (-not (Assert-NotBusy)) { return }
    $global:IsBusy = $true
    $BtnCancelJob.Visibility = [System.Windows.Visibility]::Visible
    $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Visible
    $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Visible
    Update-CaptureForm

    # Kullanıcı seçimlerini al
    $hasRecovery  = $ChkCreateRecovery.IsChecked
    $hasData      = $ChkCreateDataDisk.IsChecked
    $addToBcd     = $ChkAddToBcd.IsChecked
    $dataLabel    = if ($TxtDataDiskLabel.Text) { $TxtDataDiskLabel.Text } else { "DATA" }
    $unattendPath = if ($ChkUseUnattend.IsChecked -and $TxtUnattendApply.Text -ne '') { $TxtUnattendApply.Text } else { '' }

    # BCD etiketi: seçili index'in WIM adından al
    $bcdLabel = "Windows"
    $selIdx = $ListViewApplyIndex.SelectedIndex
    if ($selIdx -ge 0 -and $selIdx -lt $global:ApplyIndexItems.Count) {
        $wimName = $global:ApplyIndexItems[$selIdx].IndexName
        if (-not [string]::IsNullOrWhiteSpace($wimName)) { $bcdLabel = $wimName }
    }
    $winSizeMB   = 0
    # Kullanıcı GB giriyor, MB'ye çevir ve 500 MB buffer bırak (MSR + alignment)
    if ($TxtWindowsSize.Text -match '^\d+$') { 
        $winSizeMB = ([int]$TxtWindowsSize.Text * 1024) - 500
    }

    $script:DeployJob = Start-Job -ScriptBlock {
        param($diskNum, $fw, $appSrc, $appIdx, $appVerify, $appCompact, $hasRec, $hasData, $dataLbl, $winSizeMB, $addToBcd, $bcdLabel, $unattendPath)

        function Log { param($msg) Write-Output "[LOG] $msg" }

        # ── 1. Disk bolumlendirme (Kullanıcı ayarlarına göre) ──
        Log "Disk $diskNum bolumlendiriliyor ($fw)..."
        
        # DiskPart scriptini dinamik olarak oluştur
        $partScript = ""
        
        if ($fw -eq 'UEFI') {
            # UEFI bölümlendirme - doğru sıralama: EFI → MSR → Windows → Recovery → Data
            $partScript = "SELECT DISK $diskNum`r`n"
            $partScript += "CLEAN`r`n"
            $partScript += "CONVERT GPT`r`n"
            
            # 1. EFI System Partition (260MB)
            $partScript += "CREATE PARTITION EFI SIZE=260`r`n"
            $partScript += "FORMAT QUICK FS=FAT32 LABEL=`"System`"`r`n"
            $partScript += "ASSIGN LETTER=S`r`n"
            
            # 2. MSR (16MB)
            $partScript += "CREATE PARTITION MSR SIZE=16`r`n"
            
            # 3. Windows Partition
            if ($winSizeMB -gt 0) {
                # Kullanıcı boyut belirtmiş
                $partScript += "CREATE PARTITION PRIMARY SIZE=$winSizeMB`r`n"
            } else {
                # Tüm disk (Recovery varsa onun için alan bırak)
                if ($hasRec) {
                    # Kalan alan - 1024 MB (recovery için)
                    # DiskPart bunu otomatik hesaplar: tüm kalan alanı ver
                    $partScript += "CREATE PARTITION PRIMARY`r`n"
                } else {
                    # Tam kalan alan
                    $partScript += "CREATE PARTITION PRIMARY`r`n"
                }
            }
            $partScript += "FORMAT QUICK FS=NTFS LABEL=`"Windows`"`r`n"
            $partScript += "ASSIGN`r`n"
            
            # 4. Recovery Partition (varsa, 1GB)
            if ($hasRec) {
                # Windows boyutu boşsa, Windows tüm diski kaplar; Recovery için yer açmak üzere 1GB shrink yap.
                # Not: SHRINK MB cinsindendir ve seçili volume üzerinde çalışır.
                if ($winSizeMB -le 0) {
                    $partScript += "SHRINK DESIRED=1024 MINIMUM=1024`r`n"
                }
                $partScript += "CREATE PARTITION PRIMARY SIZE=1024`r`n"
                $partScript += "FORMAT QUICK FS=NTFS LABEL=`"WinRE`"`r`n"
                $partScript += "SET ID=`"de94bba4-06d1-4d40-a16a-bfd50179d6ac`"`r`n"
                $partScript += "GPT ATTRIBUTES=0x8000000000000001`r`n"
            }
            
            # 5. DATA Partition (Windows sabit boyutluysa ve Data istendiyse)
            if ($hasData -and $winSizeMB -gt 0) {
                $partScript += "CREATE PARTITION PRIMARY`r`n"
                $partScript += "FORMAT QUICK FS=NTFS LABEL=`"$dataLbl`"`r`n"
                $partScript += "ASSIGN`r`n"
            }
            
            $partScript += "EXIT`r`n"
        } else {
            # BIOS/MBR bölümlendirme - doğru sıralama: System → Windows → Recovery → Data
            $partScript = "SELECT DISK $diskNum`r`n"
            $partScript += "CLEAN`r`n"
            $partScript += "CONVERT MBR`r`n"
            
            # 1. System Partition (260MB, Active)
            $partScript += "CREATE PARTITION PRIMARY SIZE=260`r`n"
            $partScript += "FORMAT QUICK FS=NTFS LABEL=`"System`"`r`n"
            $partScript += "ACTIVE`r`n"
            $partScript += "ASSIGN LETTER=S`r`n"
            
            # 2. Windows Partition
            if ($winSizeMB -gt 0) {
                $partScript += "CREATE PARTITION PRIMARY SIZE=$winSizeMB`r`n"
            } else {
                if ($hasRec) {
                    # Kalan alan (Recovery için 1024MB bırak)
                    $partScript += "CREATE PARTITION PRIMARY`r`n"
                } else {
                    $partScript += "CREATE PARTITION PRIMARY`r`n"
                }
            }
            $partScript += "FORMAT QUICK FS=NTFS LABEL=`"Windows`"`r`n"
            $partScript += "ASSIGN`r`n"
            
            # 3. Recovery Partition (varsa, 1GB)
            if ($hasRec) {
                # Windows boyutu boşsa, Windows tüm diski kaplar; Recovery için yer açmak üzere 1GB shrink yap.
                if ($winSizeMB -le 0) {
                    $partScript += "SHRINK DESIRED=1024 MINIMUM=1024`r`n"
                }
                $partScript += "CREATE PARTITION PRIMARY SIZE=1024`r`n"
                $partScript += "FORMAT QUICK FS=NTFS LABEL=`"WinRE`"`r`n"
                $partScript += "SET ID=27`r`n"
            }
            
            # 4. DATA Partition
            if ($hasData -and $winSizeMB -gt 0) {
                $partScript += "CREATE PARTITION PRIMARY`r`n"
                $partScript += "FORMAT QUICK FS=NTFS LABEL=`"$dataLbl`"`r`n"
                $partScript += "ASSIGN`r`n"
            }
            
            $partScript += "EXIT`r`n"
        }
        $tmpPart = [System.IO.Path]::GetTempFileName() + ".txt"
        $partScript | Set-Content $tmpPart -Encoding ASCII
        $partOut = & diskpart /s $tmpPart 2>&1
        Remove-Item $tmpPart -ErrorAction SilentlyContinue
        foreach ($line in $partOut) { if ($line.Trim()) { Log $line } }
        Start-Sleep -Seconds 2

        # ── 2. Windows etiketli bolumu bul ──
        Log "Windows bolumu aranıyor..."
        $tmpVol = [System.IO.Path]::GetTempFileName() + ".txt"
        "list volume`nexit" | Set-Content $tmpVol -Encoding ASCII
        $volOut = & diskpart /s $tmpVol 2>&1
        Remove-Item $tmpVol -ErrorAction SilentlyContinue

        $winVol = $null; $winLetter = $null
        foreach ($vl in $volOut) {
            if ($vl -match 'Windows') {
                if ($vl -match 'Volume\s+(\d+)') { $winVol = $Matches[1] }
                # Harf atanmissa al
                if ($vl -match '\s+([A-Z])\s+') { $winLetter = $Matches[1] }
                break
            }
        }

        # Harf yoksa ata
        if ($winVol -and -not $winLetter) {
            Log "Windows harfsiz, W: atanıyor..."
            $tmpAssign = [System.IO.Path]::GetTempFileName() + ".txt"
            "select volume $winVol`nassign letter=W`nexit" | Set-Content $tmpAssign -Encoding ASCII
            & diskpart /s $tmpAssign | Out-Null
            Remove-Item $tmpAssign -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            $winLetter = 'W'
        }

        if (-not $winLetter) {
            Log "HATA: Hedef Windows bolumu bulunamadi!"
            Write-Output "__EXIT__:1"
            return
        }
        Log "Hedef bolum: ${winLetter}:"

        # ── 3. DISM Apply ──
        Log "DISM ile imaj uygulanıyor..."
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "DISM.EXE"
        $dimArgs = "/Apply-Image /ImageFile:`"$appSrc`" /Index:$appIdx /ApplyDir:${winLetter}:\"
        if ($appVerify)  { $dimArgs += " /Verify" }
        if ($appCompact) { $dimArgs += " /Compact" }
        if ($unattendPath -ne '') { $dimArgs += " /Unattend:`"$unattendPath`"" }
        $psi.Arguments = $dimArgs
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        Write-Output "[DISM_CMD] DISM.EXE $dimArgs"
        $proc.Start() | Out-Null
        Write-Output "__PID__:$($proc.Id)"
        while (-not $proc.StandardOutput.EndOfStream) {
            $line = $proc.StandardOutput.ReadLine()
            if ($line.Trim()) { Write-Output $line.Trim() }
        }
        $err = $proc.StandardError.ReadToEnd()
        if ($err) { foreach ($el in ($err -split "`n")) { if ($el.Trim()) { Write-Output "  $($el.Trim())" } } }
        $proc.WaitForExit()
        $ec = $proc.ExitCode
        if ($ec -ne 0) {
            Log "DISM hata! (Cikis: $ec)"
            Write-Output "__EXIT__:$ec"
            return
        }
        Log "DISM tamamlandi."

        # ── 3b. Panther klasörüne unattend.xml kopyala ──
        if ($unattendPath -ne '') {
            try {
                $pantherDir = "${winLetter}:\Windows\Panther"
                if (-not (Test-Path $pantherDir)) { New-Item -Path $pantherDir -ItemType Directory -Force | Out-Null }
                Copy-Item -Path $unattendPath -Destination "$pantherDir\unattend.xml" -Force
                Log "unattend.xml Panther klasörüne kopyalandı: $pantherDir\unattend.xml"
            } catch {
                Log "UYARI: unattend.xml kopyalanamadı: $($_.Exception.Message)"
            }
        }

        # ── 4. WinRE — Recovery partition'a kopyala ve etkinleştir ──
        if ($hasRec) {
            Log "WinRE Recovery partition'a tasiniyor..."

            # Recovery (WinRE label'li) volume'u bul
            $tmpRecList = [System.IO.Path]::GetTempFileName() + ".txt"
            "list volume`nexit" | Set-Content $tmpRecList -Encoding ASCII
            $recVolOut = & diskpart /s $tmpRecList 2>&1
            Remove-Item $tmpRecList -ErrorAction SilentlyContinue

            $recVolNum = $null
            foreach ($rv in $recVolOut) {
                if ($rv -match 'WinRE') {
                    if ($rv -match 'Volume\s+(\d+)') { $recVolNum = $Matches[1] }
                    break
                }
            }

            if ($recVolNum) {
                # Geçici harf ata
                $tmpRecAssign = [System.IO.Path]::GetTempFileName() + ".txt"
                "select volume $recVolNum`nassign letter=R`nexit" | Set-Content $tmpRecAssign -Encoding ASCII
                & diskpart /s $tmpRecAssign | Out-Null
                Remove-Item $tmpRecAssign -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 800

                # Hedef dizini oluştur
                $winreDestDir = "R:\Recovery\WindowsRE"
                if (-not (Test-Path $winreDestDir)) {
                    New-Item -Path $winreDestDir -ItemType Directory -Force | Out-Null
                }

                # winre.wim kopyala
                $winreSrc = "${winLetter}:\Windows\System32\Recovery\WinRE.wim"
                if (Test-Path $winreSrc) {
                    Copy-Item -Path $winreSrc -Destination "$winreDestDir\WinRE.wim" -Force
                    Log "WinRE.wim kopyalandi: $winreDestDir\WinRE.wim"

                    # boot.sdi kopyala (varsa)
                    $bootSdiSrc = "${winLetter}:\Windows\Boot\DVD\PCAT\boot.sdi"
                    if (Test-Path $bootSdiSrc) {
                        Copy-Item -Path $bootSdiSrc -Destination "$winreDestDir\boot.sdi" -Force
                        Log "boot.sdi kopyalandi."
                    }

                    # ReAgent.xml manuel olustur — reagentc /target offline sistemde guvenilir degil.
                    # Windows ilk boot'ta bu XML'i okuyarak WinRE'yi aktif eder.
                    # Partition numarasini bul (diskpart list partition ciktisinden)
                    $tmpPartInfo = [System.IO.Path]::GetTempFileName() + ".txt"
                    "select disk $diskNum`nlist partition`nexit" | Set-Content $tmpPartInfo -Encoding ASCII
                    $partInfoOut = & diskpart /s $tmpPartInfo 2>&1
                    Remove-Item $tmpPartInfo -ErrorAction SilentlyContinue

                    $recPartNum = $null
                    # Recovery partition'u sira numarasina gore bul
                    # diskpart list partition ciktisinda WinRE label gorunmez, son primary partition'dur
                    foreach ($pl in $partInfoOut) {
                        if ($pl -match 'Partition\s+(\d+)') { $recPartNum = $Matches[1] }
                    }

                    if ($recPartNum) {
                        $reagentXml = @"
<?xml version='1.0' encoding='utf-8'?>
<WindowsRE version="2.0">
  <WinreBCD id="{00000000-0000-0000-0000-000000000000}"/>
  <WinreLocation path="\Recovery\WindowsRE" id="0" offset="0" guid="{00000000-0000-0000-0000-000000000000}"/>
  <ImageLocation path="" id="0" offset="0" guid="{00000000-0000-0000-0000-000000000000}"/>
  <OsInstallLocation path="" id="0" offset="0" guid="{00000000-0000-0000-0000-000000000000}" index="0"/>
  <customImageFailoverLocation path="" id="0" offset="0" guid="{00000000-0000-0000-0000-000000000000}" index="0"/>
  <OperationParam path="" id="0" offset="0" guid="{00000000-0000-0000-0000-000000000000}"/>
  <OperationPermanentParam path="" id="0" offset="0" guid="{00000000-0000-0000-0000-000000000000}"/>
  <OsBuildVersion path=""/>
  <OemTool path=""/>
  <IsAutoRepairOn>1</IsAutoRepairOn>
  <IsServer>0</IsServer>
  <NoBCDEdit>0</NoBCDEdit>
  <IsWimBoot>0</IsWimBoot>
  <InstallState>0</InstallState>
  <OsInstallAvailable>0</OsInstallAvailable>
  <ImageInstallAvailable>0</ImageInstallAvailable>
  <UseCustomFailover>0</UseCustomFailover>
</WindowsRE>
"@
                        # Windows\System32\Recovery altina da ReAgent.xml yaz (reagentc buradan okur)
                        $reagentXml | Set-Content -Path "${winLetter}:\Windows\System32\Recovery\ReAgent.xml" -Encoding UTF8 -Force
                        Log "ReAgent.xml olusturuldu (Windows\System32\Recovery)."
                    }
                    Log "WinRE dosyalari Recovery partition'a kopyalandi. Ilk boot'ta Windows aktif edecek."
                } else {
                    Log "UYARI: WinRE.wim bulunamadi: $winreSrc — Recovery partition bos kalacak."
                }

                # Geçici harfi kaldır (partition gizli kalmalı)
                $tmpRecRemove = [System.IO.Path]::GetTempFileName() + ".txt"
                "select volume $recVolNum`nremove letter=R`nexit" | Set-Content $tmpRecRemove -Encoding ASCII
                & diskpart /s $tmpRecRemove | Out-Null
                Remove-Item $tmpRecRemove -ErrorAction SilentlyContinue
                Log "Recovery harfi kaldirildi (partition gizli)."
            } else {
                Log "UYARI: WinRE volume bulunamadi (label=WinRE), reagentc atlandi."
            }
        }

        # ── 5. bcdboot ile boot kaydı ──
        Log "Boot kayıtları oluşturuluyor (bcdboot)..."
        if ($fw -eq 'UEFI') {
            # EFI bolumunu bul, gecici harf ata
            $tmpEfi = [System.IO.Path]::GetTempFileName() + ".txt"
            "select disk $diskNum`nlist partition`nexit" | Set-Content $tmpEfi -Encoding ASCII
            $partInfo = & diskpart /s $tmpEfi 2>&1
            Remove-Item $tmpEfi -ErrorAction SilentlyContinue

            $efiPart = $null
            foreach ($pl in $partInfo) {
                if ($pl -match 'System') { # EFI partition type
                    if ($pl -match 'Partition\s+(\d+)') { $efiPart = $Matches[1] }
                    break
                }
            }

            if ($efiPart) {
                $tmpEfiAssign = [System.IO.Path]::GetTempFileName() + ".txt"
                "select disk $diskNum`nselect partition $efiPart`nassign letter=S`nexit" | Set-Content $tmpEfiAssign -Encoding ASCII
                & diskpart /s $tmpEfiAssign | Out-Null
                Remove-Item $tmpEfiAssign -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
                Log "bcdboot ${winLetter}:\Windows /s S: /f UEFI"
                $bcdOut = & bcdboot "${winLetter}:\Windows" /s S: /f UEFI 2>&1
                foreach ($bl in $bcdOut) { Log $bl }
                # EFI harfini kaldir
                $tmpEfiRemove = [System.IO.Path]::GetTempFileName() + ".txt"
                "select disk $diskNum`nselect partition $efiPart`nremove letter=S`nexit" | Set-Content $tmpEfiRemove -Encoding ASCII
                & diskpart /s $tmpEfiRemove | Out-Null
                Remove-Item $tmpEfiRemove -ErrorAction SilentlyContinue
            } else {
                Log "EFI bolumu bulunamadi, fallback bcdboot..."
                $bcdOut = & bcdboot "${winLetter}:\Windows" /f UEFI 2>&1
                foreach ($bl in $bcdOut) { Log $bl }
            }
        } else {
            Log "bcdboot ${winLetter}:\Windows /f BIOS"
            $bcdOut = & bcdboot "${winLetter}:\Windows" /f BIOS 2>&1
            foreach ($bl in $bcdOut) { Log $bl }
        }
        Log "Tum islemler tamamlandi."

        # ── 6. Mevcut sistemin BCD'sine ekle (opsiyonel) ──
        if ($addToBcd) {
            Log "Mevcut BCD deposuna yeni kurulum ekleniyor..."
            try {
                # Mevcut {current} girişini kopyala, yeni bir BCD girdisi oluştur
                $copyOut = & bcdedit /copy '{current}' /d "$bcdLabel" 2>&1
                # Çıktıdan yeni GUID'i al: "The entry was successfully copied to {xxxxxxxx-...}"
                $newGuid = $null
                foreach ($co in $copyOut) {
                    if ($co -match '\{([0-9a-fA-F\-]+)\}') { $newGuid = "{$($Matches[1])}"; break }
                }

                if ($newGuid) {
                    # device ve osdevice'ı yeni Windows bölümüne yönlendir
                    & bcdedit /set $newGuid device    "partition=${winLetter}:" 2>&1 | Out-Null
                    & bcdedit /set $newGuid osdevice  "partition=${winLetter}:" 2>&1 | Out-Null
                    & bcdedit /set $newGuid path      "\Windows\system32\winload.efi" 2>&1 | Out-Null
                    & bcdedit /set $newGuid systemroot "\Windows" 2>&1 | Out-Null
                    # Boot menüsüne ekle
                    & bcdedit /displayorder $newGuid /addlast 2>&1 | Out-Null
                    Log "BCD girdisi olusturuldu: $newGuid"
                } else {
                    Log "UYARI: BCD kopyalama cikti parse edilemedi: $copyOut"
                }
            } catch {
                Log "UYARI: BCD ekleme hatasi: $($_.Exception.Message)"
            }
        }

        Write-Output "__EXIT__:0"
    } -ArgumentList $diskNum, $fw, $appSrc, $appIdx, $ChkApplyVerify.IsChecked, $ChkApplyCompact.IsChecked, $hasRecovery, $hasData, $dataLabel, $winSizeMB, $addToBcd, $bcdLabel, $unattendPath

    # Timer
    Set-Progress -Percent 5 -Message "Disk hazirlaniyor..."
    $script:DeployTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:DeployTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:DeployTimer.Add_Tick({
        $lines = $script:DeployJob | Receive-Job
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line.StartsWith("__PID__:")) { $script:VssDismPid = [int]($line.Substring(8)); continue }
            if ($line.StartsWith("[DISM_CMD]")) { Write-Log $line.Substring(10).Trim() -Level "RUN"; continue }
            if ($line.StartsWith("__EXIT__:")) {
                $script:DeployTimer.Stop()
                $ec = [int]($line.Substring(9))
                Remove-Job -Job $script:DeployJob -Force -ErrorAction SilentlyContinue
                $BtnCancelJob.Visibility = [System.Windows.Visibility]::Collapsed
                $BusyOverlayMenu.Visibility    = [System.Windows.Visibility]::Collapsed
                $BusyOverlayContent.Visibility = [System.Windows.Visibility]::Collapsed
                if ($global:CancelRequested) {
                    Write-Log "Iptal edildi." -Level "ERR"
                    Set-Progress -Percent 0 -Message "Iptal edildi."
                    # Yarım kalan disk yapısını temizle
                    if ($global:SelectedDiskNumber -ne $null) {
                        $cleanResult = Show-Confirm -Title "Disk Temizleme" `
                            -Message "Deploy iptal edildi. Disk $($global:SelectedDiskNumber) üzerinde yarım kalmış partition tablosu olabilir.`n`nDisk otomatik temizlensin mi? (Önerilen: Evet)`n`nHayır derseniz bir sonraki deploy'da 3. parti araç gerekebilir." `
                            -Icon "⚠️"
                        if ($cleanResult) {
                            Write-Log "Disk $($global:SelectedDiskNumber) temizleniyor..." -Level "WARN"
                            $tmpClean = [System.IO.Path]::GetTempFileName() + ".txt"
                            "select disk $($global:SelectedDiskNumber)`nclean`nexit" | Set-Content $tmpClean -Encoding ASCII
                            & diskpart /s $tmpClean 2>&1 | Out-Null
                            Remove-Item $tmpClean -ErrorAction SilentlyContinue
                            Write-Log "Disk temizlendi. Tekrar deploy yapilabilir." -Level "INFO"
                        } else {
                            Write-Log "Disk temizleme atlandı." -Level "INFO"
                        }
                    }
                } elseif ($ec -eq 0) {
                    Write-Log "Geri yukleme tamamlandi!" -Level "OK"
                    Set-Progress -Percent 100 -Message "Tamamlandi."
                    Show-Alert -Title "Tamamlandi" -Message "Imaj basariyla uygulandı ve boot kayıtları oluşturuldu.`n`nBilgisayarı yeniden baslatin."
                } else {
                    Write-Log "Geri yukleme hatasi. (Cikis: $ec)" -Level "ERR"
                    Set-Progress -Percent 0 -Message "Hata (kod: $ec)"
                    # Hatalı deploy sonrası diski temizle
                    if ($global:SelectedDiskNumber -ne $null) {
                        Write-Log "Disk $($global:SelectedDiskNumber) temizleniyor (hatalı deploy sonrası)..." -Level "WARN"
                        $tmpClean2 = [System.IO.Path]::GetTempFileName() + ".txt"
                        "select disk $($global:SelectedDiskNumber)`nclean`nexit" | Set-Content $tmpClean2 -Encoding ASCII
                        & diskpart /s $tmpClean2 2>&1 | Out-Null
                        Remove-Item $tmpClean2 -ErrorAction SilentlyContinue
                        Write-Log "Disk temizlendi. Tekrar deploy yapilabilir." -Level "INFO"
                    }
                }
                Start-Sleep -Milliseconds 400
                Set-Progress -Percent 0 -Message "Sistem Hazir."
                $global:IsBusy = $false
                $global:CancelRequested = $false
                Update-CaptureForm
                return
            }
            if ($line.StartsWith("[LOG]")) {
                Write-Log $line.Substring(5).Trim() -Level "INFO"
                $global:_Console.AppendText("`r`n  " + $line.Substring(5).Trim())
                $global:_Console.ScrollToEnd()
                continue
            }
            $pct = -1
            if ($line -match "(\d+(?:\.\d+)?)\s*%") { $pct = [int][Math]::Floor([double]$Matches[1]) }
            $global:_Console.AppendText("`r`n  $line")
            $global:_Console.ScrollToEnd()
            if ($pct -ge 0 -and $pct -le 100) {
                $global:_PBar.Value  = $pct
                $global:_PctLbl.Text = "$pct%"
                $global:_MsgLbl.Text = "Imaj uygulanıyor $pct%"
            }
        }
    })
    $script:DeployTimer.Start()
})


# PG_8 : EXPORT & CONSOLIDATE
# ═══════════════════════════════════════════════════════
$TxtExportSource          = $window.FindName("TxtExportSource")
$TxtExportFileName        = $window.FindName("TxtExportFileName")
$BtnExportChooseFileName  = $window.FindName("BtnExportChooseFileName")
$CmbExportCompression     = $window.FindName("CmbExportCompression")
$ChkExportBootable        = $window.FindName("ChkExportBootable")
$ChkExportWimBoot         = $window.FindName("ChkExportWimBoot")
$ChkExportCheckIntegrity  = $window.FindName("ChkExportCheckIntegrity")
$BtnExportImage           = $window.FindName("BtnExportImage")

# Export - Yeni ListView kontrolleri
$TxtExportIndexSource     = $window.FindName("TxtExportIndexSource")
$ListViewExportIndex      = $window.FindName("ListViewExportIndex")
$BtnExportIndexBrowse     = $window.FindName("BtnExportIndexBrowse")
$BtnExportIndexRefresh    = $window.FindName("BtnExportIndexRefresh")
$TxtExportIndexCount      = $window.FindName("TxtExportIndexCount")

# Index Silme (Yeni Çoklu Seçim)
$TxtDeleteIndexSource     = $window.FindName("TxtDeleteIndexSource")
$ListViewDeleteIndex      = $window.FindName("ListViewDeleteIndex")
$ChkSelectAllHeader       = $window.FindName("ChkSelectAllHeader")
$BtnDeleteIndexBrowse     = $window.FindName("BtnDeleteIndexBrowse")
$BtnDeleteIndexRefresh    = $window.FindName("BtnDeleteIndexRefresh")
$BtnSelectAllIndexes      = $window.FindName("BtnSelectAllIndexes")
$BtnDeselectAllIndexes    = $window.FindName("BtnDeselectAllIndexes")
$BtnDeleteIndex           = $window.FindName("BtnDeleteIndex")
$TxtDeleteIndexCount      = $window.FindName("TxtDeleteIndexCount")

# ListView için Data Class
class PackageItem {
    [bool]   $IsSelected
    [string] $PackageName
    [string] $Version
    [string] $Architecture
    [string] $State
    [string] $StateLabel
    [string] $StateColor
}

class FeatureItem {
    [bool]   $IsSelected
    [string] $FeatureName
    [string] $DisplayName
    [string] $State         # Enabled / Disabled / EnablePending / DisablePending
    [string] $StateLabel
    [string] $StateColor
}

class IndexDeleteItem {
    [bool]   $IsSelected
    [int]    $IndexNumber
    [string] $IndexName
    [string] $Description
    [string] $SizeText
}

# Export için aynı yapı
class IndexExportItem {
    [bool]   $IsSelected
    [int]    $IndexNumber
    [string] $IndexName
    [string] $Description
    [string] $SizeText
}

# Driver için class
class DriverItem {
    [bool]   $IsSelected
    [string] $DriverName
    [string] $ProviderName
    [string] $Description
    [string] $ClassName
    [string] $Version
}

$global:PackageItems     = New-Object System.Collections.ObjectModel.ObservableCollection[PackageItem]
$global:AllPackageItems  = New-Object System.Collections.Generic.List[PackageItem]
$ListViewPackages.ItemsSource = $global:PackageItems

$global:FeatureItems     = New-Object System.Collections.ObjectModel.ObservableCollection[FeatureItem]
$global:AllFeatureItems  = New-Object System.Collections.Generic.List[FeatureItem]
$ListViewFeatures.ItemsSource = $global:FeatureItems

$global:DeleteIndexItems = New-Object System.Collections.ObjectModel.ObservableCollection[IndexDeleteItem]
$ListViewDeleteIndex.ItemsSource = $global:DeleteIndexItems

# Export için ObservableCollection
$global:ExportIndexItems = New-Object System.Collections.ObjectModel.ObservableCollection[IndexExportItem]

# Driver için ObservableCollection
$global:DriverItems = New-Object System.Collections.ObjectModel.ObservableCollection[DriverItem]
$ListViewDrivers.ItemsSource = $global:DriverItems

# Filtreleme için tam liste
$global:AllDriverItems = New-Object System.Collections.Generic.List[DriverItem]

# Provider ComboBox güncelleme flag'i
$script:UpdatingProviderCombo = $false

# Mount için index item class
class MountIndexItem {
    [bool]   $IsSelected
    [int]    $IndexNumber
    [string] $IndexName
    [string] $Description
    [string] $Architecture
    [string] $Languages
    [string] $CreatedDate
    [string] $Size
    [string] $MountStatus
    [string] $MountStatusColor
    [string] $MountPath
}
$global:MountIndexItems = New-Object System.Collections.ObjectModel.ObservableCollection[MountIndexItem]
$ListViewMountIndex.ItemsSource = $global:MountIndexItems
$ListViewExportIndex.ItemsSource = $global:ExportIndexItems

# Seçim değişikliklerini izlemek için timer (Delete)
$script:DeleteIndexCheckTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DeleteIndexCheckTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:LastDeleteIndexCount = -1
$script:DeleteIndexCheckTimer.Add_Tick({
    if ($global:DeleteIndexItems.Count -eq 0) { return }
    
    $selectedCount = ($global:DeleteIndexItems | Where-Object { $_.IsSelected }).Count
    $totalCount = $global:DeleteIndexItems.Count
    
    # Sadece değişiklik olduysa güncelle
    if ($selectedCount -ne $script:LastDeleteIndexCount) {
        # Eğer hepsi seçiliyse, son seçileni geri al
        if ($selectedCount -ge $totalCount -and $totalCount -gt 0) {
            # Son seçilen item'ı bul ve geri al
            $lastSelected = $global:DeleteIndexItems | Where-Object { $_.IsSelected } | Select-Object -Last 1
            if ($lastSelected) {
                $lastSelected.IsSelected = $false
                $ListViewDeleteIndex.Items.Refresh()
                $selectedCount = $totalCount - 1
                Show-Alert -Title "Uyarı" -Message "Tüm index'ler seçilemez. En az bir index seçilmemiş kalmalı."
            }
        }
        
        $TxtDeleteIndexCount.Text = "Seçili: $selectedCount"
        $script:LastDeleteIndexCount = $selectedCount
    }
})
$script:DeleteIndexCheckTimer.Start()

# Seçim değişikliklerini izlemek için timer (Export)
$script:ExportIndexCheckTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ExportIndexCheckTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:LastExportIndexCount = -1
$script:ExportIndexCheckTimer.Add_Tick({
    if ($global:ExportIndexItems.Count -eq 0) { return }
    
    $selectedCount = ($global:ExportIndexItems | Where-Object { $_.IsSelected }).Count
    
    # Sadece değişiklik olduysa güncelle
    if ($selectedCount -ne $script:LastExportIndexCount) {
        $TxtExportIndexCount.Text = "Seçili: $selectedCount"
        $script:LastExportIndexCount = $selectedCount
    }
})
$script:ExportIndexCheckTimer.Start()

# Seçim değişikliklerini izlemek için timer (Driver)
$script:DriverCheckTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DriverCheckTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:LastDriverCount = -1
$script:LastDriverTotalCount = -1
$script:DriverCheckTimer.Add_Tick({
    if ($global:DriverItems.Count -eq 0) { return }
    
    $visibleSelected = ($global:DriverItems | Where-Object { $_.IsSelected }).Count
    $totalSelected   = ($global:AllDriverItems | Where-Object { $_.IsSelected }).Count
    
    if ($visibleSelected -ne $script:LastDriverCount -or $totalSelected -ne $script:LastDriverTotalCount) {
        $TxtDriverCount.Text      = "Seçili (görünür): $visibleSelected"
        $TxtDriverTotalCount.Text = "Toplam Seçili: $totalSelected"
        $script:LastDriverCount      = $visibleSelected
        $script:LastDriverTotalCount = $totalSelected
    }
})
$script:DriverCheckTimer.Start()


# ── Export Index Liste Yönetimi ──

function Load-ExportIndexList {
    param([string]$FilePath)
    
    $global:ExportIndexItems.Clear()
    $TxtExportIndexCount.Text = "Seçili: 0"
    
    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path $FilePath)) {
        return
    }
    
    try {
        Import-Module DISM -ErrorAction SilentlyContinue
        $images = Get-WindowsImage -ImagePath $FilePath
        
        foreach ($img in $images) {
            $sizeGB = [Math]::Round($img.ImageSize / 1GB, 2)
            $item = [IndexExportItem]@{
                IsSelected   = $false
                IndexNumber  = $img.ImageIndex
                IndexName    = $img.ImageName
                Description  = if ($img.ImageDescription) { $img.ImageDescription } else { "Açıklama yok" }
                SizeText     = "$sizeGB GB"
            }
            $global:ExportIndexItems.Add($item)
        }
        
        Write-Log "$($images.Count) index yüklendi: $FilePath" -Level "INFO"
        
    } catch {
        Write-Log "Index listesi yüklenemedi: $($_.Exception.Message)" -Level "ERR"
        Show-Alert -Title "Hata" -Message "WIM dosyası okunamadı:`n$($_.Exception.Message)"
    }
}

# Export Gözat butonu
$BtnExportIndexBrowse.Add_Click({
    $f = Select-File -Filter "Image Dosyaları (*.wim;*.esd)|*.wim;*.esd"
    if ($f -eq "") { return }
    $TxtExportIndexSource.Text = $f
    Load-ExportIndexList -FilePath $f
})

# Export Yenile butonu
$BtnExportIndexRefresh.Add_Click({
    if ($TxtExportIndexSource.Text -ne "") {
        Load-ExportIndexList -FilePath $TxtExportIndexSource.Text
    }
})

# BtnExportChooseFileName (Hedef dosya seçimi)
$BtnExportChooseFileName.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title            = "Hedef Dosyayı Kaydet"
    $dlg.Filter           = "WIM Dosyası (*.wim)|*.wim|ESD Dosyası (*.esd)|*.esd|Tüm Dosyalar (*.*)|*.*"
    $dlg.DefaultExt       = "wim"
    $dlg.AddExtension     = $true
    $dlg.OverwritePrompt  = $true
    
    # Başlangıç dizini ve dosya adı önerisi
    if ($TxtExportFileName.Text -ne "") {
        $dlg.InitialDirectory = [System.IO.Path]::GetDirectoryName($TxtExportFileName.Text)
        $dlg.FileName = [System.IO.Path]::GetFileNameWithoutExtension($TxtExportFileName.Text)
    } elseif ($TxtExportIndexSource.Text -ne "") {
        $dlg.InitialDirectory = [System.IO.Path]::GetDirectoryName($TxtExportIndexSource.Text)
        $dlg.FileName = [System.IO.Path]::GetFileNameWithoutExtension($TxtExportIndexSource.Text)
    } else {
        $dlg.FileName = "export"
    }
    
    if ($dlg.ShowDialog($window) -eq $true) {
        $fn = $dlg.FileName
        # Çift uzantı kontrolü - eğer zaten .wim/.esd/.swm varsa ekleme
        $currentExt = [System.IO.Path]::GetExtension($fn).ToUpper()
        $validExts = @(".WIM", ".ESD", ".SWM")
        
        if ($validExts -notcontains $currentExt) {
            # Uzantı yoksa ekle
            $fn += ".wim"
        }
        # Zaten varsa olduğu gibi bırak
        
        $TxtExportFileName.Text = $fn
    }
})

# ── Index Silme (Çoklu Seçim) ──

# Dosya seçme ve listeyi doldurma
function Load-DeleteIndexList {
    param([string]$FilePath)
    
    $global:DeleteIndexItems.Clear()
    $TxtDeleteIndexCount.Text = "Seçili: 0"
    
    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path $FilePath)) {
        return
    }
    
    try {
        Import-Module DISM -ErrorAction SilentlyContinue
        $images = Get-WindowsImage -ImagePath $FilePath
        
        foreach ($img in $images) {
            $sizeGB = [Math]::Round($img.ImageSize / 1GB, 2)
            $item = [IndexDeleteItem]@{
                IsSelected   = $false
                IndexNumber  = $img.ImageIndex
                IndexName    = $img.ImageName
                Description  = if ($img.ImageDescription) { $img.ImageDescription } else { "Açıklama yok" }
                SizeText     = "$sizeGB GB"
            }
            $global:DeleteIndexItems.Add($item)
        }
        
        Write-Log "$($images.Count) index yüklendi: $FilePath" -Level "INFO"
        
        # CheckBox değişikliklerini dinle
        Update-DeleteIndexCount
        
    } catch {
        Write-Log "Index listesi yüklenemedi: $($_.Exception.Message)" -Level "ERR"
        Show-Alert -Title "Hata" -Message "WIM dosyası okunamadı:`n$($_.Exception.Message)"
    }
}

# Seçili index sayısını güncelle
function Update-DeleteIndexCount {
    $window.Dispatcher.Invoke([action]{
        $selectedCount = ($global:DeleteIndexItems | Where-Object { $_.IsSelected }).Count
        $TxtDeleteIndexCount.Text = "Seçili: $selectedCount"
    })
}

# Dosya seç butonu
$BtnDeleteIndexBrowse.Add_Click({
    $f = Select-File -Filter "Image Dosyaları (*.wim;*.esd)|*.wim;*.esd"
    if ($f -eq "") { return }
    $TxtDeleteIndexSource.Text = $f
    Load-DeleteIndexList -FilePath $f
})

# Yenile butonu
$BtnDeleteIndexRefresh.Add_Click({
    if ($TxtDeleteIndexSource.Text -ne "") {
        Load-DeleteIndexList -FilePath $TxtDeleteIndexSource.Text
    }
})

# Header checkbox - ASLA tümünü seçemez (en az bir index seçilmemiş kalmalı)
$ChkSelectAllHeader.Add_Checked({
    # Tüm indexleri seçmeye çalışırsa engelle
    $this.IsChecked = $false
    Show-Alert -Title "Uyarı" -Message "Tüm index'ler seçilemez. En az bir index seçilmemiş kalmalı."
})

$ChkSelectAllHeader.Add_Unchecked({
    foreach ($item in $global:DeleteIndexItems) {
        $item.IsSelected = $false
    }
    $ListViewDeleteIndex.Items.Refresh()
    Update-DeleteIndexCount
})

# PropertyChanged event otomatik çalışacak - MouseUp'a gerek yok

# Index'leri sil butonu (ÇOK ÖNEMLİ: Çoklu silme mantığı)
$BtnDeleteIndex.Add_Click({
    if ($TxtDeleteIndexSource.Text -eq "") { 
        Show-Alert -Title "Eksik Alan" -Message "Kaynak WIM/ESD dosyasını seçin."
        return 
    }
    
    $selectedItems = $global:DeleteIndexItems | Where-Object { $_.IsSelected }
    
    if ($selectedItems.Count -eq 0) {
        Show-Alert -Title "Seçim Yapılmadı" -Message "En az bir index seçin."
        return
    }
    
    # Tüm index'leri seçmişse uyar (En az bir index SEÇİLMEMİŞ kalmalı)
    if ($selectedItems.Count -ge $global:DeleteIndexItems.Count) {
        Show-Alert -Title "Hata" -Message "Tüm index'ler silinemez. En az bir index seçilmemiş kalmalı."
        return
    }
    
    $script:DeleteSourceFile = $TxtDeleteIndexSource.Text
    $indexNames = ($selectedItems | ForEach-Object { "#$($_.IndexNumber)" }) -join ", "
    
    $confirm = Show-Confirm -Title "Index Silme" `
        -Message "$($selectedItems.Count) index silinecek: $indexNames`n`nDevam edilsin mi?" `
        -Icon "🗑️"
    
    if (-not $confirm) { return }
    
    # Seçili index'leri küçükten büyüğe sırala (DISM silme sırasına göre)
    $indexesToDelete = ($selectedItems | Sort-Object -Property IndexNumber).IndexNumber
    
    Write-Log "Toplu index silme başlatıldı: $($indexesToDelete -join ', ')" -Level "WARN"
    
    # Her index'i sırayla sil - ANCAK büyükten küçüğe sil (index numaraları kaymayacak)
    $indexesToDelete = $indexesToDelete | Sort-Object -Descending
    
    $script:DeleteQueue = New-Object System.Collections.Queue
    $script:TotalDeleteCount = $indexesToDelete.Count
    foreach ($idx in $indexesToDelete) {
        $script:DeleteQueue.Enqueue($idx)
    }
    
    # İlk silme işlemini başlat
    $nextIdx = $script:DeleteQueue.Dequeue()
    $delArgs = "/Delete-Image /ImageFile:`"$($script:DeleteSourceFile)`" /Index:$nextIdx"
    Write-Log "DISM $delArgs (Kalan: $($script:DeleteQueue.Count))" -Level "RUN"
    
    Start-DismJob -DismArgs $delArgs -StatusMessage "Index $nextIdx siliniyor... ($($script:TotalDeleteCount - $script:DeleteQueue.Count)/$($script:TotalDeleteCount))" -OnComplete {
        param($ec)
        if ($ec -ne 0) { 
            Write-Log "Index $nextIdx silme hatası!" -Level "ERR"
            Show-Alert -Title "Hata" -Message "Index silme işlemi başarısız oldu."
            return 
        }
        
        # Kuyruğa devam et
        if ($script:DeleteQueue.Count -gt 0) {
            $nextIdx = $script:DeleteQueue.Dequeue()
            $delArgs = "/Delete-Image /ImageFile:`"$($script:DeleteSourceFile)`" /Index:$nextIdx"
            Write-Log "DISM $delArgs (Kalan: $($script:DeleteQueue.Count))" -Level "RUN"
            
            Start-DismJob -DismArgs $delArgs -StatusMessage "Index $nextIdx siliniyor... ($($script:TotalDeleteCount - $script:DeleteQueue.Count)/$($script:TotalDeleteCount))" -OnComplete $MyInvocation.MyCommand.ScriptBlock -OnCancel {
                # İptal durumunda - orijinal WIM kısmen değişmiş olabilir ama temp yok
                Write-Log "Index silme iptal edildi (WIM dosyası kısmen değişmiş olabilir)" -Level "WARN"
                Load-DeleteIndexList -FilePath $script:DeleteSourceFile
            }
            return
        }
        
        # Tüm silme işlemleri tamamlandı - şimdi defragment et
        Write-Log "Tüm index'ler silindi. WIM defragment ediliyor ([DELETED] temizleniyor)..." -Level "INFO"
        $srcFile  = $script:DeleteSourceFile
        $script:TempDefragFile  = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($srcFile), "__temp_defrag__.wim")
        
        # Önceki temp dosya varsa sil
        if (Test-Path $script:TempDefragFile) {
            Write-Log "Eski temp dosya siliniyor: $($script:TempDefragFile)" -Level "INFO"
            Remove-Item $script:TempDefragFile -Force -ErrorAction SilentlyContinue
        }
        
        # Silme sonrası kalan index listesini al
        $remainingIndexes = @()
        try {
            Import-Module DISM -ErrorAction SilentlyContinue
            $imgs = Get-WindowsImage -ImagePath $srcFile
            $remainingIndexes = $imgs | Select-Object -ExpandProperty ImageIndex
        } catch {
            Write-Log "Index listesi alınamadı: $($_.Exception.Message)" -Level "ERR"
        }
        
        if ($remainingIndexes.Count -eq 0) {
            Show-Alert -Title "Uyarı" -Message "Index'ler silindi fakat defragment yapılamadı (index listesi boş)."
            Load-DeleteIndexList -FilePath $srcFile
            return
        }
        
        Write-Log "Defragment başlatılıyor ($($remainingIndexes.Count) index)..." -Level "INFO"
        Set-Progress -Percent 10 -Message "Defragment başlatılıyor..."
        
        # Her index'i sırayla export et
        $script:DefragJob = Start-Job -ScriptBlock {
            param($srcFile, $tempWim, $indexes)
            $first = $true
            $total = $indexes.Count
            $current = 0
            foreach ($idx in $indexes) {
                $current++
                $args = "/Export-Image /SourceImageFile:`"$srcFile`" /SourceIndex:$idx /DestinationImageFile:`"$tempWim`" /Compress:max"
                Write-Output "[LOG] Export index $idx -> $tempWim ($current/$total)"
                Write-Output "[PROGRESS] $([Math]::Floor(($current / $total) * 80) + 10)"
                $out = & DISM.EXE $args.Split(' ') 2>&1
                $ec  = $LASTEXITCODE
                $out | ForEach-Object { if ($_.Trim()) { Write-Output $_.Trim() } }
                if ($ec -ne 0) { Write-Output "__EXIT__:$ec"; return }
                $first = $false
            }
            Write-Output "__EXIT__:0"
        } -ArgumentList $srcFile, $script:TempDefragFile, $remainingIndexes
        
        # Timer ile takip et
        $script:DefragTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:DefragTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:DefragTimer.Add_Tick({
            if ($script:DefragJob.State -notin @('Completed','Failed','Stopped')) { return }
            $script:DefragTimer.Stop()
            $lines = Receive-Job -Job $script:DefragJob -ErrorAction SilentlyContinue
            Remove-Job -Job $script:DefragJob -Force -ErrorAction SilentlyContinue
            
            # DISM process'lerinin tamamen kapanmasını bekle (dosya kilidinden kurtulmak için)
            Start-Sleep -Seconds 2
            
            # Hala açık DISM process'i var mı kontrol et
            $dismProcesses = Get-Process -Name "DISM" -ErrorAction SilentlyContinue
            if ($dismProcesses) {
                $waitCount = 0
                while ((Get-Process -Name "DISM" -ErrorAction SilentlyContinue) -and $waitCount -lt 10) {
                    Start-Sleep -Seconds 1
                    $waitCount++
                }
                if ($waitCount -ge 10) {
                    Get-Process -Name "DISM" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 1
                }
            }
            
            $exitCode = 0
            foreach ($ln in $lines) {
                if ($ln.StartsWith("[LOG]")) { 
                    # Export detaylarını loglama - gereksiz
                    continue 
                }
                if ($ln.StartsWith("[PROGRESS]")) {
                    $pct = [int]($ln.Substring(11))
                    Set-Progress -Percent $pct -Message "WIM defragment ediliyor..."
                    continue
                }
                if ($ln.StartsWith("__EXIT__:")) { 
                    $exitCode = [int]($ln.Substring(9))
                    continue 
                }
            }
            
            if ($exitCode -eq 0 -and (Test-Path $script:TempDefragFile)) {
                try {
                    # Script scope'tan kaynak dosya yolunu al (TextBox değişebilir)
                    $originalFile = $script:DeleteSourceFile
                    
                    # Dosyaların varlığını kontrol et
                    if (-not (Test-Path $script:TempDefragFile)) {
                        throw "Temp dosya bulunamadı: $($script:TempDefragFile)"
                    }
                    
                    if (-not (Test-Path $originalFile)) {
                        throw "Orijinal dosya bulunamadı: $originalFile"
                    }
                    
                    # Dosya boyutlarını logla
                    $tempSize = (Get-Item $script:TempDefragFile).Length
                    $origSize = (Get-Item $originalFile).Length
                    $savedMB = [Math]::Round(($origSize - $tempSize) / 1MB, 2)
                    Write-Log "WIM optimize edildi: $([Math]::Round($origSize/1MB,2)) MB → $([Math]::Round($tempSize/1MB,2)) MB (Kazanç: $savedMB MB)" -Level "INFO"
                    
                    # Orijinal dosyayı sil ve temp'i taşı
                    Remove-Item -Path $originalFile -Force -ErrorAction Stop
                    Start-Sleep -Milliseconds 500
                    Move-Item -Path $script:TempDefragFile -Destination $originalFile -Force -ErrorAction Stop
                    
                    # Başarı kontrolü
                    if (Test-Path $script:TempDefragFile) {
                        throw "Temp dosya hala mevcut - taşıma başarısız!"
                    }
                    
                    if (-not (Test-Path $originalFile)) {
                        throw "Taşıma sonrası hedef dosya bulunamadı!"
                    }
                    
                    Write-Log "✓ $($script:TotalDeleteCount) index silindi, WIM defragment edildi." -Level "OK"
                    Set-Progress -Percent 100 -Message "Tamamlandı!"
                    
                    # İşlem özeti
                    $summary = "✓ $($script:TotalDeleteCount) index başarıyla silindi`n✓ WIM dosyası defragment edildi`n✓ Dosya boyutu: $savedMB MB azaldı"
                    Show-Alert -Title "İşlem Tamamlandı" -Message $summary
                } catch {
                    Write-Log "Dosya güncellenemedi: $($_.Exception.Message)" -Level "ERR"
                    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERR"
                    
                    # Temp dosyayı temizlemeye çalış
                    if (Test-Path $script:TempDefragFile) {
                        try {
                            Remove-Item $script:TempDefragFile -Force -ErrorAction Stop
                            Write-Log "Temp dosya temizlendi: $($script:TempDefragFile)" -Level "INFO"
                        } catch {
                            Write-Log "Temp dosya silinemedi: $($_.Exception.Message)" -Level "WARN"
                        }
                    }
                    
                    Show-Alert -Title "Hata" -Message "WIM güncellenemedi:`n`n$($_.Exception.Message)`n`nTemp dosya: $($script:TempDefragFile)"
                }
            } else {
                # Temp dosya yoksa veya exitCode başarısız
                if (Test-Path $script:TempDefragFile) {
                    try {
                        Remove-Item $script:TempDefragFile -Force -ErrorAction Stop
                        Write-Log "Temp dosya temizlendi." -Level "INFO"
                    } catch {
                        Write-Log "Temp dosya silinemedi: $($_.Exception.Message)" -Level "WARN"
                    }
                }
                Write-Log "Defragment başarısız (exitCode: $exitCode)." -Level "WARN"
                Show-Alert -Title "Hata" -Message "Defragment işlemi başarısız oldu."
            }
            
            $global:IsBusy = $false
            Set-Progress -Percent 0 -Message "Sistem Hazır."
            Load-DeleteIndexList -FilePath $script:DeleteSourceFile
        })
        $script:DefragTimer.Start()
    }
})

# /Bootable ve /WIMBoot karşılıklı dışlama
$ChkExportBootable.Add_Checked({
    $ChkExportWimBoot.IsChecked = $false
    $ChkExportWimBoot.IsEnabled = $false
})
$ChkExportBootable.Add_Unchecked({
    $ChkExportWimBoot.IsEnabled = $true
})
$ChkExportWimBoot.Add_Checked({
    $ChkExportBootable.IsChecked = $false
    $ChkExportBootable.IsEnabled = $false
})
$ChkExportWimBoot.Add_Unchecked({
    $ChkExportBootable.IsEnabled = $true
})

$BtnExportImage.Add_Click({
    # Yeni ListView kontrolü
    if ($TxtExportIndexSource.Text -eq "") { 
        Show-Alert -Title "Eksik Alan" -Message "Kaynak WIM/ESD seçin."; 
        return 
    }
    if ($TxtExportFileName.Text -eq "") { 
        Show-Alert -Title "Eksik Alan" -Message "Hedef dosyayı seçin (Kaydet butonu)."; 
        return 
    }
    
    # Seçili index'leri al
    $selectedItems = $global:ExportIndexItems | Where-Object { $_.IsSelected }
    if ($selectedItems.Count -eq 0) {
        Show-Alert -Title "Eksik Alan" -Message "En az bir index seçin."
        return
    }
    
    $expCmpr = if ($CmbExportCompression.SelectedItem) { ($CmbExportCompression.SelectedItem).Content } else { "fast" }
    $expDest = $TxtExportFileName.Text.Trim()
    
    # Çift uzantı kontrolü
    $currentExt = [System.IO.Path]::GetExtension($expDest).ToUpper()
    $validExts = @(".WIM", ".ESD", ".SWM")
    if ($validExts -notcontains $currentExt) {
        $expDest += ".wim"
    }
    
    $expSrc  = $TxtExportIndexSource.Text
    $expBoot = ($ChkExportBootable.IsChecked -eq $true)
    $expWimB = ($ChkExportWimBoot.IsChecked  -eq $true)
    $expIntg = ($ChkExportCheckIntegrity.IsChecked -eq $true)

    # /Bootable ve /WIMBoot aynı anda kullanılamaz
    if ($expBoot -and $expWimB) {
        Show-Alert -Title "Geçersiz Seçim" -Message "/Bootable ve /WIMBoot aynı anda kullanılamaz.`n`nLütfen yalnızca birini seçin."
        return
    }
    
    # Çoklu index onay
    if ($selectedItems.Count -gt 1) {
        $indexList = ($selectedItems | ForEach-Object { "#$($_.IndexNumber)" }) -join ", "
        $confirm = Show-Confirm -Title "Çoklu Index Export" `
            -Message "$($selectedItems.Count) index seçildi: $indexList`n`nTümü aynı hedef dosyaya export edilecek.`n`nDevam edilsin mi?" `
            -Icon "📦"
        if (-not $confirm) { return }
    }
    
    # Export parametrelerini script scope'a al (recursive callback'ler için)
    $script:ExportSource = $expSrc
    $script:ExportDest = $expDest
    $script:ExportCompr = $expCmpr
    $script:ExportBootable = $expBoot
    $script:ExportWimBoot = $expWimB
    $script:ExportCheckIntegrity = $expIntg
    
    # Çoklu export için queue oluştur
    $script:ExportQueue = New-Object System.Collections.Queue
    $script:ExportTotalCount = $selectedItems.Count
    foreach ($item in $selectedItems) {
        $script:ExportQueue.Enqueue($item.IndexNumber)
    }
    
    # İlk export'u başlat
    $nextIdx = $script:ExportQueue.Dequeue()
    $expArgs = "/Export-Image /SourceImageFile:`"$($script:ExportSource)`" /SourceIndex:$nextIdx /DestinationImageFile:`"$($script:ExportDest)`" /Compress:$($script:ExportCompr)"
    if ($script:ExportBootable) { $expArgs += " /Bootable" }
    if ($script:ExportWimBoot) { $expArgs += " /WIMBoot" }
    if ($script:ExportCheckIntegrity) { $expArgs += " /CheckIntegrity" }
    Write-Log "DISM $expArgs (İlerleme: $($script:ExportTotalCount - $script:ExportQueue.Count)/$($script:ExportTotalCount))" -Level "RUN"
    Write-Log "Flags → Bootable:$($script:ExportBootable)  WIMBoot:$($script:ExportWimBoot)  CheckIntegrity:$($script:ExportCheckIntegrity)" -Level "INFO"
    $script:PendingExpDest = $script:ExportDest
    
    Start-DismJob -DismArgs $expArgs -StatusMessage "Export (Index $nextIdx)" -OnComplete {
        param($ec)
        if ($ec -ne 0) {
            Show-Alert -Title "Hata" -Message "Index $nextIdx export başarısız oldu."
            return
        }
        
        # Kuyruğa devam et
        if ($script:ExportQueue.Count -gt 0) {
            $nextIdx = $script:ExportQueue.Dequeue()
            $expArgs = "/Export-Image /SourceImageFile:`"$($script:ExportSource)`" /SourceIndex:$nextIdx /DestinationImageFile:`"$($script:ExportDest)`" /Compress:$($script:ExportCompr)"
            if ($script:ExportBootable) { $expArgs += " /Bootable" }
            if ($script:ExportWimBoot) { $expArgs += " /WIMBoot" }
            if ($script:ExportCheckIntegrity) { $expArgs += " /CheckIntegrity" }
            Write-Log "DISM $expArgs (İlerleme: $($script:ExportTotalCount - $script:ExportQueue.Count)/$($script:ExportTotalCount))" -Level "RUN"
            
            Start-DismJob -DismArgs $expArgs -StatusMessage "Export (Index $nextIdx)" -OnComplete $MyInvocation.MyCommand.ScriptBlock -OnCancel {
                # İptal durumunda yarım kalan export dosyasını temizle
                if ($script:PendingExpDest -and (Test-Path $script:PendingExpDest)) {
                    try {
                        Remove-Item -Path $script:PendingExpDest -Force -ErrorAction Stop
                        Write-Log "İptal edildi: Yarım kalan dosya temizlendi ($script:PendingExpDest)" -Level "INFO"
                    } catch {
                        Write-Log "İptal sonrası dosya silinemedi: $($_.Exception.Message)" -Level "WARN"
                    }
                }
            }
            return
        }
        
        # Tüm export'lar tamamlandı
        Show-Alert -Title "Tamamlandı" -Message "$($script:ExportTotalCount) index export edildi:`n$($script:PendingExpDest)"
    } -OnCancel {
        # İptal durumunda yarım kalan export dosyasını temizle
        if ($script:PendingExpDest -and (Test-Path $script:PendingExpDest)) {
            try {
                Remove-Item -Path $script:PendingExpDest -Force -ErrorAction Stop
                Write-Log "İptal edildi: Yarım kalan dosya temizlendi ($script:PendingExpDest)" -Level "INFO"
            } catch {
                Write-Log "İptal sonrası dosya silinemedi: $($_.Exception.Message)" -Level "WARN"
            }
        }
    }
})

# ═══════════════════════════════════════════════════════
# PG_9 : SPLIT MEDIA (SWM)
# ═══════════════════════════════════════════════════════
$TxtSplitSourceWim       = $window.FindName("TxtSplitSourceWim")
$TxtSplitDestDir         = $window.FindName("TxtSplitDestDir")
$TxtSplitSwmName         = $window.FindName("TxtSplitSwmName")
$TxtSplitSize            = $window.FindName("TxtSplitSize")
$ChkSplitCheckIntegrity  = $window.FindName("ChkSplitCheckIntegrity")
$BtnSplitChooseWim       = $window.FindName("BtnSplitChooseWim")
$BtnSplitChooseDir       = $window.FindName("BtnSplitChooseDir")
$BtnSplitImage           = $window.FindName("BtnSplitImage")

$BtnSplitChooseWim.Add_Click({
    $f = Select-File -Filter "WIM Dosyaları (*.wim)|*.wim"
    if ($f -ne "") { $TxtSplitSourceWim.Text = $f }
})
$BtnSplitChooseDir.Add_Click({
    $f = Select-Folder
    if ($f -ne "") { $TxtSplitDestDir.Text = $f }
})

$BtnSplitImage.Add_Click({
    if ($TxtSplitSourceWim.Text -eq "") { Show-Alert -Title "Eksik Alan" -Message "Kaynak WIM seçin."; return }
    if ($TxtSplitDestDir.Text -eq "")   { Show-Alert -Title "Eksik Alan" -Message "Hedef dizin seçin."; return }
    if ($TxtSplitSwmName.Text -eq "")   { Show-Alert -Title "Eksik Alan" -Message "SWM dosya adını girin."; return }
    if (-not ($TxtSplitSize.Text -match "^\d+$") -or [uint64]$TxtSplitSize.Text -eq 0) {
        Show-Alert -Title "Geçersiz Değer" -Message "Dosya boyutu geçerli bir sayı olmalıdır (MB cinsinden, 0'dan büyük)."
        return
    }
    $splSize = [uint64]$TxtSplitSize.Text
    $splSrc  = $TxtSplitSourceWim.Text
    $splIntg = $ChkSplitCheckIntegrity.IsChecked

    # SWM dosya adına .swm uzantısı yoksa otomatik ekle
    $splName = $TxtSplitSwmName.Text
    if (-not $splName.ToLower().EndsWith(".swm")) { $splName += ".swm" }
    $splFile = Join-Path $TxtSplitDestDir.Text $splName

    $splArgs = "/Split-Image /ImageFile:`"$splSrc`" /SWMFile:`"$splFile`" /FileSize:$splSize"
    if ($splIntg) { $splArgs += " /CheckIntegrity" }
    Write-Log "DISM $splArgs" -Level "RUN"
    Start-DismJob -DismArgs $splArgs -StatusMessage "SWM parçalanıyor" -OnComplete {
        param($ec)
        if ($ec -eq 0) { Show-Alert -Title "Tamamlandı" -Message "SWM parçalama tamamlandı.`nHedef: $splFile" }
    }
})

# ═══════════════════════════════════════════════════════
# PG_10 : REGIONAL SETTINGS
# ═══════════════════════════════════════════════════════
$TxtLangCode   = $window.FindName("TxtLangCode")
$TxtTimezone   = $window.FindName("TxtTimezone")
$BtnApplyLang  = $window.FindName("BtnApplyLang")
$BtnGetLangInfo= $window.FindName("BtnGetLangInfo")

$BtnApplyLang.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    $langCode = $TxtLangCode.Text
    $tzName   = $TxtTimezone.Text
    $mntPath  = $global:StrMountedImageLocation
    if ($langCode -ne "") {
        $lArgs = "/Image:`"$mntPath`" /Set-UILang:$langCode"
        Start-DismJob -DismArgs $lArgs -StatusMessage "Dil ayarlanıyor" -OnComplete {
            param($ec)
            if ($tzName -ne "") {
                Start-DismJob -DismArgs "/Image:`"$mntPath`" /Set-TimeZone:`"$tzName`"" -StatusMessage "Zaman dilimi"
            }
        }
    } elseif ($tzName -ne "") {
        Start-DismJob -DismArgs "/Image:`"$mntPath`" /Set-TimeZone:`"$tzName`"" -StatusMessage "Zaman dilimi"
    }
})

$BtnGetLangInfo.Add_Click({
    if (-not (Assert-WimMounted)) { return }
    $lArgs = "/Image:`"$global:StrMountedImageLocation`" /Get-Intl"
    Write-Log "DISM $lArgs" -Level "RUN"
    Start-DismJob -DismArgs $lArgs -StatusMessage "Dil Bilgisi"
})

# ═══════════════════════════════════════════════════════
# PG_11 : FFU STORAGE FLASH
# ═══════════════════════════════════════════════════════
$TxtFfuCapturePhysDrive = $window.FindName("TxtFfuCapturePhysDrive")
$TxtFfuCaptureDest      = $window.FindName("TxtFfuCaptureDest")
$BtnFfuCaptureDest      = $window.FindName("BtnFfuCaptureDest")
$BtnCaptureFfu          = $window.FindName("BtnCaptureFfu")
$TxtFfuApplySource      = $window.FindName("TxtFfuApplySource")
$TxtFfuApplyDrive       = $window.FindName("TxtFfuApplyDrive")
$BtnFfuApplySource      = $window.FindName("BtnFfuApplySource")
$BtnApplyFfu            = $window.FindName("BtnApplyFfu")

$BtnFfuCaptureDest.Add_Click({
    $f = Select-SaveFile -Filter "FFU Dosyaları (*.ffu)|*.ffu" -Title "Hedef FFU Dosyası"
    if ($f -ne "") { $TxtFfuCaptureDest.Text = $f }
})

$BtnCaptureFfu.Add_Click({
    if ($TxtFfuCaptureDest.Text -eq "") { Show-Alert -Title "Eksik Alan" -Message "Hedef FFU dosya yolunu belirtin."; return }
    $ffuDrive = $TxtFfuCapturePhysDrive.Text
    $ffuDest  = $TxtFfuCaptureDest.Text
    $ffuArgs  = "/Capture-Ffu /CaptureDrive:$ffuDrive /ImageFile:`"$ffuDest`" /Name:`"FFU Backup`""
    Write-Log "DISM $ffuArgs" -Level "RUN"
    Start-DismJob -DismArgs $ffuArgs -StatusMessage "FFU yakalanıyor... (Bu işlem uzun sürebilir)"
})

$BtnFfuApplySource.Add_Click({
    $f = Select-File -Filter "FFU Dosyaları (*.ffu)|*.ffu"
    if ($f -ne "") { $TxtFfuApplySource.Text = $f }
})

$BtnApplyFfu.Add_Click({
    if ($TxtFfuApplySource.Text -eq "") { Show-Alert -Title "Eksik Alan" -Message "FFU dosyasını seçin."; return }
    $confirm = Show-Confirm -Title "Tehlikeli İşlem" `
        -Message "UYARI: Bu işlem hedef diskteki TÜM verileri silecektir!`nHedef: $($TxtFfuApplyDrive.Text)`n`nDevam etmek istiyor musunuz?" `
        -Icon "🚨"
    if (-not $confirm) { return }
    $ffuSrc   = $TxtFfuApplySource.Text
    $ffuDrv   = $TxtFfuApplyDrive.Text
    $ffuArgs  = "/Apply-Ffu /ImageFile:`"$ffuSrc`" /ApplyDrive:$ffuDrv"
    Write-Log "DISM $ffuArgs" -Level "RUN"
    Start-DismJob -DismArgs $ffuArgs -StatusMessage "FFU uygulanıyor... (Bu işlem uzun sürebilir)"
})

# ── PENCERE KAPANIRKEN ──
$window.Add_Closing({

    if ($global:WIMMounted) {
        $_.Cancel = $true  # Önce kapatılmayı engelle, dialog sonucuna göre karar ver
        $r = Show-ClosingConfirm `
            -Title "WIM Mount Aktif" `
            -Message "Hâlâ mount edilmiş bir WIM var. Kapatmadan önce unmount edilsin mi?`n`nKaydet = Değişiklikler kaydedilerek unmount`nKaydetme = Değişiklikler atılarak unmount`nKapat = Unmount yapılmadan kapat (WIM bağlı kalır)`nİptal = Pencere açık kalacak"
        if ($r -eq "Save") {
            $_.Cancel = $false
            Dismount-WindowsImage -Path $global:StrMountedImageLocation -Save    -ErrorAction SilentlyContinue | Out-Null
        } elseif ($r -eq "Discard") {
            $_.Cancel = $false
            Dismount-WindowsImage -Path $global:StrMountedImageLocation -Discard -ErrorAction SilentlyContinue | Out-Null
        } elseif ($r -eq "ForceClose") {
            $_.Cancel = $false
            Write-Log "Uygulama unmount yapılmadan kapatıldı (WIM bağlı kaldı: $global:StrMountedImageLocation)" -Level "WARN"
        }
        # "Cancel" durumunda $_.Cancel = $true kalır, pencere kapanmaz
        if ($_.Cancel) { return }
    }

    # Tüm arka plan job'larını durdur
    if ($script:DismTimer)        { $script:DismTimer.Stop() }
    if ($script:VssTimer)         { $script:VssTimer.Stop()  }
    if ($script:VhdTimer)         { $script:VhdTimer.Stop()  }
    if ($script:DeployTimer)      { $script:DeployTimer.Stop() }
    if ($script:DriverListTimer)  { $script:DriverListTimer.Stop() }
    if ($script:MountIndexTimer)  { $script:MountIndexTimer.Stop() }
    if ($script:ApplyIndexTimer)  { $script:ApplyIndexTimer.Stop() }
    if ($script:DefragTimer)      { $script:DefragTimer.Stop() }
    if ($script:DiskRefreshTimer) { $script:DiskRefreshTimer.Stop() }
    if ($script:DeleteIndexCheckTimer) { $script:DeleteIndexCheckTimer.Stop() }
    if ($script:ExportIndexCheckTimer) { $script:ExportIndexCheckTimer.Stop() }
    if ($script:DriverCheckTimer)      { $script:DriverCheckTimer.Stop() }

    Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue

    # Arka planda asılı DISM veya VDS süreçlerini sonlandır
    Get-Process -Name "DISM", "vds" -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.Kill() } catch {}
    }
})

# ── BAŞLANGIÇ ──
Write-Log "WinImage Studio v1.0.1 hazır." -Level "INFO"

# Mevcut mount'ları kontrol et ve UI'ya yükle
try {
    $mounted = Get-WindowsImage -Mounted
    if ($mounted -and $mounted.Count -gt 0) {
        # WinREChk_ kalıntılarını temizle (önceki WinRE kontrol mount'ları)
        foreach ($stale in ($mounted | Where-Object { $_.Path -match 'WinREChk_' })) {
            Write-Log "WinREChk kalıntısı temizleniyor: $($stale.Path)" -Level "WARN"
            & dism /Unmount-Image /MountDir:"$($stale.Path)" /Discard 2>&1 | Out-Null
            Remove-Item $stale.Path -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Gerçek kullanıcı mount'larına bak
        $realMounts = $mounted | Where-Object { $_.Path -notmatch 'WinREChk_' }
        if ($realMounts -and $realMounts.Count -gt 0) {
            $m = $realMounts[0]

            $global:WIMMounted              = $true
            $global:StrMountedImageLocation = $m.Path
            $global:StrWIM                  = $m.ImagePath
            $global:StrIndex                = $m.ImageIndex

            $TxtMountFolder.Text = $m.Path
            $TxtWimFile.Text     = $m.ImagePath

            if (Test-Path $m.ImagePath) {
                Load-MountIndexList -FilePath $m.ImagePath
                
                # İlgili index'i seç ve durum rozetini yenile
                $window.Dispatcher.InvokeAsync([action]{
                    # Load-MountIndexList asenkron olduğu için kısa gecikme ile yenile
                    $script:StartupRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
                    $script:StartupRefreshTimer.Interval = [TimeSpan]::FromMilliseconds(800)
                    $script:StartupRefreshTimer.Add_Tick({
                        $script:StartupRefreshTimer.Stop()
                        for ($i = 0; $i -lt $global:MountIndexItems.Count; $i++) {
                            if ($global:MountIndexItems[$i].IndexNumber -eq $global:StrIndex) {
                                $ListViewMountIndex.SelectedIndex = $i
                                break
                            }
                        }
                        $ListViewMountIndex.Items.Refresh()
                    })
                    $script:StartupRefreshTimer.Start()
                }) | Out-Null
            }

            $mountInfo = Get-MountedImageInfo -MountDir $m.Path
            if ($mountInfo.IsMounted -and $mountInfo.IsReadOnly) {
                $ChkReadOnly.IsChecked = $true
            }

            Set-Status -Text "Mounted (Önceki)" -Color "#F59E0B"
            Write-Log "Önceki mount yüklendi: $($m.ImagePath) [#$($m.ImageIndex)] @ $($m.Path)" -Level "OK"
        }
    }
}
catch {
    Write-Log "Mount kontrolü hatası: $($_.Exception.Message)" -Level "ERR"
}

# ── PENCERE BOYUTU VE KONUMU ──
# WorkArea'ya göre boyutlandır ve ortala (görev çubuğu dahil edilmez)
$window.Add_Loaded({
    $wa = [System.Windows.SystemParameters]::WorkArea

    # ── DPI'ya göre başlangıç boyutunu ölçekle ──────────────────────────────
    $baseW = 1100.0
    $baseH = 800.0

    if ($script:DpiScale -ge 1.5) {
        $baseW = [Math]::Round($baseW / $script:DpiScale * 1.25)
        $baseH = [Math]::Round($baseH / $script:DpiScale * 1.25)
    } elseif ($script:DpiScale -ge 1.25) {
        $baseW = [Math]::Round($baseW / $script:DpiScale * 1.15)
        $baseH = [Math]::Round($baseH / $script:DpiScale * 1.15)
    }

    $targetW = [Math]::Max([Math]::Min($baseW, $wa.Width),  $window.MinWidth)
    $targetH = [Math]::Max([Math]::Min($baseH, $wa.Height), $window.MinHeight)

    $window.Width  = $targetW
    $window.Height = $targetH
    $window.Left   = $wa.Left + ($wa.Width  - $targetW) / 2
    $window.Top    = $wa.Top  + ($wa.Height - $targetH) / 2

    # ── WM_DPICHANGED hook: monitor değişince pencereyi yeniden boyutlandır ──
    try {
        $hwndSrc = [System.Windows.Interop.HwndSource]::FromHwnd(
            (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        )
        if ($null -ne $hwndSrc) {
            $hwndSrc.AddHook([System.Windows.Interop.HwndSourceHook]{
                param($hwnd, $msg, $wParam, $lParam, [ref]$handled)
                # WM_DPICHANGED = 0x02E0
                if ($msg -eq 0x02E0) {
                    try {
                        # lParam = önerilen RECT (left, top, right, bottom) — DIP cinsinden değil piksel
                        $newDpiX = ($wParam.ToInt64() -band 0xFFFF)
                        $newScale = $newDpiX / 96.0

                        $waNew = [System.Windows.SystemParameters]::WorkArea
                        $newW = [Math]::Max([Math]::Min([Math]::Round(1100.0 / $newScale * 1.1), $waNew.Width),  $window.MinWidth)
                        $newH = [Math]::Max([Math]::Min([Math]::Round(800.0  / $newScale * 1.1), $waNew.Height), $window.MinHeight)

                        if (-not $script:IsMaximized) {
                            $window.Width  = $newW
                            $window.Height = $newH
                            $window.Left   = $waNew.Left + ($waNew.Width  - $newW) / 2
                            $window.Top    = $waNew.Top  + ($waNew.Height - $newH) / 2
                        }
                        $script:DpiScale = $newScale
                        Write-Log ("DPI değişti: {0} DPI  Ölçek: {1:P0}" -f [int]$newDpiX, $newScale) -Level "INFO"
                    } catch { }
                    $handled.Value = $false
                }
                return [IntPtr]::Zero
            })
        }
    } catch { }

    # ── Gerçek DPI değerini log'a yaz ────────────────────────────────────────
    try {
        $src = [System.Windows.PresentationSource]::FromVisual($window)
        if ($null -ne $src -and $null -ne $src.CompositionTarget) {
            $dpiX = [int]($src.CompositionTarget.TransformToDevice.M11 * 96)
            $dpiY = [int]($src.CompositionTarget.TransformToDevice.M22 * 96)
            Write-Log ("Ekran DPI: {0}x{1}  Ölçek: {2:P0}" -f $dpiX, $dpiY, ($dpiX / 96.0)) -Level "INFO"
        }
    } catch { }
})

[void]$window.ShowDialog()