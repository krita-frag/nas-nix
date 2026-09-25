# Windows 连接脚本：Samba 共享映射网络驱动器 + Syncthing 客户端安装/引导 +
# Web 服务直达。挂载凭据用网络驱动器弹窗（不入脚本）。
# 用法（PowerShell，需管理员权限安装用 winget）：
#   powershell -ExecutionPolicy Bypass -File scripts\connect\windows.ps1
# 可设 NAS_HOST 环境变量，默认 nas.local；windows 高度依赖网络发现，如解析不到
# 则换成固定 IP：$env:NAS_HOST="192.168.5.93"

param([string]$Host = $env:NAS_HOST)
if (-not $Host) { $Host = "nas.local" }

Write-Host "== 连接 NAS($Host) ==" -ForegroundColor Cyan

# 1) Syncthing 客户端：缺失则用 winget 安装（GUI 版 SyncthingTray / 官方）
if (-not (Get-Command syncthing -ErrorAction SilentlyContinue)) {
    Write-Host ">> 安装 Syncthing 客户端（winget）"
    # 提供常见包名，按可用性回退
    winget install --id Syncthing.Syncthing -e -h --accept-package-agreements --accept-source-agreements 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "!! winget 未装成 Syncthing；请到 https://syncthing.net 手动安装" -ForegroundColor Yellow
    }
} else {
    Write-Host ">> Syncthing 客户端已安装"
}
Write-Host ">> 用设备 ID 在 Syncthing GUI 添加远程设备（ID 见 connect-info.sh 输出）"

# 2) Samba 共享：映射网络驱动器（P: public 免密, N: nas 需口令）
$shares = @{ P = "public"; N = "nas" }
foreach ($d in $shares.GetEnumerator()) {
    $target = "\\$Host\$($d.Value)"
    if (Test-Path "$($d.Key):") { Write-Host ">> $($d.Key): 已映射，跳过"; continue }
    Write-Host ">> 映射 $($d.Key): -> $target"
    net use "$($d.Key):" "$target" 2>$null
}

# 3) Web 服务直达
Write-Host ">> 打开 Web 服务"
foreach ($u in @("http://$Host`:8080", "http://$Host`:3000", "https://$Host`:9090")) {
    Start-Process $u
}

Write-Host "完成。" -ForegroundColor Cyan