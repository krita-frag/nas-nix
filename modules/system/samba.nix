{ config, lib, pkgs, ... }:

# Samba：家庭文件共享
{
  services.samba = {
    enable = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "NixOS NAS";
        "security" = "user";
        "map to guest" = "Bad User";
      };
      public = {
        path = "/srv/shares/public";
        "read only" = "no";
        "guest ok" = "yes";
        "browseable" = "yes";
        comment = "公共共享目录";
      };
    };
  };

  # 共享目录骨架（用户认证共享在 agenix 阶段扩展）
  systemd.tmpfiles.rules = [
    "d /srv/shares 0755 root root -"
    "d /srv/shares/public 0775 root users -"
  ];

  # 放行 SMB 端口
  networking.firewall.allowedTCPPorts = [ 139 445 ];
  networking.firewall.allowedUDPPorts = [ 137 138 ];
}
