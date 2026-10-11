#Requires -Version 5.1
<#
OpenCode 语音输入 安装器

用法（普通权限运行即可，创建计划任务时会请求一次管理员授权）：
    powershell -ExecutionPolicy Bypass -File install.ps1
可选参数：
    -InstallDir <路径>   默认 %USERPROFILE%\.config\opencode\voice
    -Port <端口>         默认 17860
    -Model <模型ID>      默认 Qwen/Qwen3-ASR-1.7B
    -SkipModel           跳过模型下载
    -NoTasks             不创建计划任务（改用启动文件夹快捷方式）
    -NoStart             安装后不立即启动
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:USERPROFILE\.config\opencode\voice",
    [string]$Model = 'Qwen/Qwen3-ASR-1.7B',
    [int]$Port = 17860,
    [switch]$SkipModel,
    [switch]$NoTasks,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$payload = Join-Path $root 'payload'
$configRoot = Join-Path $env:USERPROFILE '.config\opencode'
$pluginDir = Join-Path $configRoot 'plugins\opencode-voice'
$userName = "$env:USERDOMAIN\$env:USERNAME"
$serverTask = 'OpenCodeVoiceServer'
$hotkeyTask = 'OpenCodeVoiceHotkey'

function Say([string]$msg, [string]$color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Step([string]$msg) { Write-Host "`n== $msg ==" -ForegroundColor Cyan }
function Ok([string]$msg) { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Info([string]$msg) { Write-Host "  $msg" }
function Warn([string]$msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }

function New-StartupShortcut([string]$name, [string]$target, [string]$arguments) {
    $startup = [Environment]::GetFolderPath('Startup')
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut((Join-Path $startup $name))
    $sc.TargetPath = $target
    $sc.Arguments = $arguments
    $sc.WorkingDirectory = $InstallDir
    $sc.WindowStyle = 7
    $sc.Description = 'OpenCode 语音输入'
    $sc.Save()
}

# 生成极简麦克风托盘图标（accent 蓝，深浅任务栏都可见）
function New-VoiceIcon([string]$Path) {
    if (Test-Path $Path) { return }
    Add-Type -AssemblyName System.Drawing
    $size = 32
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $color = [System.Drawing.Color]::FromArgb(255, 0, 113, 227)
    $brush = New-Object System.Drawing.SolidBrush($color)
    # 麦克风主体（胶囊）
    $g.FillEllipse($brush, 11, 3, 10, 10)
    $g.FillRectangle($brush, 11, 8, 10, 8)
    $g.FillEllipse($brush, 11, 11, 10, 10)
    $pen = New-Object System.Drawing.Pen($color, 2)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    # 支架
    $g.DrawArc($pen, 7, 8, 18, 16, 0, 180)
    $g.DrawLine($pen, 16, 24, 16, 28)
    $g.DrawLine($pen, 11, 28, 21, 28)
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $ms.ToArray()
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]1)
    $bw.Write([Byte]32); $bw.Write([Byte]32); $bw.Write([Byte]0); $bw.Write([Byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$png.Length); $bw.Write([UInt32]22)
    $bw.Write($png)
    $bw.Close(); $fs.Close()
    $g.Dispose(); $bmp.Dispose()
}

# 用默认模板刷新配置：保留已有取值、补充新选项；-Force 里的键强制覆盖（配置版本升级用）
function Merge-Ini {
    param(
        [string]$TemplatePath,
        [string]$TargetPath,
        [hashtable]$Overrides = @{},
        [hashtable]$Force = @{}
    )
    $existing = @{}
    if (Test-Path $TargetPath) {
        $section = ''
        foreach ($line in (Get-Content $TargetPath -Encoding UTF8)) {
            if ($line -match '^\s*\[(.+)\]\s*$') { $section = $matches[1].Trim().ToLower(); continue }
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
                $existing["$section/$($matches[1].Trim().ToLower())"] = $matches[2].Trim()
            }
        }
    }
    $out = New-Object System.Collections.Generic.List[string]
    $section = ''
    foreach ($line in (Get-Content $TemplatePath -Encoding UTF8)) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            $section = $matches[1].Trim().ToLower()
            $out.Add($line)
            continue
        }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $key = $matches[1].Trim()
            $lookup = "$section/$($key.ToLower())"
            if ($Force.ContainsKey($lookup)) { $value = $Force[$lookup] }
            elseif ($existing.ContainsKey($lookup)) { $value = $existing[$lookup] }
            elseif ($Overrides.ContainsKey($lookup)) { $value = $Overrides[$lookup] }
            else { $value = $matches[2] }
            $out.Add("$key=$value")
            continue
        }
        $out.Add($line)
    }
    [System.IO.File]::WriteAllText($TargetPath, ($out -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding $false))
}

