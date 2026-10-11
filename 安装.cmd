@echo off
chcp 65001 >nul 2>nul
title OpenCode 语音输入 - 安装程序
setlocal

echo.
echo   ============================================================
echo      OpenCode 语音输入   安装程序
echo   ============================================================
echo.
echo   即将安装：
echo     [1] Python 运行环境与语音识别依赖（约 2.6GB）
echo     [2] 离线语音模型 Qwen3-ASR-1.7B（约 4.7GB，安装时自动下载）
echo     [3] AutoHotkey v2 与 OpenCode 插件
echo     [4] 开机自启（可选：计划任务，兼容以管理员运行的程序）
echo.
echo   需要联网，整个过程约 10-30 分钟（取决于网速）。
echo   安装完成后，在任意软件输入框按住回车即可说话输入。
echo.
pause

powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0install.ps1' -PassThru -Wait; exit $p.ExitCode"
set RC=%ERRORLEVEL%

echo.
if "%RC%"=="0" (
  echo   安装流程已结束。若显示为“安装完成”，即可开始使用。
) else (
  echo   安装未正常完成（退出码 %RC%），请查看上方输出或 install 日志。
)
echo   提示：托盘 H 图标右键可打开“设置…”。
echo.
pause
