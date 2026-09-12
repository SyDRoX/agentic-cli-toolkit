@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude\hooks\claude-notify\notify.ps1" attention
