@echo off
title EKK Oracle Print Portal

echo =====================================================
echo   EKK Oracle Print Portal
echo =====================================================
echo.

:: Change to this script's directory (C:\AIX_Monitor\print_portal\)
cd /d "%~dp0"

:: Check Python is available
python --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Python not found. Install Python 3.10+ and try again.
    pause
    exit /b 1
)

:: Install requirements if needed
pip show flask >nul 2>&1
if errorlevel 1 (
    echo Installing required packages...
    pip install -r "%~dp0requirements.txt"
)

echo.
echo  Excel file  : C:\AIX_Monitor\Oracle_printers.xlsx
echo  Open in browser: http://localhost:5000
echo  Press Ctrl+C to stop.
echo.

python "%~dp0app.py"
pause
