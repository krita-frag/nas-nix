#!/usr/bin/env bash
# 把本地项目迁移到 Gitea（建空仓库 + 推送）。适合本仓库其余项目。
# 原则：
#   - 不在脚本/命令行写明文口令；授权由 git 凭据提示或 $GITEA_TOKEN 提供
#   - GitHub 已推送的项目保留 origin=github，另加 gitea remote；未推送的仅建到 gitea
#
# 用法：
#   export GITEA_TOKEN="<你在 Web 生成的 PAT>"   # 可选：用于自动建空仓库
#   bash scripts/migrate-gitea.sh                  # 迁移默认 6 个
#   bash scripts/migrate-gitea.sh repoA repoB      # 或指定列表
#   推送 HTTPS 时首次 git 会提示输入 zhou + 口令（或把 token 当密码），经 macOS 钥匙串缓存
set -euo pipefail

GITEA_URL="${GITEA_URL:-http://nas.local:3000}"
GITEA_USER="${GITEA_USER:-zhou}"
BASE="/Users/a1-6/Documents/projects"
repos=( "${@:-abcx actant pymz diskforge neko npanel}" )

api() { # 创建空仓库（幂等，已存在则忽略）
  local name="$1"
  if [ -z "${GITEA_TOKEN:-}" ]; then echo "  !! 未设 GITEA_TOKEN，跳过自动建仓（请在 Web 手动建空仓库）"; return 0; fi
  curl -fsS --max-time 10 -X POST "$GITEA_URL/api/v1/user/repos" \
    -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
    -d "{\"name\":\"$name\",\"private\":false,\"auto_init\":false}" \
    >/dev/null 2>&1 && echo "  建仓 OK" || echo "  建仓跳过/已存在(401需测token)"
}

for repo in "${repos[@]}"; do
  echo "===== $repo ====="
  [ -d "$BASE/$repo/.git" ] || { echo "  !! 非 git 仓库，跳过"; continue; }

  # 1) 建空仓库
  api "$repo"

  # 2) 加 gitea remote（HTTPS，保留原 origin）
  git -C "$BASE/$repo" remote remove gitea 2>/dev/null || true
  git -C "$BASE/$repo" remote add gitea "$GITEA_URL/$GITEA_USER/$repo.git"
  echo "  remote gitea = $(git -C "$BASE/$repo" remote get-url gitea)"

  # 3) 推送全部分支与标签（首次会提示输入 gitea 凭据）
  git -C "$BASE/$repo" push gitea --all 2>&1 | sed 's/^/    /'
  git -C "$BASE/$repo" push gitea --tags 2>&1 | sed 's/^/    /' || true
done
echo "完成。"