# 读取已有配置的版本号
function Get-IniVersion([string]$Path) {
    if (-not (Test-Path $Path)) { return 0 }
    $section = ''
    foreach ($line in (Get-Content $Path -Encoding UTF8)) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $section = $matches[1].Trim().ToLower(); continue }
        if ($section -eq 'meta' -and $line -match '^\s*version\s*=\s*(\d+)') { return [int]$matches[1] }
    }
    return 0
}

Say '========================================' 'White'
Say ' OpenCode 语音输入 安装器' 'White'
$versionText = ''
$versionFile = Join-Path $root 'VERSION'
if (Test-Path $versionFile) { $versionText = (Get-Content $versionFile -Raw).Trim() }
if ($versionText) { Say (" 版本 " + $versionText) 'Gray' }
Say '========================================' 'White'
Say "安装目录: $InstallDir"
Say "插件目录: $pluginDir"
Say "计划任务: $serverTask / $hotkeyTask"

if (-not (Test-Path $payload)) { throw "缺少 payload 目录: $payload" }

# ---------------------------------------------------------------- 1 停止旧实例
Step '1/9 停止正在运行的旧实例'
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @('python.exe', 'pythonw.exe') -and $_.CommandLine -like '*voice_server.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process AutoHotkey64 -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$InstallDir*" } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Ok '已清理'

# ---------------------------------------------------------------- 2 复制文件
Step '2/9 复制程序文件'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
foreach ($file in 'voice_server.py', 'voice.ahk', 'voicectl.ps1', 'voicectl.cmd', 'selftest.ps1', 'bench.py', 'sample_zh.wav', 'settings.html') {
    $src = Join-Path $payload $file
    if (Test-Path $src) { Copy-Item $src (Join-Path $InstallDir $file) -Force }
    else { Warn "安装包中缺少 $file（已跳过）" }
}
foreach ($file in 'install-tasks.ps1', 'install-tasks.cmd') {
    Copy-Item (Join-Path $root $file) (Join-Path $InstallDir $file) -Force
}
Copy-Item (Join-Path $root 'README.md') (Join-Path $InstallDir 'README.md') -Force
Ok "文件已更新: $InstallDir"

# ---------------------------------------------------------------- 3 配置
Step '3/9 配置文件'
$ini = Join-Path $InstallDir 'voice.config.ini'
$iniExisted = Test-Path $ini
$iniVersion = Get-IniVersion $ini
# 配置版本升级：把影响性能的默认项强制更新到新默认值（其余保留用户取值）
$force = @{}
if ($iniVersion -lt 2) {
    $force['voice/partial_interval_ms'] = '280'
    $force['voice/partial_min_growth_ms'] = '150'
    $force['voice/partial_min_first_ms'] = '300'
    $force['voice/segment_seconds'] = '5'
    $force['voice/segment_overlap_ms'] = '600'
    $force['overlay/poll_ms'] = '150'
}
if ($iniVersion -lt 3) {
    # v3：改为全局生效 + 新增触发键/暂停快捷键/注入方式
    $force['hotkey/targets'] = '*'
    $force['hotkey/trigger'] = 'enter'
    $force['hotkey/disable_hotkey'] = '^!m'
    $force['hotkey/inject'] = 'paste'
}
if ($iniVersion -lt 4) {
    # v4：新增外观主题（默认跟随系统）
    $force['ui/theme'] = 'auto'
}
if ($iniVersion -lt 5) {
    # v5：新增计算设备（默认 auto = 有显卡用显卡）
    $force['voice/compute'] = 'auto'
}
# 版本号始终以模板为准
$templateVersion = (Select-String -Path (Join-Path $root 'config.default.ini') -Pattern '^\s*version\s*=\s*(\d+)' | Select-Object -First 1).Matches[0].Groups[1].Value
if ($templateVersion) { $force['meta/version'] = $templateVersion }
Merge-Ini -TemplatePath (Join-Path $root 'config.default.ini') -TargetPath $ini -Overrides @{ 'voice/port' = "$Port" } -Force $force
if ($iniExisted) {
    Ok "配置已刷新（版本 $iniVersion -> 2，保留原值并补充新选项）: $ini"
} else {
    Ok "已写入默认配置: $ini"
}

