#!/usr/bin/env bash
# 连接信息清单：打印 NAS 各服务的稳定访问地址（局域网 .local + 尾网域名），
# 并尝试经 ssh 读取 Syncthing 本机设备 ID（用于客户端配对）。
# 用法：bash scripts/connect/connect-info.sh   （可设 NAS_HOST 覆盖，默认 nas.local）
set -euo pipefail

NAS_HOST="${NAS_HOST:-nas.local}"

echo "== NAS 连接信息（$NAS_HOST） =="
echo "主机名：$NAS_HOST   局域网 IP：按需（avahi 保证 .local 稳定）"
echo "尾网域名：https://nas-1.tailf2ba32.ts.net（需在尾网内）"

echo
echo "-- Web 服务 --"
echo "Docs(知识库)   : http://$NAS_HOST:8080"
echo "Gitea          : http://$NAS_HOST:3000"
echo "Cockpit        : https://$NAS_HOST:9090（登录用已启用账号）"
echo "Syncthing GUI  : http://$NAS_HOST:8384 (仅本机绑定，需端口转发/SSH 隧道)"

echo
echo "-- Samba 共享 --"
echo "public(免密) : smb://$NAS_HOST/public"
echo "nas(需口令)  : smb://$NAS_HOST/nas   用户 nas"

echo
echo "-- Syncthing 配对 --"
if command -v ssh >/dev/null 2>&1; then
  id="$(ssh -o ConnectTimeout=6 -o BatchMode=yes "root@${NAS_HOST}" \
    "grep -o '<device id=\"[^\"]*\"' /var/lib/syncthing/.config/syncthing/config.xml 2>/dev/null | head -1 | sed 's/.*=\"//'" 2>/dev/null || true)"
  if [ -n "$id" ]; then echo "NAS 设备 ID：$id"; else echo "（无法经 ssh 读取；请登录 NAS 或 Syncthing GUI 查看设备 ID）"; fi
else
  echo "（本机无 ssh，无法自动读取；请登录 NAS/Syncthing GUI 查看设备 ID）"
fi