# NAS 运维知识库

由 nas-nix 仓库 `docs/` 目录提供的知识库源（纯 Markdown）。引擎（nas-docs）
依据 `repos.json` 聚合构建所有注册知识库 → 单一 MkDocs 站点 → 直接写入站点根
（`http://<nas-ip>:8080/`）。

本知识库位于 `http://<nas-ip>:8080/<owner>/nas-nix/`，中心主页自动聚合所有注册知识库的链接。

## 内容

- [自托管服务一键部署（容器）](container-deploy.md)
- [自托管服务本机声明式部署](nixos-native-deploy.md)

## 注册新知识库

知识库中心采用**聚合式单站**：注册点唯一（引擎仓库 `nas-docs/repos.json`），
内容仓库零配置、零 token、零 workflow，所有构建由引擎统一完成，UI 统一（MkDocs Material）。

1. 内容仓库根目录放 `docs/` 知识库源（纯 Markdown，可选 `.kb.yml` 覆盖标题/路径/导航）；
2. 在引擎仓库 `repos.json` 的 `repos` 列表加一行
   `{ "owner": ..., "name": ..., "desc": ... }`；
3. 在引擎仓库运行 `GITEA_PASS=<口令> bash publish.sh`（触发立即重建）或等待每 6h 定时自动同步。

之后引擎每次重建都会自动把该仓库 Markdown 构建进统一站点，中心主页自动出现新卡片。
