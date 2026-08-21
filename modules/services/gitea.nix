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
        - ubuntu-latest:docker://node:16-bullseye
        - ubuntu-22.04:docker://node:16-bullseye
        - ubuntu-20.04:docker://node:16-bullseye

    container:
      privileged: false
      network: ""
      force_pull: false
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
    serviceConfig = {
      User = "gitea-runner";
      Group = "gitea-runner";
      WorkingDirectory = "/var/lib/gitea-runner";
      StateDirectory = "gitea-runner";
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
}
