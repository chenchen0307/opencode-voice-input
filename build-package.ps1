#Requires -Version 5.1
<#
OpenCode 语音输入 —— 打包脚本

生成 dist/OpenCodeVoice-Setup-<版本>.zip（不含模型，首次安装时自动下载）
用法：
    powershell -ExecutionPolicy Bypass -File build-package.ps1
可选：
    -Version 1.1.0      指定版本号（默认读 VERSION 文件）
    -OutDir <路径>      输出目录（默认 dist）
#>
[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

if (-not $Version) {
    $VersionFile = Join-Path $root 'VERSION'
    if (-not (Test-Path $VersionFile)) { throw '缺少 VERSION 文件' }
    $Version = (Get-Content $VersionFile -Raw).Trim()
}
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

$pkgName = "OpenCodeVoice-Setup-$Version"
$stage = Join-Path $env:TEMP ("ocvoice-pkg-" + [guid]::NewGuid().ToString('N'))
$pkgDir = Join-Path $stage $pkgName

Write-Host "打包 $pkgName" -ForegroundColor Cyan

# ---- 准备暂存目录 ----
New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null
foreach ($file in 'install.ps1', 'install-tasks.ps1', 'install-tasks.cmd', 'uninstall.ps1', 'README.md', 'config.default.ini', 'VERSION') {
    $src = Join-Path $root $file
    if (-not (Test-Path $src)) { throw "缺少文件: $file" }
    Copy-Item $src $pkgDir -Force
}
Copy-Item (Join-Path $root '安装.cmd') (Join-Path $pkgDir '安装.cmd') -Force
Copy-Item (Join-Path $root 'payload') (Join-Path $pkgDir 'payload') -Recurse -Force

# 打包内不需要的调试文件
Get-ChildItem (Join-Path $pkgDir 'payload') -Recurse -Include '*.pyc', '*.log' -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem (Join-Path $pkgDir 'payload') -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# ---- 校验必需文件 ----
$required = @(
    'install.ps1', 'uninstall.ps1', 'README.md', 'config.default.ini', 'VERSION', '安装.cmd',
    'payload\voice_server.py', 'payload\voice.ahk', 'payload\settings.html', 'payload\voicectl.ps1', 'payload\voicectl.cmd',
    'payload\selftest.ps1', 'payload\plugin\tui.tsx', 'payload\plugin\index.ts', 'payload\plugin\package.json'
)
foreach ($rel in $required) {
    if (-not (Test-Path (Join-Path $pkgDir $rel))) { throw "打包内容缺少: $rel" }
}

# ---- 写入版本号到说明文件 ----
(Get-Content (Join-Path $pkgDir 'install.ps1') -Raw -Encoding UTF8) |
    Set-Content (Join-Path $pkgDir 'install.ps1') -Encoding UTF8

# ---- 生成 zip ----
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zip = Join-Path $OutDir "$pkgName.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $pkgDir '*') -DestinationPath $zip -CompressionLevel Optimal

# ---- 校验和 ----
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
"$hash  $pkgName.zip" | Set-Content (Join-Path $OutDir 'SHA256SUMS.txt') -Encoding ASCII

Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

$item = Get-Item $zip
Write-Host ''
Write-Host "完成：" -ForegroundColor Green
Write-Host ("  {0}" -f $item.FullName)
Write-Host ("  大小 {0:N1} MB" -f ($item.Length / 1MB))
Write-Host ("  SHA256 {0}" -f $hash)
Write-Host ''
Write-Host "安装方式：解压后双击『安装.cmd』（会自动请求管理员权限）" -ForegroundColor Gray
