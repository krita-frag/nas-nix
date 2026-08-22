{ config, lib, pkgs, ... }:

# SSH：密钥认证，禁用密码登录；限尝试次数并保持长连接探活（防御纵深）
{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      MaxAuthTries = 3;
      ClientAliveInterval = 120;
      ClientAliveCountMax = 3;
    };
  };

  # 管理端公钥（macOS）
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGMhourtyuIlX/oTPUpsLzKlv2xU7aEkWld4pj8ucm2D cc567821@163.com"
  ];
}
