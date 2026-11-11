@echo off
rem Bam dup file nay de chay kiem tra. Tu xin quyen Admin.
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Dang xin quyen Admin...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check.ps1" %*
echo.
pause
