@echo off
REM Compile save-hwnd.exe from SaveHwnd.cs using .NET Framework 4 csc.exe
REM Run from the repo root: build.cmd

set CSC=C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe
set WPF=C:\Windows\Microsoft.NET\Framework64\v4.0.30319\WPF

if not exist "%CSC%" (
    echo ERROR: .NET Framework 4 csc.exe not found.
    echo Expected at: %CSC%
    exit /b 1
)

echo Compiling save-hwnd.exe...
"%CSC%" -nologo -optimize+ -out:save-hwnd.exe SaveHwnd.cs -r:"%WPF%\UIAutomationClient.dll" -r:"%WPF%\UIAutomationTypes.dll" -r:System.Management.dll

if %ERRORLEVEL% EQU 0 (
    echo Build successful: save-hwnd.exe
) else (
    echo Build FAILED.
    exit /b 1
)
