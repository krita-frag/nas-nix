# NAS 运维知识库

由 nas-nix 仓库 `docs/` 目录自动构建的知识库（MkDocs Material）。push hub（nas-nix）
main 触发 Gitea Actions 聚合构建所有注册知识库 → Hugo 生成统一站点 → 强推 pages 分支
→ NAS post-receive 钩子检出到站点根（`http://<nas-ip>:8080/`）。

本知识库位于 `http://<nas-ip>:8080/zhou/nas-nix/`，中心主页自动聚合所有注册知识库的链接。

## 内容

- [自托管服务一键部署（容器）](container-deploy.md)
- [自托管服务本机声明式部署](nixos-native-deploy.md)

## 注册新知识库

知识库中心采用**聚合式单站**：注册点唯一（`docs-hub/repos.json`），内容仓库零配置、
零 token、零 workflow，所有构建由 hub 统一完成，UI 统一（MkDocs Material + Hugo 聚合页）。

1. 内容仓库根目录放 `mkdocs.yml` + `docs/` 知识库源（MkDocs Material 主题）；
2. 在 nas-nix 仓库 `docs-hub/repos.json` 的 `repos` 列表加一行
   `{ "owner": ..., "name": ..., "desc": ... }`；
3. 推送到 hub（`./deploy.sh publish` 或手动 push main）触发聚合重建。

之后 hub 每次重建都会自动把该仓库 MkDocs 产物构建进统一站点，中心主页自动出现新卡片。
