@echo off
start "Monitor PC" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
