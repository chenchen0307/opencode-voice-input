#Requires -Version 5.1
<#
OpenCode 语音输入 自检脚本

用法：
    powershell -ExecutionPolicy Bypass -File selftest.ps1
逐项检查：文件、服务、麦克风、转写链路、预览链路、助手进程、计划任务、插件。
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'E:\Apps\opencode-voice',
    [int]$Port = 0
)

$ErrorActionPreference = 'Continue'
$voice = $InstallDir
$ini = Join-Path $voice 'voice.config.ini'
if ($Port -le 0) {
    $Port = 17860
    if (Test-Path $ini) {
        $m = Select-String -Path $ini -Pattern '^\s*port\s*=\s*(\d+)' | Select-Object -First 1
        if ($m) { $Port = [int]$m.Matches[0].Groups[1].Value }
    }
}
$base = "http://127.0.0.1:$Port"
$pass = 0
$fail = 0
$warn = 0

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Host ("  [PASS] {0} {1}" -f $name, $detail) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  [FAIL] {0} {1}" -f $name, $detail) -ForegroundColor Red }
}
function Warn([string]$name, [string]$detail = '') {
    $script:warn++; Write-Host ("  [WARN] {0} {1}" -f $name, $detail) -ForegroundColor Yellow
}

Write-Host '=========================================' -ForegroundColor White
Write-Host ' OpenCode 语音输入 自检' -ForegroundColor White
Write-Host '=========================================' -ForegroundColor White
Write-Host "安装目录: $voice"
Write-Host "服务地址: $base"

# 1. 文件
Write-Host "`n[1] 文件完整性" -ForegroundColor Cyan
Check 'voice_server.py' (Test-Path (Join-Path $voice 'voice_server.py'))
Check 'voice.ahk' (Test-Path (Join-Path $voice 'voice.ahk'))
Check 'voice.config.ini' (Test-Path $ini)
Check 'AutoHotkey64.exe' (Test-Path (Join-Path $voice 'bin\ahk\AutoHotkey64.exe'))
Check 'Python venv' (Test-Path (Join-Path $voice '.venv\Scripts\python.exe'))
Check '模型目录' (Test-Path (Join-Path $voice 'models\Qwen3-ASR-1.7B'))
Check '测试音频' (Test-Path (Join-Path $voice 'sample_zh.wav'))

# 2. 服务健康
Write-Host "`n[2] 服务健康" -ForegroundColor Cyan
$health = $null
try { $health = Invoke-RestMethod -Uri "$base/health" -TimeoutSec 3 } catch { }
Check 'HTTP 可访问' ($null -ne $health)
if ($health) {
    Check '模型已就绪' ([bool]$health.ready)
    Check '麦克风有音频数据' ([bool]$health.audio_flowing) ("(frames=$($health.frames))")
    if ($health.mic_error) { Warn '麦克风异常' $health.mic_error }
    if ($health.last_error) { Warn '最近一次转写错误' $health.last_error }
    if ($health.recoveries -gt 0) { Warn "采集流已自动恢复 $($health.recoveries) 次" }
}

# 3. 麦克风设备
Write-Host "`n[3] 麦克风设备" -ForegroundColor Cyan
try {
    $dev = Invoke-RestMethod -Uri "$base/devices" -TimeoutSec 5
    Check '可枚举输入设备' ($dev.devices.Count -gt 0) ("(共 $($dev.devices.Count) 个)")
} catch { Check '可枚举输入设备' $false }

# 4. 转写链路（注入样例音频）
Write-Host "`n[4] 转写链路（注入样例音频）" -ForegroundColor Cyan
$sample = Join-Path $voice 'sample_zh.wav'
if ((Test-Path $sample) -and $health -and $health.ready) {
    try {
        Invoke-WebRequest -Method Post -Uri "$base/inject" -Body $sample -ContentType 'text/plain; charset=utf-8' -UseBasicParsing -TimeoutSec 10 | Out-Null
        Invoke-WebRequest -Method Post -Uri "$base/start" -UseBasicParsing -TimeoutSec 10 | Out-Null
        $r = Invoke-WebRequest -Method Post -Uri "$base/stop" -UseBasicParsing -TimeoutSec 120
        $text = $r.Content
        Check '转写返回非空文本' ($text.Trim().Length -gt 0) ("「$text」")
    } catch {
        Check '转写链路' $false $_.Exception.Message
    }
} else {
    Warn '跳过转写链路测试' '服务未就绪或缺少 sample_zh.wav'
}

