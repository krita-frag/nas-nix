{ config, lib, pkgs, ... }:

# Docker：容器运行时底座（应用容器层宿主）
{
  virtualisation.docker = {
    enable = true;
    # 国内网络无法直连 Docker Hub，走可用镜像加速源（按优先级降序）
    daemon.settings = {
      registry-mirrors = [
        "https://docker.1panel.live"
        "https://docker.m.daocloud.io"
        "https://docker.1ms.run"
      ];
    };
  };
}
