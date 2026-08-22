#!/usr/bin/env bash
#
# 知识库中心统一构建（单一 MkDocs 站点）：
#   1) clone 每个注册内容仓库，把其 docs/（MkDocs Material Markdown 源）合并到统一
#      docs_dir，按 <owner>/<name>/ 组织；内容仓库零配置（无需各自 mkdocs.yml / workflow / token）；
#   2) 从 repos.json 生成统一主页 index.md（卡片聚合）与 MkDocs nav（每个知识库一个顶部 tab）；
#   3) 用单一 mkdocs.yml 构建为完整站点：统一主题 + 全站搜索 + 统一导航。
#
# 前置（由 Gitea Actions workflow 保证）：
#   - git、python3-venv、python3-pip 已安装
#   - 环境变量 GITEA_TOKEN = PAGES_TOKEN（write:repository 权限 API token）
#   - 内容仓库根目录有 docs/（MkDocs Material Markdown 源）
#
# 用法：
#   GITEA_TOKEN=xxx bash docs-hub/build.sh
#   构建产物输出到 /tmp/hub-site
set -euo pipefail

GITEA_TOKEN="${GITEA_TOKEN:?需要 PAGES_TOKEN（write:repository 权限 API token）}"
GITEA_BASE="http://oauth2:${GITEA_TOKEN}@127.0.0.1:3000"
VENV="/tmp/docs-venv"
BUILD="/tmp/docs-build"   # 统一构建目录（mkdocs.yml + docs/ + extra.css）
DOCS="${BUILD}/docs"      # 统一 docs_dir
SITE_DIR="/tmp/hub-site"  # 构建产物
REPO_CLONE="/tmp/docs-repo"

cd "$(dirname "$0")"

# --- 构建环境（一次性，workflow 已装系统依赖，这里只准备 Python venv）---
python3 -m venv "${VENV}"
"${VENV}/bin/pip" install -q mkdocs-material

# --- 准备统一构建目录 ---
rm -rf "${BUILD}" "${SITE_DIR}"
mkdir -p "${DOCS}"
cp mkdocs.yml "${BUILD}/mkdocs.yml"
cp extra.css "${BUILD}/extra.css"

# --- 逐一 clone 各内容仓库，合并 docs/ 到 <owner>/<name>/ ---
mapfile -t repo_list < <(python3 -c \
  "import json; d=json.load(open('repos.json')); print('\n'.join(f\"{r['owner']}/{r['name']}\" for r in d['repos']))")

for repo in "${repo_list[@]}"; do
  [ -n "${repo}" ] || continue
  rm -rf "${REPO_CLONE}"
  git clone --depth 1 "${GITEA_BASE}/${repo}.git" "${REPO_CLONE}"
  target="${DOCS}/${repo}"
  mkdir -p "${target}"
  cp -r "${REPO_CLONE}/docs/." "${target}/"
  echo "合并完成: ${repo}"
done

# --- 生成统一主页（卡片聚合，指向各知识库）---
python3 - "${DOCS}" <<'PY'
import json, sys
docs = sys.argv[1]
repos = json.load(open('repos.json'))['repos']
cards = []
for r in repos:
    link = f"{r['owner']}/{r['name']}/"
    desc = r.get('desc', '')
    cards.append(
        f"-   **{r['name']}**\n\n    ---\n\n    {desc}\n    [进入 →]({link})"
    )
md = f"""# NAS 知识库中心

统一聚合的运维知识库：单一站点、统一导航、全站搜索。
所有内容仓库仅提供 `docs/` Markdown 源，由 hub 经 Gitea Actions 统一构建。

## 知识库

<div class="grid cards" markdown>

{chr(10).join(cards)}

</div>
"""
with open(f'{docs}/index.md', 'w', encoding='utf-8') as f:
    f.write(md)
PY

# --- 生成 MkDocs nav：每个知识库一个顶层 tab，其下递归列出全部页面 ---
python3 - "${BUILD}" "${DOCS}" <<'PY'
import json, os, sys
build, docs = sys.argv[1], sys.argv[2]
repos = json.load(open('repos.json'))['repos']

def render_nav(base_dir, rel_dir, indent):
    lines = []
    for e in sorted(os.listdir(os.path.join(base_dir, rel_dir))):
        full = os.path.join(base_dir, rel_dir, e)
        rel = f"{rel_dir}/{e}".lstrip('/')
        if os.path.isdir(full):
            lines.append(f"{indent}- {e}:")
            lines += render_nav(base_dir, rel, indent + '  ')
        elif e.endswith('.md'):
            lines.append(f"{indent}- {e[:-3]}: {rel}")
    return lines

with open(f'{build}/mkdocs.yml', 'a', encoding='utf-8') as f:
    f.write('\nnav:\n  - 首页: index.md\n')
    for r in repos:
        prefix = f"{r['owner']}/{r['name']}"
        f.write(f"  - {r['name']}:\n")
        for line in render_nav(docs, prefix, '      '):
            f.write(line + '\n')
PY

# --- 单一站点构建 ---
(cd "${BUILD}" && "${VENV}/bin/mkdocs" build --site-dir "${SITE_DIR}")
echo "统一站点已构建: ${SITE_DIR}"
