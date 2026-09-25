#!/usr/bin/env bash
# macOS 连接脚本：Samba 共享挂载 + Syncthing 客户端安装/引导 + Web 服务直达。
# 前提：已加入局域网（nas.local 由 avahi 提供）；挂载口令走系统凭据弹窗（不入脚本）。
# 用法：bash scripts/connect/macos.sh   （可设 NAS_HOST，默认 nas.local）
set -euo pipefail

NAS_HOST="${NAS_HOST:-nas.local}"
WEB_OPEN="${WEB_OPEN:-open}"

has() { command -v "$1" >/dev/null 2>&1; }

echo "== 连接 NAS($NAS_HOST) =="

# 1) Samba 共享：用 Finder 的 smb:// 挂载（弹凭据框），public 免密、nas 用账号 nas
for share in public nas; do
  echo ">> 挂载 smb://$NAS_HOST/$share"
  "$WEB_OPEN" "smb://${NAS_HOST}/${share}"
done

# 2) Syncthing：客户端缺失则自动安装（首选 GUI 版 cask，回退 CLI）
if has syncthing || has syncthing-gui; then
  echo ">> Syncthing 客户端已安装"
elif has brew; then
  echo ">> 安装 Syncthing（brew）"
  brew install --cask syncthing 2>/dev/null || brew install syncthing
else
  echo "!! 未装 Homebrew，无法自动安装 Syncthing；请到 https://syncthing.net 安装"
fi
echo ">> 在 Syncthing GUI 添加“远程设备”，设备 ID 用：$(bash scripts/connect/connect-info.sh 2>/dev/null | grep -m1 '设备 ID' | sed 's/.*：//' || echo '见 connect-info.sh 输出')"

# 3) Web 服务直达
echo ">> 打开 Web 服务"
"$WEB_OPEN" "http://$NAS_HOST:8080"   # Docs
"$WEB_OPEN" "http://$NAS_HOST:3000"   # Gitea
"$WEB_OPEN" "https://$NAS_HOST:9090"  # Cockpit

echo "完成。"