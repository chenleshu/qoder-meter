@echo off
rem Qoder Meter - explicit manual start, independent of the start-with-Qoder option
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%~dp0launch-hidden.vbs" (
  start "" "%SystemRoot%\System32\wscript.exe" "%~dp0launch-hidden.vbs"
) else (
  start "" /b "%PS%" -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0src\meter.ps1"
)
endlocal
