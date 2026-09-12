@echo off
:: Pi CLI (tencent/hy4-preview @ 256k), ormi-unity x3. Pass -DryRun to inspect the wt.exe command.
powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0PiOrmiLayout.ps1" %*
