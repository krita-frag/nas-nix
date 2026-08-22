# 知识库构建 job 镜像（预烘焙）：一次构建免去每次 Gitea Actions 运行
# apt-get 安装 git/python3 与 pip 安装 mkdocs 的重复耗时（实测 apt-get 单次约 3-4 分钟）。
#
# 构建：管理机执行 runner/build-kb-image.sh（在 NAS 本地 podman build，
# 与 runner 共用同一镜像存储，免 registry push 认证）。
# 用法：Gitea Actions 用 kb-builder 标签（runs-on: kb-builder），
#       /opt/venv 已预装 mkdocs-material + pyyaml，build.sh 直接复用。
FROM node:20-bookworm

# 构建运行时工具：git（clone/push）+ python3（venv/pip）
RUN apt-get update \
    && apt-get install -y --no-install-recommends git python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# 预装知识库构建依赖：/opt/venv 由 build.sh 优先复用，免每次 pip install
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir mkdocs-material pyyaml

ENV PATH="/opt/venv/bin:$PATH"
