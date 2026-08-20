{ config, lib, pkgs, ... }:

# Portainer：Docker 容器管理面板（依赖 docker.nix 容器运行时）
{
  virtualisation.oci-containers = {
    backend = "docker";
    containers.portainer = {
      image = "portainer/portainer-ce:latest";
      # 面板 HTTPS 端口 9443；数据与 docker.sock 持久化挂载
      ports = [ "9443:9443" ];
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
        "portainer_data:/data"
      ];
    };
  };

  # 放行管理面板端口（经 Tailscale 访问，非公网暴露）
  networking.firewall.allowedTCPPorts = [ 9443 ];
}
