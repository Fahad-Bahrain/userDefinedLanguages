@echo off
:: Run this ONCE as Administrator to register auto-start on every system restart.
echo ======================================================
echo   EKK Print Portal - Register Auto-Start Task
echo ======================================================
echo.

:: Find Python path
for /f "delims=" %%i in ('where python 2^>nul') do set PYPATH=%%i
if "%PYPATH%"=="" (
    echo ERROR: Python not found in PATH.
    pause
    exit /b 1
)
echo   Python found: %PYPATH%

:: Remove existing task if present
schtasks /delete /tn "EKK Print Portal" /f >nul 2>&1

:: Register task: runs at system startup with 1-minute delay (lets network come up)
schtasks /create /f ^
    /tn "EKK Print Portal" ^
    /sc ONSTART ^
    /delay 0001:00 ^
    /ru SYSTEM ^
    /rl HIGHEST ^
    /tr "\"%PYPATH%\" C:\AIX_Monitor\print_portal\print_portal\app.py >> C:\AIX_Monitor\print_portal\portal.log 2>&1"

if errorlevel 1 (
    echo.
    echo FAILED to register startup task.
) else (
    echo.
    echo [OK] Auto-start task registered!
    echo      Portal will start automatically 1 minute after every system restart.
    echo.
    echo      Verify:
    echo        schtasks /query /tn "EKK Print Portal"
)
echo.
pause
