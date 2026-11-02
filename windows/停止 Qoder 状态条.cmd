@echo off
rem Qoder Meter - stop only its recorded PID, creation time and exact script identity
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0src\stop.ps1"
endlocal
