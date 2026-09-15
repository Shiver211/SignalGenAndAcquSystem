@echo off
setlocal

if not "%~1"=="" goto :run_with_arguments

:menu
cls
echo ========================================
echo FPGA Build and Program
echo ========================================
echo [1] Build and program
echo [2] Build only
echo [3] Program only
echo [4] Exit
echo.
choice /C 1234 /N /M "Select mode [1-4]: "
if errorlevel 4 exit /b 0
if errorlevel 3 goto :program_only
if errorlevel 2 goto :build_only
goto :build_and_program

:program_only
set "arguments=-ProgramOnly"
goto :run

:build_only
set "arguments=-SkipProgram"
goto :run

:build_and_program
set "arguments="
goto :run

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fpga\build_and_program.ps1" %arguments%
set "exit_code=%ERRORLEVEL%"

echo.
if "%exit_code%"=="0" (
    echo Operation completed successfully.
) else (
    echo Build or programming failed, exit code: %exit_code%
)
pause
exit /b %exit_code%

:run_with_arguments
set "arguments=%*"
goto :run
