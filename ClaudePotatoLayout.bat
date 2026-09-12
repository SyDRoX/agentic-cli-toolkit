@echo off
:: ClaudePotatoLayout.bat - PotatoSandwich x3 (primary + repos2 + repos3)
:: Right-click and "Pin to taskbar", or pass -DryRun to print the wt.exe command.
powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ClaudePotatoLayout.ps1" %*
