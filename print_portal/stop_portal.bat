@echo off
echo Stopping EKK Print Portal...
set FOUND=0
for /f "tokens=5" %%a in ('netstat -aon ^| find ":5000" ^| find "LISTENING"') do (
    echo Killing process PID %%a
    taskkill /F /PID %%a >nul 2>&1
    set FOUND=1
)
if "%FOUND%"=="0" (
    echo Portal was not running.
) else (
    echo [OK] Portal stopped.
)
pause
