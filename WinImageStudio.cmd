@echo off
setlocal EnableExtensions DisableDelayedExpansion

:: ── WinImageStudio v1.0.1 Launcher ──────────────────────────────────────────
set "SCRIPT_DIR=%~dp0"
set "PS_FILE=%SCRIPT_DIR%WinImageStudio.ps1"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

:: ── PS1 dosyasi var mi ────────────────────────────────────────────────────────
if not exist "%PS_FILE%" (
    echo HATA: WinImageStudio.ps1 bulunamadi.
    echo Beklenen konum: %PS_FILE%
    pause
    exit /b 1
)

:: ── Yonetici yetkisi kontrolu ─────────────────────────────────────────────────
icacls "%SystemRoot%\System32\config\system" >nul 2>&1
if %errorlevel% NEQ 0 (
    "%PS_EXE%" -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
    exit /b 0
)

:: ── Per-Monitor DPI Awareness'i etkinlestir (Windows 10+) ────────────────────
:: Bu olmadan WPF %125/%150 ölceklendirmede bulanik render eder.
:: manifestin olmadigi powershell.exe icin registry veya API uzerinden ayarla.
set "DPI_KEY=HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"
reg query "%DPI_KEY%" /v "%PS_EXE%" >nul 2>&1
if %errorlevel% NEQ 0 (
    reg add "%DPI_KEY%" /v "%PS_EXE%" /t REG_SZ /d "~ PERMONITORV2" /f >nul 2>&1
)

:: ── WinImageStudio'yu calistir ───────────────────────────────────────────────
"%PS_EXE%" -NoProfile -NonInteractive -WindowStyle Hidden ^
    -ExecutionPolicy Bypass ^
    -File "%PS_FILE%"

set "PS_EXIT=%errorlevel%"

:: Hata durumunda registry kaydini temizle (bir sonraki acilista tekrar denensin)
if %PS_EXIT% NEQ 0 (
    echo.
    echo HATA: WinImageStudio beklenmedik sekilde sonlandi. (Cikis kodu: %PS_EXIT%^)
    echo PS1 dosyasi: %PS_FILE%
    pause
    exit /b %PS_EXIT%
)

endlocal
exit /b 0