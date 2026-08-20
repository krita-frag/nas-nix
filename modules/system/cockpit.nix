{ config, lib, pkgs, ... }:

# Cockpit：Web 系统状态监控与管理面板
{
  services.cockpit.enable = true;

  # 放行 Web 面板端口
  networking.firewall.allowedTCPPorts = [ 9090 ];
}
