@echo off
cd /d "C:\AIX_Monitor\print_portal\print_portal"
echo Starting EKK Print Portal...
start "" /b python app.py > "C:\AIX_Monitor\print_portal\portal.log" 2>&1
timeout /t 3 /nobreak >nul
netstat -aon | find ":5000" | find "LISTENING" >nul 2>&1
if errorlevel 1 (
    echo FAILED to start. Check C:\AIX_Monitor\print_portal\portal.log
) else (
    echo [OK] Portal is RUNNING at http://localhost:5000
)
pause
