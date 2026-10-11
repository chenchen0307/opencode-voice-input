@echo off
rem 一键启用管理员模式：创建计划任务（会弹出 UAC，请点“是”）
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0install-tasks.ps1','-InstallDir','E:\Apps\opencode-voice','-UserName','%USERDOMAIN%\%USERNAME%','-Restart' -Wait"
echo.
echo 完成。可按任意键关闭。
pause >nul
