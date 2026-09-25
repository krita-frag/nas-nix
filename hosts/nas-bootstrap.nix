# 首装最小系统（bootstrap）：SSH 密钥 + WiFi + agenix + Flakes。
# 只装系统能力、不装服务（Gitea/Podman/备份等），避免在安装介质有限的
# 内存里构建大闭包；系统启动后由 deploy.sh 推送 hosts/nas 完整配置。
{ config, modulesPath, ... }:

{
  imports = [
    ./nas/hardware-configuration.nix
    ../modules/system/ssh.nix
    ../modules/system/agenix.nix
  ];

  # 主机名与网络（NetworkManager 管理，WiFi 连接经 agenix 解密注入）
  networking.hostName = "nas";
  networking.networkmanager.enable = true;
  environment.etc."NetworkManager/system-connections/home-wifi.nmconnection" = {
    source = config.age.secrets.wifi-nm.path;
    mode = "0600";
  };

  # 引导器（UEFI）
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # 二进制缓存换源：清华 TUNA 优先（cache.nixos.org 由系统自动附加）
  nix.settings = {
    substituters = [
      "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
    ];
    experimental-features = [ "nix-command" "flakes" ];
  };

  # 声明式口令：root 密码哈希来自 agenix（见 modules/system/agenix.nix）
  users.mutableUsers = false;

  # 与 nixpkgs 通道一致
  system.stateVersion = "26.05";
}
