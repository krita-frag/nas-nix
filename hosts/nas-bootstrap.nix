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

  # 硬件固件：安装介质自带全套固件（wlo1 可用），但最小安装默认不带任何
  # 固件（enableRedistributableFirmware 缺省 = enableAllFirmware = false），
  # WiFi 驱动因缺固件无法 probe、网卡直接消失。首装后要能连 WiFi 必须显式开启。
  hardware.enableRedistributableFirmware = true;
  environment.etc."NetworkManager/system-connections/home-wifi.nmconnection" = {
    source = config.age.secrets.wifi-nm.path;
    mode = "0600";
  };

  # 引导器（UEFI + GRUB，GPT 分区表）：
  # - efiSupport：安装 grubx64.efi 到 ESP 并注册 NVRAM 引导项
  # - efiInstallAsRemovable：同时写入 ESP 的 EFI/BOOT/BOOTX64.EFI 回退文件，
  #   固件回退扫描（\EFI\BOOT\BOOTX64.EFI）也能命中，双保险
  # 说明：efiInstallAsRemovable 与 canTouchEfiVariables 互斥（NixOS 断言），
  # 实机固件依赖回退扫描，故关闭 NVRAM 写入，由 efibootmgr 手动补注册。
  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  boot.loader.efi.canTouchEfiVariables = false;

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
