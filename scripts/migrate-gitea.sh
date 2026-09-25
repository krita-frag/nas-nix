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
set -uo pipefail

GITEA_URL="${GITEA_URL:-http://nas.local:3000}"
GITEA_USER="${GITEA_USER:-zhou}"
BASE="/Users/a1-6/Documents/projects"
if [ "$#" -gt 0 ]; then
  repos=( "$@" )
else
  repos=( abcx actant pymz diskforge neko npanel )
fi

api() { # 创建空仓库（幂等，已存在则忽略）
  local name="$1"
  if [ -z "${GITEA_TOKEN:-}" ]; then echo "  !! 未设 GITEA_TOKEN，跳过自动建仓（请在 Web 手动建空仓库）"; return 0; fi
  local code
  code="$(curl -sS --max-time 10 -o /tmp/gitea-api.json -w '%{http_code}' \
    -X POST "$GITEA_URL/api/v1/user/repos" \
    -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
    -d "{\"name\":\"$name\",\"private\":false,\"auto_init\":false}")"
  case "$code" in
    201) echo "  建仓 OK" ;;
    409) echo "  仓库已存在，跳过建仓" ;;
    401|403)
      echo "  建仓失败 HTTP $code：令牌无效或无权限（$name）"
      sed 's/^/      /' /tmp/gitea-api.json 2>/dev/null | head -2
      ;;
    *) echo "  建仓 HTTP $code：$(cat /tmp/gitea-api.json 2>/dev/null | head -c 120)" ;;
  esac
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

  # 3) 推送全部分支与标签（首次会提示输入 gitea 凭据；失败继续，不中断后面仓库）
  if git -C "$BASE/$repo" push gitea --all 2>&1; then
    git -C "$BASE/$repo" push gitea --tags 2>&1 || true
  else
    echo "  !! 推送失败（$repo）——若为认证错误，见上方报错；可改 SSH 或检查令牌"
  fi
done
echo "完成。"