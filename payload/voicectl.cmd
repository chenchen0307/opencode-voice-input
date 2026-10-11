@echo off
rem OpenCode voice server control wrapper
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0voicectl.ps1" %*
