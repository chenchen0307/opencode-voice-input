param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status', 'log', 'devices', 'config')]
    [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'
$voice = $PSScriptRoot
$pythonw = Join-Path $voice '.venv\Scripts\pythonw.exe'
$server = Join-Path $voice 'voice_server.py'
$log = Join-Path $voice 'voice_server.log'
$ini = Join-Path $voice 'voice.config.ini'

# 端口从配置文件读取
$port = 17860
if (Test-Path $ini) {
    $m = Select-String -Path $ini -Pattern '^\s*port\s*=\s*(\d+)' | Select-Object -First 1
    if ($m) { $port = [int]$m.Matches[0].Groups[1].Value }
}
$url = "http://127.0.0.1:$port"

function Get-VoiceProcess {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('python.exe', 'pythonw.exe') -and $_.CommandLine -like "*voice_server.py*" }
}

function Test-Health {
    try { return Invoke-RestMethod -Uri "$url/health" -TimeoutSec 2 } catch { return $null }
}

function Start-VoiceServer {
    if (Test-Health) { Write-Host '服务已在运行。' -ForegroundColor Green; return }
    if (-not (Test-Path $pythonw)) { throw "找不到 pythonw: $pythonw" }
    Start-Process -FilePath $pythonw -ArgumentList "`"$server`"" -WorkingDirectory $voice -WindowStyle Hidden
    Write-Host '正在启动语音服务（首次需加载模型，约 10-60 秒）...'
    for ($i = 0; $i -lt 180; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Health) { Write-Host "服务已就绪: $url/health" -ForegroundColor Green; return }
    }
    throw "启动超时，请查看日志: $log"
}

function Stop-VoiceServer {
    $procs = Get-VoiceProcess
    if (-not $procs) { Write-Host '服务未运行。'; return }
    $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Write-Host '已停止语音服务。' -ForegroundColor Yellow
}

switch ($Action) {
    'start'   { Start-VoiceServer }
    'stop'    { Stop-VoiceServer }
    'restart' { Stop-VoiceServer; Start-Sleep -Seconds 1; Start-VoiceServer }
    'status'  {
        $h = Test-Health
        if ($h) {
            Write-Host "运行中  ready=$($h.ready)  recording=$($h.recording)  device=$($h.device)  rate=$($h.rate)  port=$port  音频数据=$($h.audio_flowing)" -ForegroundColor Green
            if (-not $h.audio_flowing) { Write-Host '  [!] 最近 2 秒没有采集到音频：检查麦克风是否被占用/断连，或重启音频服务/重插设备' -ForegroundColor Yellow }
        } else {
            Write-Host "未运行 (port=$port)" -ForegroundColor Red
            if (Get-VoiceProcess) { Write-Host '（进程存在但端口无响应，可能仍在加载模型）' }
        }
    }
    'devices' {
        (Invoke-RestMethod -Uri "$url/devices" -TimeoutSec 5).devices |
            ForEach-Object { "[$($_.index)] $($_.name)  (channels=$($_.channels))" }
    }
    'config' {
        $c = Invoke-RestMethod -Uri "$url/config" -TimeoutSec 5
        $c | ConvertTo-Json -Depth 6
    }
    'log' {
        if (Test-Path $log) { Get-Content $log -Tail 40 -Encoding UTF8 } else { Write-Host '暂无日志。' }
    }
}
