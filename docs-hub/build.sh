#!/usr/bin/env bash
#
# 知识库中心聚合构建：读取 repos.json 中的每个内容仓库，
# 逐一 clone 并 mkdocs build 产物拷贝到 static/<owner>/<name>/，
# 再复制 repos.json 到 data/ 供 Hugo 主页渲染。
#
# 前置（由 Gitea Actions workflow 保证）：
#   - git、python3-venv、python3-pip、hugo 已安装
#   - 环境变量 GITEA_TOKEN = PAGES_TOKEN（write:repository 权限 API token）
#   - 内容仓库根目录有 mkdocs.yml + docs/（MkDocs Material）
#
# 用法：
#   GITEA_TOKEN=xxx bash docs-hub/build.sh
#   然后 cd docs-hub && hugo --minify --destination /tmp/site
set -euo pipefail

GITEA_TOKEN="${GITEA_TOKEN:?需要 PAGES_TOKEN（write:repository 权限 API token）}"
GITEA_BASE="http://oauth2:${GITEA_TOKEN}@127.0.0.1:3000"
VENV="/tmp/docs-venv"
REPO_CLONE="/tmp/docs-repo"
SITE_DIR="/tmp/docs-site"

cd "$(dirname "$0")"

# --- 构建环境（一次性，workflow 已装系统依赖，这里只准备 Python venv）---
python3 -m venv "${VENV}"
"${VENV}/bin/pip" install -q mkdocs-material

# --- 清空生成目录（产物不入库，见 .gitignore）---
rm -rf static data
mkdir -p static data

# --- 逐一构建各内容仓库 ---
mapfile -t repo_list < <(python3 -c \
  "import json; d=json.load(open('repos.json')); print('\n'.join(f\"{r['owner']}/{r['name']}\" for r in d['repos']))")

for repo in "${repo_list[@]}"; do
  [ -n "${repo}" ] || continue
  rm -rf "${REPO_CLONE}" "${SITE_DIR}"
  git clone --depth 1 "${GITEA_BASE}/${repo}.git" "${REPO_CLONE}"
  (cd "${REPO_CLONE}" && "${VENV}/bin/mkdocs" build --site-dir "${SITE_DIR}")
  mkdir -p "static/${repo}"
  cp -r "${SITE_DIR}/." "static/${repo}/"
  echo "构建完成: ${repo}"
done

# --- 聚合数据（Hugo 主页渲染卡片）---
cp repos.json data/repos.json
echo "聚合数据已生成: data/repos.json"
