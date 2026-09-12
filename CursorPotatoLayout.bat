@echo off
:: Cursor Agent CLI, PotatoSandwich x3. Pass -DryRun to inspect the wt.exe command.
powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0CursorPotatoLayout.ps1" %*
