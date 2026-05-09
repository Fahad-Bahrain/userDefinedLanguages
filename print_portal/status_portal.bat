@echo off
echo ======================================
echo   EKK Print Portal - Status Check
echo ======================================
netstat -aon | find ":5000" | find "LISTENING" >nul 2>&1
if errorlevel 1 (
    echo   Status  : STOPPED
    echo   URL     : http://localhost:5000  (not accessible)
) else (
    echo   Status  : RUNNING
    echo   URL     : http://localhost:5000
    for /f "tokens=5" %%a in ('netstat -aon ^| find ":5000" ^| find "LISTENING"') do (
        echo   PID     : %%a
    )
)
echo ======================================
pause
