# 自托管服务一键部署（Gitea → NAS）

在 Gitea 仓库开发工具/网站/服务后，如何一键在 NAS（NixOS）上部署测试。整体链路：

```
git push → Gitea Actions（Podman 后端构建镜像）
        → 推入 Gitea 内置 Container Registry（127.0.0.1:3000）
        → NAS 本机 Podman 部署（开发期 docker run / 稳定期 Quadlet+systemd 托管）
```

关键前提（本仓库已配置）：

- act_runner 运行于 NAS 本机，job 容器经 `/run/docker.sock` 直通宿主 Podman，
  因此 **Actions 里 `docker build` 的镜像直接出现在宿主 `podman images`**；
- Gitea 已启用内置 OCI Container Registry（`packages.ENABLED`）；
- Podman 已配置 insecure registry：`127.0.0.1:3000`（HTTP，无需 TLS）。

## 1. Actions 部署工作流（开发/测试循环）

在项目仓库新建 `.gitea/workflows/deploy.yaml`（模板）：

```yaml
name: build-and-deploy
on: [push]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # 登录本机 Gitea registry（owner 用你的 Gitea 账号，
      # GITEA_TOKEN 为仓库 Secret，在 Gitea 设置中创建，需 packages 写权限）
      - name: Login registry
        run: |
          docker login 127.0.0.1:3000 \
            -u <你的Gitea用户名> \
            -p ${{ secrets.GITEA_TOKEN }}

      - name: Build & push image
        run: |
          IMG=127.0.0.1:3000/<owner>/<repo>:latest
          docker build -t "$IMG" .
          docker push "$IMG"

      # 本机部署（Web 服务：端口映射；工具/定时任务见第 3 节）
      - name: Deploy to NAS
        run: |
          docker rm -f <服务名> || true
          docker run -d --name <服务名> \
            --restart unless-stopped \
            -p <宿主端口>:<容器端口> \
            127.0.0.1:3000/<owner>/<repo>:latest
```

说明：

- `docker push` 后镜像即长期保存在 NAS 的 Podman 镜像存储与 Gitea registry 中，
  换 tag（如 `:v1.2.3`）即可多版本并存、随时回滚；
- 经 docker socket 启动的容器由 rootful Podman 管理，`podman ps` 与
  Cockpit → Podman 容器视图均可看到；
- 开发期临时测试可用 `docker run`，容器随系统不保证重启——稳定化见第 2 节。

## 2. 稳定化：Podman Quadlet + systemd 托管

需要开机自启、失败重启的服务，用 Quadlet（systemd 原生管理容器）固化。
Quadlet 文件放 `/etc/containers/systemd/`，systemd 自动生成 unit 并托管。
在 NixOS 侧以 `environment.etc` 声明（模板 `docs/quadlet.example.container`）：

```nix
environment.etc."containers/systemd/<服务名>.container".text = ''
  [Unit]
  Description=<服务描述>

  [Container]
  Image=127.0.0.1:3000/<owner>/<repo>:latest
  # 从 Gitea registry 拉取需登录凭据：Quadlet 也读取 $HOME/.docker/config.json
  # 或改 Image= 为 public 镜像；亦可用 EnvironmentFile 注入凭据
  PublishPort=<宿主端口>:<容器端口>
  Volume=<数据卷>:<容器内路径>

  [Service]
  Restart=on-failure
'';
```

Quadlet 文件写好并通过 `systemctl daemon-reload && systemctl start <服务名>` 验证后，
把该 `environment.etc` 片段并入对应服务模块（`modules/services/<name>.nix`），
随仓库 `./deploy.sh` 声明式部署——服务纳入 NixOS generation，可随系统回滚。

## 3. 工具 / 定时任务类服务

- **CLI 工具**：NAS 已装 Nix，直接 `nix run nixpkgs#<工具>` 或项目内 `nix develop` 运行，
  无需容器化；
- **定时任务**：以 systemd timer 声明（NixOS `systemd.timers`），无需常驻容器；
- **需要容器化的一次性任务**：Actions 内 `docker run --rm` 执行后退出。

## 4. 验证

```bash
podman images                       # 应见 127.0.0.1:3000/<owner>/<repo> 镜像
podman ps                           # 部署的容器在运行
curl -sf http://<nas-ip>:<端口>/     # Web 服务响应
systemctl list-units | grep <服务名> # Quadlet 托管的 unit
```

## 5. 回滚

- **容器 tag 回滚**：改 workflow 的 tag 并重新 push，或 `podman tag` 旧版本镜像后
  `docker run` 旧 tag；
- **NixOS 回滚**：Quadlet 固化后 `./deploy.sh rollback` 原子回到上一代。
