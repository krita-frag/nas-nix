{ config, lib, pkgs, ... }:

# agenix：敏感数据声明式解密
# 加密文件位于 secrets/*.age，随仓库提交；部署时用主机 SSH 私钥解密，
# 挂载到 /run/agenix/<name>，明文不落盘。
{
  age.secrets = {
    # Tailscale 认证密钥（首次加入组网时自动登录）
    "tailscale-auth" = {
      file = ../../secrets/tailscale-auth.age;
      owner = "root";
      group = "root";
      mode = "0400";
    };
    # Samba 用户 nas 的口令
    "samba-nas-password" = {
      file = ../../secrets/samba-nas-password.age;
      owner = "root";
      group = "root";
      mode = "0400";
    };
    # root 的登录口令哈希（Cockpit 等 PAM 认证用；SSH 仍为密钥认证）
    "root-password-hash" = {
      file = ../../secrets/root-password-hash.age;
      owner = "root";
      group = "root";
      mode = "0400";
    };
  };

  # root 口令来自 agenix 解密文件，明文不入库、不落盘
  users.users.root.hashedPasswordFile = config.age.secrets.root-password-hash.path;
}
