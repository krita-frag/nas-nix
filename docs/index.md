# NAS 运维知识库

由 nas-nix 仓库 `docs/` 目录自动构建的知识库网站（MkDocs Material）。
push main 触发 Gitea Actions 构建并强推 pages 分支，NAS post-receive 钩子就地部署到
知识库中心（`http://<nas-ip>:8080/zhou/nas-nix/`），并在中心主页聚合链接。

## 内容

- [自托管服务一键部署（容器）](container-deploy.md)
- [自托管服务本机声明式部署](nixos-native-deploy.md)

## 注册新知识库

知识库中心（Docs 模块）支持任意 Gitea 仓库注册，主页自动聚合所有已注册知识库的链接，互不耦合：

1. 仓库根目录放 `mkdocs.yml` + `docs/` 知识库源；
2. 复制 [kb-workflow.example.yml](kb-workflow.example.yml) 为 `.gitea/workflows/docs.yml`；
3. 仓库设置添加 `PAGES_TOKEN` secret（write:repository 权限 API token）；
4. 在 nas-nix `hosts/nas/default.nix` 的 `services.docs.repos` 加一行 `owner/name` 并部署。

之后每次 push main 自动重建并部署到 `/owner/name/`，中心主页自动出现新链接。
