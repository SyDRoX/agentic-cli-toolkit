@echo off
:: Cursor Agent CLI, both games x3. Pass -DryRun to inspect the wt.exe command.
powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0CursorBothLayout.ps1" %*
