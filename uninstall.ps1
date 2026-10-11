#Requires -Version 5.1
<#
OpenCode 语音输入 卸载器

用法：
    powershell -ExecutionPolicy Bypass -File uninstall.ps1
可选参数：
    -InstallDir <路径>   默认 %USERPROFILE%\.config\opencode\voice
    -KeepData            保留 .venv 与 models（便于快速重装）
    -KeepTasks           不删除计划任务
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:USERPROFILE\.config\opencode\voice",
    [switch]$KeepData,
    [switch]$KeepTasks
)

$ErrorActionPreference = 'Stop'
$configRoot = Join-Path $env:USERPROFILE '.config\opencode'
$pluginDir = Join-Path $configRoot 'plugins\opencode-voice'
$serverTask = 'OpenCodeVoiceServer'
$hotkeyTask = 'OpenCodeVoiceHotkey'

function Say([string]$msg, [string]$color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Ok([string]$msg) { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn([string]$msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }

Say 'OpenCode 语音输入 卸载' 'White'

# 1. 停止进程
Say '停止进程 ...'
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @('python.exe', 'pythonw.exe') -and $_.CommandLine -like '*voice_server.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process AutoHotkey64 -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$InstallDir*" } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Ok '已停止'

# 2. 删除计划任务
if (-not $KeepTasks) {
    Say '删除计划任务 ...'
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    foreach ($task in $serverTask, $hotkeyTask) {
        if (-not (schtasks /query /tn $task 2>$null)) { continue }
        if ($isAdmin) {
            schtasks /delete /tn $task /f 2>$null | Out-Null
        } else {
            try {
                Start-Process -FilePath 'schtasks.exe' -ArgumentList @('/delete', '/tn', $task, '/f') -Verb RunAs -Wait -WindowStyle Hidden
            } catch {
                Warn "删除任务 $task 需要管理员权限，已跳过"
                continue
            }
        }
        Ok "已删除任务: $task"
    }
}

# 3. 删除启动文件夹快捷方式
Say '删除启动快捷方式 ...'
$startup = [Environment]::GetFolderPath('Startup')
foreach ($name in 'OpenCodeVoiceServer.lnk', 'OpenCodeVoiceHotkey.lnk', 'OpenCode 语音输入.lnk') {
    $file = Join-Path $startup $name
    if (Test-Path $file) { Remove-Item $file -Force -ErrorAction SilentlyContinue; Ok "已删除: $name" }
}
$desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'OpenCode 语音输入.lnk'
if (Test-Path $desktopLnk) { Remove-Item $desktopLnk -Force -ErrorAction SilentlyContinue; Ok '已删除桌面快捷方式' }

# 4. 删除插件
Say '删除 OpenCode 插件 ...'
if (Test-Path $pluginDir) {
    Remove-Item $pluginDir -Recurse -Force -ErrorAction SilentlyContinue
    Ok "已删除: $pluginDir"
} else {
    Ok '插件目录不存在，跳过'
}

# 5. 删除安装目录
Say '删除安装文件 ...'
if (-not (Test-Path $InstallDir)) {
    Ok '安装目录不存在，跳过'
} elseif ($KeepData) {
    Get-ChildItem $InstallDir -Force |
        Where-Object { $_.Name -notin @('.venv', 'models') } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Ok "已保留 .venv 与 models: $InstallDir"
} else {
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Ok "已删除: $InstallDir"
}

Write-Host ''
Say '卸载完成。' 'Green'
Say '提示：如果之前把插件路径写进了 cli.json，可手动移除其中的 opencode-voice 条目。'
