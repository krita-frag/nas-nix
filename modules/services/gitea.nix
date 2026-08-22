{ config, lib, pkgs, ... }:

# Gitea：自托管 Git 服务 + Actions 持续集成
# 轻量取向：Gitea 原生 systemd 服务 + SQLite（不引入数据库容器）；
# Actions 由 act_runner 执行（nixpkgs 内二进制名为 gitea-runner），
# 底层经 Podman 的 Docker 兼容 socket 运行 job 容器，不依赖 Docker 守护进程。
{
  # Gitea 本体：原生服务 + SQLite，数据在 /var/lib/gitea
  services.gitea = {
    enable = true;
    database.type = "sqlite3";

    settings = {
      server = {
        HTTP_PORT = 3000;
        # 经系统 SSH（22）提供 git 克隆，复用现有 openssh
        DISABLE_SSH = false;
        SSH_PORT = 22;
      };
      # 启用 Actions（由 gitea-runner 消费）
      actions.ENABLED = true;
      # 内置 OCI Container Registry：自托管服务的镜像仓库
      # （Gitea 默认已启用，此处显式声明以文档化）
      packages.ENABLED = true;
      "packages.registry".ENABLED = true;
      # 关闭匿名自助注册：防外部主体进入信任圈（注册入知识库即获得站点写入能力），
      # 账号一律由管理员后台创建
      service.DISABLE_REGISTRATION = true;
    };
  };

  # --- act_runner：GitHub Actions 兼容执行器 ---
  # 运行用户；podman 组成员以访问 /run/docker.sock
  users.users.gitea-runner = {
    isSystemUser = true;
    group = "gitea-runner";
    extraGroups = [ "podman" ];
  };
  users.groups.gitea-runner = { };

  # runner 配置（无敏感信息）：job 容器经 Podman 的 Docker 兼容 socket 运行
  environment.etc."gitea-runner/config.yaml".text = ''
    log:
      level: info

    runner:
      file: .runner
      capacity: 1
      timeout: 3h
      fetch_timeout: 10s
      fetch_interval: 2s
      labels:
        # 标准环境：node:20-bookworm（Debian Bookworm + node + bash/git/curl）
        # 兼容 ubuntu 生态；各 ubuntu-* runs-on 统一指向该镜像，减少镜像拉取种类
        - ubuntu-latest:docker://node:20-bookworm
        - ubuntu-22.04:docker://node:20-bookworm
        - ubuntu-20.04:docker://node:20-bookworm
        # 轻量镜像：体积小、启动快，适合纯命令/工具类任务
        # 注意：均不含 bash，workflow 需指定 shell: sh，或先安装依赖（apk/apt）
        # 如使用 actions/checkout 等 bash 脚本 action，请改用 ubuntu-latest
        - alpine:docker://docker.io/library/alpine:3.20
        - node:docker://node:20-alpine
        - debian:docker://debian:bookworm-slim
        # 预烘焙镜像：一次构建把 git/python3 与 mkdocs（/opt/venv）装进镜像，
        # 免去每次运行 apt-get/pip 的重复耗时；本地构建（runner/build-kb-image.sh），
        # 配合 force_pull:false 命中本地镜像不联网拉取
        - kb-builder:docker://127.0.0.1:3000/kb-builder:latest
        # 本机直跑：job 在宿主以 gitea-runner 用户直接执行（无容器/镜像/apt-get，最快）。
        # 信任边界扩大——仓库代码可在宿主以 gitea-runner 权限运行，仅限受信任仓库使用
        - nas-host:host
        
    container:
      privileged: false
      # host 网络：默认情况下 act_runner 为每个 job 创建隔离桥接网络，
      # 容器内 127.0.0.1 指向容器自身而非宿主，workflow 将无法访问本机 Gitea
      # （git clone / push 均走 127.0.0.1:3000）。改用宿主网络后，容器与宿主
      # 共享网络命名空间，127.0.0.1:3000 直接可达，且不依赖任何具体 IP，VM 与
      # 实机均可移植。
      network: "host"
      force_pull: false
      # 挂载知识库站点根：nas-docs 引擎 workflow 直接写入聚合构建产物
      # （Gitea HTTP 推送不执行 post-receive.d 钩子，故由 runner 容器部署）
      # 另挂载构建缓存目录 /kb-cache：复用 venv 与 pip 缓存，避免每次重建重复下载依赖
      # 注意：act 仅允许挂载 valid_volumes 白名单内的宿主路径，未列入会被静默忽略
      options: "-e HOME=/root -v /var/www/docs:/var/www/docs -v /var/lib/gitea-runner/kb-cache:/kb-cache"
      valid_volumes:
        - /var/www/docs
        - /var/lib/gitea-runner/kb-cache
      docker_host: unix:///run/docker.sock

    # Actions 缓存目录：置于 runner 状态目录内（系统用户 HOME=/var/empty 无写权限）
    cache:
      enabled: true
      dir: /var/lib/gitea-runner/cache
  '';

  systemd.services.gitea-runner = {
    description = "Gitea Actions runner (Podman backend)";
    wantedBy = [ "multi-user.target" ];
    after = [ "gitea.service" "podman.socket" ];
    wants = [ "gitea.service" ];
    # nas-host（本机直跑）依赖：job 继承宿主工具。path 指向 config.system.path
    # （systemPackages 聚合），故 tools.nix 预装的 git/python3/go/rust/make 等
    # 对 host job 全部可见，免每次 apt-get/下载安装；bash 由系统自带
    path = [ config.system.path ];
    serviceConfig = {
      User = "gitea-runner";
      Group = "gitea-runner";
      WorkingDirectory = "/var/lib/gitea-runner";
      StateDirectory = "gitea-runner";
      # HOME 指向可写状态目录：系统用户默认 /var/empty 只读，host job 的 git 全局配置、
      # 缓存等需要可写
      # no_proxy：宿主系统级默认走代理（http_proxy 指向管理机），而 job 需直连本机
      # Gitea（127.0.0.1:3000）。无 no_proxy 时 git clone 经代理访问本机 127.0.0.1
      # 返回 502（代理无法访问 NAS 自身）。声明 no_proxy 让本机访问绕过代理
      Environment = [
        "HOME=/var/lib/gitea-runner"
        "no_proxy=127.0.0.1,localhost"
        "NO_PROXY=127.0.0.1,localhost"
      ];
      Restart = "on-failure";
      RestartSec = 10;
    };
    # 首次注册：在 Gitea 后台生成的注册令牌写入
    # /var/lib/gitea-runner/registration-token 后自动注册（一次性）
    preStart = ''
      if [ -f .runner ]; then
        exit 0
      fi
      if [ ! -f /var/lib/gitea-runner/registration-token ]; then
        echo "gitea-runner 未注册：请在 Gitea 后台生成注册令牌并写入 /var/lib/gitea-runner/registration-token，再 systemctl restart gitea-runner" >&2
        exit 1
      fi
      ${pkgs.gitea-actions-runner}/bin/gitea-runner register \
        --instance "http://127.0.0.1:3000/" \
        --token "$(cat /var/lib/gitea-runner/registration-token)" \
        --no-interactive \
        --name "nas-runner" \
        --config /etc/gitea-runner/config.yaml
    '';
    script = ''
      ${pkgs.gitea-actions-runner}/bin/gitea-runner daemon --config /etc/gitea-runner/config.yaml
    '';
  };

  # 放行 Gitea Web 端口
  networking.firewall.allowedTCPPorts = [ 3000 ];

  # 尾网 HTTPS 入口：Gitea Web 经 tailscale serve 挂到尾网（https://<机器名>.ts.net:8443/），
  # 有效证书、仅 tailnet 内可达；与 docs 共用 443 之外独立端口，无需改动 Gitea ROOT_URL。
  # 机制见通用模块 tailscale-serve.nix
  services.tailscaleServe.rules = [{
    name = "gitea";
    https = 8443;
    target = "http://127.0.0.1:3000";
  }];
}
