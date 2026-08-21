{ config, lib, pkgs, ... }:

# Podman：无守护进程的 OCI 容器运行时（原生替代 Docker）
{
  virtualisation.podman = {
    enable = true;
    # 提供 docker 命令兼容（转发到 podman），便于沿用既有 Docker 工作流
    dockerCompat = true;
    # Docker 兼容 API socket（/run/docker.sock，podman 组可连）：
    # 供 gitea-runner 等以 Docker API 驱动的工具经 Podman 运行容器
    dockerSocket.enable = true;
    # 定期清理无用镜像与中间层，保持系统干净
    autoPrune.enable = true;
  };

  # 国内访问 Docker Hub 镜像加速：podman 合并 /etc/containers/registries.conf.d/ 追加文件
  environment.etc."containers/registries.conf.d/docker-hub-mirrors.conf".text = ''
    [[registry]]
    prefix = "docker.io"
    location = "docker.io"

    [[registry.mirror]]
    location = "docker.1panel.live"

    [[registry.mirror]]
    location = "docker.m.daocloud.io"

    [[registry.mirror]]
    location = "docker.1ms.run"
  '';
}