# 5. 预览链路
Write-Host "`n[5] 实时预览链路" -ForegroundColor Cyan
if ($health -and $health.ready) {
    try {
        $p = Invoke-WebRequest -Uri "$base/partial.txt" -UseBasicParsing -TimeoutSec 5
        $a = Invoke-WebRequest -Uri "$base/audio.txt" -UseBasicParsing -TimeoutSec 5
        $pj = Invoke-RestMethod -Uri "$base/partial" -TimeoutSec 5
        Check '/partial.txt 可访问' ($p.StatusCode -eq 200)
        Check '/audio.txt 可访问' ($a.StatusCode -eq 200)
        Check '/partial 接口正常' ([bool]$pj.ok)
        if ($health.recording) { Check '预览线程运行中' ([bool]$health.partial) }
    } catch { Check '预览链路' $false $_.Exception.Message }
} else { Warn '跳过预览测试' '服务未就绪' }

# 6. 助手进程
Write-Host "`n[6] 长按回车助手" -ForegroundColor Cyan
$ahk = Get-Process AutoHotkey64 -ErrorAction SilentlyContinue
Check 'AutoHotkey 进程运行中' ($null -ne $ahk)
if ($ahk) { Write-Host ("        pid={0} 启动于 {1}" -f $ahk.Id, $ahk.StartTime) }
if ($health) {
    Check '麦克风输入电平可读' ($null -ne $health.input_db) ("(当前 $($health.input_db) dBFS；说话时应在 -40 以上)")
    if ($health.input_db -ne $null -and $health.input_db -lt -60) {
        Warn '当前输入电平很低' '（安静时正常；若说话时仍低于 -50，请调高系统输入音量或更换麦克风）'
    }
}
$statePath = Join-Path $voice 'voice.state'
Check '状态文件 voice.state' (Test-Path $statePath)
if (Test-Path $statePath) {
    $applied = (Select-String -Path $statePath -Pattern '^applied=(.+)$' | Select-Object -First 1).Matches[0].Groups[1].Value
    $age = ((Get-Date) - (Get-Item $statePath).LastWriteTime).TotalSeconds
    Check '助手心跳正常（近 3 分钟内有响应）' ($age -lt 180) ("(上次 $applied, ${age:N0}s 前)")
    $tr = (Select-String -Path $statePath -Pattern '^trigger=(.+)$' | Select-Object -First 1).Matches[0].Groups[1].Value
    Write-Host ("        当前触发键: {0}" -f $tr)
}

# 7. 计划任务
Write-Host "`n[7] 计划任务（管理员模式）" -ForegroundColor Cyan
foreach ($t in 'OpenCodeVoiceServer', 'OpenCodeVoiceHotkey') {
    $task = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    if ($task) {
        $level = $task.Principal.RunLevel
        Check $t $true ("(RunLevel=$level, State=$($task.State))")
    } else {
        Warn "$t 不存在" '（普通权限模式，OpenCode 以管理员运行时会失效）'
    }
}

# 8. 插件
Write-Host "`n[8] OpenCode 插件" -ForegroundColor Cyan
$plugin = Join-Path $env:USERPROFILE '.config\opencode\plugins\opencode-voice'
Check '插件目录' (Test-Path (Join-Path $plugin 'tui.tsx'))
Check '插件配置 config.json' (Test-Path (Join-Path $plugin 'config.json'))

# 汇总
Write-Host "`n=========================================" -ForegroundColor White
Write-Host (" 通过 {0}  失败 {1}  警告 {2}" -f $pass, $fail, $warn) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Write-Host '=========================================' -ForegroundColor White
if ($fail -gt 0) { exit 1 } else { exit 0 }
