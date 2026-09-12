@echo off
:: ClaudeBothLayout.bat - both games x3 in one window
:: Right-click and "Pin to taskbar", or pass -DryRun to print the wt.exe command.
powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ClaudeBothLayout.ps1" %*
