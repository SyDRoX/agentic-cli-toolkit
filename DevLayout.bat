@echo off
:: DevLayout.bat - launcher wrapper for taskbar pinning / hotkey
:: Right-click and "Pin to taskbar", or run Setup-DevLayoutShortcut.ps1 for Ctrl+Alt+D
powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0DevLayout.ps1" %*
