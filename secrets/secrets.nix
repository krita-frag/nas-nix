# agenix CLI 加密规则
# 本文件仅供 `agenix` CLI 使用（在此目录下运行），不导入 NixOS 配置。
# 每个 .age 文件列出允许解密的主机/用户公钥；CLI 将公钥直接传给
# `age --recipient`，使用 age 原生 SSH 接收者（ssh-ed25519 段），
# 与部署机 `age -d -i /etc/ssh/ssh_host_ed25519_key` 完全兼容。
let
  # NAS 主机 SSH 公钥：部署机用 /etc/ssh/ssh_host_ed25519_key 自解密
  # （2026-09 实机装机时生成并烧入 /mnt/etc/ssh/ssh_host_ed25519_key）
  nas = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIVwderuYNoKO1o7TjSTLYH3La0Ipq2QOjkf7CoTUvff root@nas";
  # 实机（192.168.5.93，主机名 nas）SSH 主机公钥：为系统盘 /etc/ssh/ssh_host_ed25519_key
  # 上实际存在的主机钥（openssh 激活时自造并保留），与全部 secret 的接收者一致，
  # agenix 用 /etc/ssh/ssh_host_ed25519_key 即能自解密联网。
  nas-real = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDopplkxmcNGIgcsOVpO9+F2UWxm9JhFUcJlZZgeo+CY root@nas";
  # 管理机（macOS）SSH 公钥：从本机编辑/解密密钥
  admin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGMhourtyuIlX/oTPUpsLzKlv2xU7aEkWld4pj8ucm2D cc567821@163.com";
in
{
  "tailscale-auth.age".publicKeys = [ nas nas-real admin ];
  "samba-nas-password.age".publicKeys = [ nas nas-real admin ];
  # root 的登录口令哈希（Cockpit 等 PAM 认证用）
  "root-password-hash.age".publicKeys = [ nas nas-real admin ];
  # restic 备份仓库口令（见 modules/services/backup.nix）
  "restic-repo-password.age".publicKeys = [ nas nas-real admin ];
  # rclone 远端凭据（rclone:<remote>: 桥接备份仓库时使用；实机接入后生成文件）
  "rclone-conf.age".publicKeys = [ nas nas-real admin ];
  # 家庭 WiFi NetworkManager 连接配置（含 PSK；nas/nas-real 双机 + 管理机可解）
  "wifi-nm.age".publicKeys = [ nas nas-real admin ];
}
