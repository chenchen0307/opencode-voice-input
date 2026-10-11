# 需要管理员权限：创建计划任务（登录触发，热键任务以最高权限运行）
param(
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$UserName,
    [string]$ServerTask = 'OpenCodeVoiceServer',
    [string]$HotkeyTask = 'OpenCodeVoiceHotkey',
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'
Import-Module ScheduledTasks -ErrorAction Stop

$pythonw = Join-Path $InstallDir '.venv\Scripts\pythonw.exe'
$server = Join-Path $InstallDir 'voice_server.py'
$ahk = Join-Path $InstallDir 'bin\ahk\AutoHotkey64.exe'
$hotkey = Join-Path $InstallDir 'voice.ahk'

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable `
    -RestartCount 5 -RestartInterval (New-TimeSpan -Seconds 30)

# ---- 转写服务：普通权限 ----
if ((Test-Path $pythonw) -and (Test-Path $server)) {
    $action = New-ScheduledTaskAction -Execute $pythonw -Argument "`"$server`"" -WorkingDirectory $InstallDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserName
    $principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $ServerTask -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force | Out-Null
    Write-Host "  已创建计划任务: $ServerTask (普通权限)"
} else {
    Write-Warning "  跳过 $ServerTask：缺少 pythonw 或 voice_server.py"
}

# ---- 热键助手：最高权限（兼容管理员身份运行的 OpenCode） ----
if ((Test-Path $ahk) -and (Test-Path $hotkey)) {
    $action = New-ScheduledTaskAction -Execute $ahk -Argument "`"$hotkey`"" -WorkingDirectory $InstallDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserName
    $principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $HotkeyTask -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force | Out-Null
    Write-Host "  已创建计划任务: $HotkeyTask (最高权限)"
} else {
    Write-Warning "  跳过 $HotkeyTask：缺少 AutoHotkey 或 voice.ahk"
}

# ---- 清理旧的启动文件夹快捷方式，避免重复启动 ----
$startup = [Environment]::GetFolderPath('Startup')
foreach ($name in 'OpenCodeVoiceServer.lnk', 'OpenCodeVoiceHotkey.lnk') {
    $file = Join-Path $startup $name
    if (Test-Path $file) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
        Write-Host "  已移除旧快捷方式: $name"
    }
}

# ---- 立即用计划任务重启，确保以新权限运行 ----
if ($Restart) {
    Write-Host '  正在停止当前实例 ...'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('python.exe', 'pythonw.exe') -and $_.CommandLine -like '*voice_server.py*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-Process AutoHotkey64 -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "$InstallDir*" } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    foreach ($task in $ServerTask, $HotkeyTask) {
        if (schtasks /query /tn $task 2>$null) {
            schtasks /run /tn $task 2>$null | Out-Null
            Write-Host "  已启动任务: $task"
        }
    }
}
