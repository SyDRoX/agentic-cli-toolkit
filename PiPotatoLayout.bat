@echo off
:: Pi CLI (tencent/hy4-preview @ 256k), PotatoSandwich x3. Pass -DryRun to inspect the wt.exe command.
powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0PiPotatoLayout.ps1" %*
