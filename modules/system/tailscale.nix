{ config, lib, pkgs, ... }:

# Tailscale：安全组网与远程访问
{
  services.tailscale.enable = true;
  # 认证密钥由 agenix 解密文件提供（接入 agenix 阶段启用）：
  # services.tailscale.authKeyFile = config.age.secrets.tailscale-auth.path;
}
