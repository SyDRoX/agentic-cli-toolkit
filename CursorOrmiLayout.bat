@echo off
:: Cursor Agent CLI, ormi-unity x3. Pass -DryRun to inspect the wt.exe command.
powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0CursorOrmiLayout.ps1" %*
