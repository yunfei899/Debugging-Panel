@echo off
setlocal
set "SHARED_PANEL_SCRIPT=%~dp0Tools\SharedDebugPanel.ps1"
set "SHARED_PROJECT_ROOT=%~dp0."
start "" powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -Command "try { & $env:SHARED_PANEL_SCRIPT -ProjectRoot $env:SHARED_PROJECT_ROOT } catch { Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show($_.Exception.ToString(), 'Shared debug panel startup failed') | Out-Null; exit 1 }"
