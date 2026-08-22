#!/usr/bin/env bash
#
# 一键部署：从 macOS 在 NAS 上构建并切换 NixOS 系统
# 构建与切换均在 NAS 上执行，避免跨架构本地模拟。
#
# 用法:
#   ./deploy.sh                 # 构建并切换（默认）
#   ./deploy.sh dry-run         # 构建但不切换（预演）
#   ./deploy.sh rollback        # 回滚到上一代
#   ./deploy.sh smoke           # 运行冒烟测试
#   TARGET=<ip> ./deploy.sh     # 指定目标主机（实机接入时用真实 IP 覆盖）
#
# 知识库发布不在此脚本：引擎仓库 nas-docs 自带 publish.sh（Gitea API 触发构建）。
# 新机引导从 GitHub 克隆本仓库与 nas-docs（GitHub 为主源，Gitea 为本地镜像）。
#
set -euo pipefail

# 当前测试用虚拟机地址；实机接入时以 TARGET 环境变量覆盖，无需改本文件
TARGET="${TARGET:-192.168.64.4}"
REMOTE="root@${TARGET}"
FLAKE=".#nas"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8"

# --- 确保 nix 可用（macOS Determinate Nix 不在默认 PATH）---
if ! command -v nix >/dev/null 2>&1; then
  if [ -x /nix/var/nix/profiles/default/bin/nix ]; then
    export PATH="/nix/var/nix/profiles/default/bin:${PATH}"
    # shellcheck disable=SC1091
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  else
    echo "错误：未找到 nix，请先安装 Nix。" >&2
    exit 1
  fi
fi

# --- 预检：SSH 密钥认证连通性（安全：仅密钥、无交互）---
echo "==> 检查 SSH 连通性（${REMOTE}）"
if ! ssh ${SSH_OPTS} "${REMOTE}" 'true' 2>/dev/null; then
  echo "错误：无法以密钥认证连接 ${REMOTE}。" >&2
  echo "请确认 NAS 在线、主机指纹已加入 known_hosts、管理机公钥已授权。" >&2
  exit 1
fi

# --- 提示未提交改动（保持 配置 <-> generation 对齐）---
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  echo "==> 提示：存在未提交改动，部署结果可能与已提交配置不一致（建议先 commit）"
fi

MODE="${1:-switch}"
case "${MODE}" in
  switch)
    echo "==> 远程构建并切换 ${FLAKE}（构建/切换均在 NAS 进行）"
    nix run .#nixos-rebuild -- switch \
      --flake "${FLAKE}" \
      --build-host "${REMOTE}" \
      --target-host "${REMOTE}"
    echo
    echo "==> 当前系统 generation："
    ssh ${SSH_OPTS} "${REMOTE}" \
      'nix-env --list-generations --profile /nix/var/nix/profiles/system | tail -1'
    echo
    echo "==> 部署完成。可运行 ./deploy.sh smoke 做冒烟验证。"
    ;;
  dry-run)
    echo "==> 预演：构建但不切换"
    nix run .#nixos-rebuild -- dry-activate \
      --flake "${FLAKE}" --build-host "${REMOTE}" --target-host "${REMOTE}"
    ;;
  rollback)
    echo "==> 回滚到上一代"
    nix run .#nixos-rebuild -- switch \
      --flake "${FLAKE}" --build-host "${REMOTE}" --target-host "${REMOTE}" --rollback
    ;;
  smoke)
    echo "==> 冒烟测试（${REMOTE}）"
    ssh ${SSH_OPTS} "${REMOTE}" 'bash -s' <<'SMOKE'
set -e
echo "--- agenix 密钥挂载 ---"
ls /run/agenix/
echo "--- 关键服务 ---"
for s in samba-smbd syncthing docker; do
  printf "%-14s %s\n" "$s" "$(systemctl is-active $s)"
done
echo "--- 关键端口 ---"
ss -tln | grep -E ':(9090|9443|8384|445)\b' | awk '{print $4}'
echo "--- zram ---"
zramctl | grep SWAP || echo "zram 未启用"
echo "--- Docker 容器 ---"
docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null || echo "docker 不可用"
echo "--- 系统 generation 数 ---"
nix-env --list-generations --profile /nix/var/nix/profiles/system | wc -l
SMOKE
    ;;
  *)
    echo "用法: $0 [switch|dry-run|rollback|smoke]" >&2
    exit 1
    ;;
esac