# ---------------------------------------------------------------- 4 Python 依赖
Step '4/9 Python 环境与依赖'
$uv = "$env:USERPROFILE\.local\bin\uv.exe"
if (-not (Test-Path $uv)) {
    Info '正在安装 uv ...'
    powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex" | Out-Null
}
if (-not (Test-Path $uv)) { throw 'uv 安装失败，请手动安装: https://docs.astral.sh/uv/' }

$venv = Join-Path $InstallDir '.venv'
$py = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $py)) {
    Info '创建 Python 3.12 虚拟环境 ...'
    & $uv venv --python 3.12 $venv | Out-Null
}

$depsReady = $false
if (Test-Path $py) {
    & $py -c "import torch, qwen_asr, sounddevice" 2>$null
    $depsReady = ($LASTEXITCODE -eq 0)
}
if ($depsReady) {
    Ok 'Python 依赖已就绪'
} else {
    Info '安装 PyTorch (CUDA，约 2.6GB) ...'
    & $uv pip install --python $py torch --index-url https://download.pytorch.org/whl/cu128
    Info '安装 qwen-asr / sounddevice ...'
    & $uv pip install --python $py qwen-asr sounddevice
    & $py -c "import torch; print('  torch', torch.__version__, 'cuda:', torch.cuda.is_available())"
}

# ---------------------------------------------------------------- 5 模型
Step '5/9 语音识别模型'
$modelDir = Join-Path $InstallDir 'models\Qwen3-ASR-1.7B'
if ($SkipModel) {
    Info '按要求跳过模型下载'
} elseif ((Test-Path $modelDir) -and (Get-ChildItem $modelDir -Filter '*.safetensors' -ErrorAction SilentlyContinue)) {
    Ok "模型已存在: $modelDir"
} else {
    Info "下载 $Model（约 4.7GB，请耐心等待）..."
    & $uv tool run --from modelscope modelscope download --model $Model --local_dir $modelDir
    Ok '模型下载完成'
}

# ---------------------------------------------------------------- 6 AutoHotkey
Step '6/9 AutoHotkey v2'
$ahkDir = Join-Path $InstallDir 'bin\ahk'
$ahkExe = Join-Path $ahkDir 'AutoHotkey64.exe'
if (Test-Path $ahkExe) {
    Ok 'AutoHotkey 已存在'
} else {
    New-Item -ItemType Directory -Force -Path $ahkDir | Out-Null
    $zip = Join-Path $ahkDir 'ahk-v2.zip'
    Info '下载 AutoHotkey v2 ...'
    Invoke-WebRequest -Uri 'https://www.autohotkey.com/download/ahk-v2.zip' -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $ahkDir -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $ahkExe)) { throw 'AutoHotkey 解压失败' }
    Ok 'AutoHotkey 已就绪'
}

# ---------------------------------------------------------------- 7 插件与界面资源
Step '7/9 OpenCode 插件与界面资源'
New-Item -ItemType Directory -Force -Path $pluginDir | Out-Null
Copy-Item (Join-Path $payload 'plugin\*') $pluginDir -Recurse -Force
@{ port = $Port; installDir = $InstallDir } |
    ConvertTo-Json |
    Set-Content -Path (Join-Path $pluginDir 'config.json') -Encoding UTF8
