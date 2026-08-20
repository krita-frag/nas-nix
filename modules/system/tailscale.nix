{ config, lib, pkgs, ... }:

# Tailscale：安全组网与远程访问
{
  services.tailscale = {
    enable = true;
    # 首次加入组网时以 agenix 解密文件中的认证密钥自动登录
    authKeyFile = config.age.secrets.tailscale-auth.path;
  };
}
