{ config, lib, pkgs, ... }:

# agenix：敏感数据声明式解密
# 加密文件位于本目录（secrets/*.age），随仓库提交，明文不落盘
{
  age.secrets = {
    # Tailscale 认证密钥（管理端用 `agenix -e` 编辑为真实密钥后重新部署）
    "tailscale-auth" = {
      file = ./tailscale-auth.age;
      owner = "root";
      group = "root";
      mode = "0400";
    };
    # Samba 用户 nas 的口令
    "samba-nas-password" = {
      file = ./samba-nas-password.age;
      owner = "root";
      group = "root";
      mode = "0400";
    };
  };
}