Ok "插件已部署: $pluginDir"
New-VoiceIcon (Join-Path $InstallDir 'assets\voice.ico')
if (Test-Path (Join-Path $InstallDir 'assets\voice.ico')) { Ok '托盘图标已生成' }
if (Test-Path $versionFile) { Copy-Item $versionFile $InstallDir -Force }

# ---------------------------------------------------------------- 8 自启动
Step '8/9 自启动'
$taskCreated = $false
if ($NoTasks) {
    Warn '按要求跳过计划任务'
} else {
    $helper = Join-Path $root 'install-tasks.ps1'
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    try {
        if ($isAdmin) {
            & $helper -InstallDir $InstallDir -UserName $userName -ServerTask $serverTask -HotkeyTask $hotkeyTask
        } else {
            Info '创建计划任务需要管理员权限，请在弹窗中点击“是”...'
            $argList = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$helper`"",
                '-InstallDir', "`"$InstallDir`"",
                '-UserName', "`"$userName`"",
                '-ServerTask', $serverTask,
                '-HotkeyTask', $hotkeyTask
            )
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait
        }
        $taskCreated = [bool](schtasks /query /tn $hotkeyTask 2>$null)
    } catch {
        Warn "计划任务创建失败或被取消: $($_.Exception.Message)"
    }
}

if ($taskCreated) {
    Ok '计划任务已创建（热键助手以最高权限运行，兼容管理员版 OpenCode）'
} else {
    Warn '改用启动文件夹快捷方式（普通权限）'
    New-StartupShortcut 'OpenCodeVoiceServer.lnk' (Join-Path $InstallDir '.venv\Scripts\pythonw.exe') "`"$(Join-Path $InstallDir 'voice_server.py')`""
    New-StartupShortcut 'OpenCodeVoiceHotkey.lnk' $ahkExe "`"$(Join-Path $InstallDir 'voice.ahk')`""
    Ok '启动文件夹快捷方式已创建'
}

# ---------------------------------------------------------------- 9 启动
Step '9/9 启动并检查'
if ($NoStart) {
    Info '按要求跳过启动'
} else {
    if ($taskCreated) {
        schtasks /run /tn $serverTask 2>$null | Out-Null
        Start-Sleep -Seconds 1
        schtasks /run /tn $hotkeyTask 2>$null | Out-Null
    } else {
        Start-Process -FilePath (Join-Path $InstallDir '.venv\Scripts\pythonw.exe') `
            -ArgumentList "`"$(Join-Path $InstallDir 'voice_server.py')`"" -WorkingDirectory $InstallDir -WindowStyle Hidden
        Start-Process -FilePath $ahkExe -ArgumentList "`"$(Join-Path $InstallDir 'voice.ahk')`"" -WorkingDirectory $InstallDir
    }

    Info '等待语音服务就绪（首次加载模型约 10-60 秒）...'
    $healthy = $false
    for ($i = 0; $i -lt 180; $i++) {
        Start-Sleep -Seconds 1
        try {
            $h = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2
            if ($h.ready) { $healthy = $true; break }
        } catch { }
    }
    if ($healthy) { Ok "语音服务就绪: http://127.0.0.1:$Port/health" }
    else { Warn "服务尚未就绪，稍后可用 voicectl.cmd status 查看（首次加载模型较慢）" }

    Start-Sleep -Seconds 1
    if (Get-Process AutoHotkey64 -ErrorAction SilentlyContinue) { Ok '长按回车助手已运行（见托盘图标）' }
    else { Warn '助手进程未检测到，请运行 voicectl.cmd 或查看 voice_server.log' }
}

# ---------------------------------------------------------------- 完成
Write-Host ''
Say '================ 安装完成 ================' 'Green'
Say '用法：在 OpenCode 窗口按住回车（>0.35s）说话，松开自动转写并粘贴；短按回车仍是正常提交。'
Say "管理：$InstallDir\voicectl.cmd status | start | stop | restart | devices | config | log"
Say '插件：终端 TUI 中可用 /voice、/voice-status、/voice-setup（底部状态栏显示 🎤）'
Say "配置：$(Join-Path $InstallDir 'voice.config.ini')"
Say '卸载：powershell -ExecutionPolicy Bypass -File uninstall.ps1'
Say '=========================================' 'Green'
