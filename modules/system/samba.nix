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
      nas = {
        path = "/srv/shares/nas";
        "read only" = "no";
        "valid users" = "nas";
        "browseable" = "yes";
        comment = "NAS 个人目录（用户认证）";
      };
    };
  };

  # 共享用户 nas（同时是共享目录属主）
  users.users.nas = {
    isNormalUser = true;
    group = "users";
    createHome = true;
    home = "/srv/shares/nas";
  };

  # 共享目录骨架：public 对所有用户只读共享、nas 属主可写
  systemd.tmpfiles.rules = [
    "d /srv/shares 0755 root root -"
    "d /srv/shares/public 0775 root users -"
  ];

  # 激活时从 agenix 解密文件注入 Samba 口令（smbpasswd 独立口令库）
  # agenix 0.15 在 switch 激活阶段解密到 /run/agenix，服务启动时密钥已就绪
  systemd.services.samba-set-passwords = {
    description = "Apply Samba user passwords from agenix secrets";
    wantedBy = [ "multi-user.target" ];
    after = [ "samba-smbd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      pass=$(cat ${config.age.secrets.samba-nas-password.path})
      printf '%s\n%s\n' "$pass" "$pass" | ${pkgs.samba}/bin/smbpasswd -a -s nas
    '';
  };

  # 放行 SMB 端口
  networking.firewall.allowedTCPPorts = [ 139 445 ];
  networking.firewall.allowedUDPPorts = [ 137 138 ];
}
