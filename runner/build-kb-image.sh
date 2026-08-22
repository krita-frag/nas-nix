#!/usr/bin/env bash
#
# 构建并预装载 kb-builder job 镜像（Gitea Actions 预烘焙镜像）：
# 在 NAS 本地用 podman build（rootful，与 gitea-runner 经 /run/docker.sock 共用镜像存储），
# 命名 127.0.0.1:3000/kb-builder:latest；runner 配置 force_pull:false 命中本地镜像免联网拉取，
# 无需向 Gitea registry push（省去认证）。镜像随 NixOS 重装丢失，重建执行本脚本即可。
#
# 用法：
#   bash runner/build-kb-image.sh            # 目标默认 192.168.64.4
#   TARGET=<nas-ip> bash runner/build-kb-image.sh
set -euo pipefail

TARGET="${TARGET:-192.168.64.4}"
IMAGE="127.0.0.1:3000/kb-builder:latest"
DIR="$(cd "$(dirname "$0")" && pwd)"
# Dockerfile 位置：经 flake 打包（nix run .#kb-builder）时由 KB_BUILDER_DOCKERFILE 指向
# store 内的副本；直接从仓库运行则用脚本同目录文件
DOCKERFILE="${KB_BUILDER_DOCKERFILE:-${DIR}/kb-builder.Dockerfile}"

echo "==> 在 ${TARGET} 上本地构建 ${IMAGE}（apt-get 仅此一次，约 1-3 分钟）"
scp -o ConnectTimeout=8 "${DOCKERFILE}" "root@${TARGET}:/tmp/kb-builder.Dockerfile"
ssh -o ConnectTimeout=8 "root@${TARGET}" \
  "podman build -f /tmp/kb-builder.Dockerfile -t ${IMAGE} /tmp && rm -f /tmp/kb-builder.Dockerfile"
ssh -o ConnectTimeout=8 "root@${TARGET}" "podman images | grep kb-builder"
echo "==> 完成。Gitea Actions 使用 runs-on: kb-builder 即命中该镜像。"
