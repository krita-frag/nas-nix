{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    ./hardware-configuration.nix
    # 系统层模块
    ../../modules/system/ssh.nix
    ../../modules/system/tailscale.nix
    ../../modules/system/samba.nix
    ../../modules/system/cockpit.nix
    ../../modules/system/docker.nix
    ../../modules/system/zram.nix
    ../../modules/system/nix-gc.nix
    # 应用容器层模块
    ../../modules/services/portainer.nix
    ../../modules/services/syncthing.nix
    # agenix 密钥声明
    ../../secrets/secrets.nix
  ];

  # 主机名
  networking.hostName = "nas";
  # DHCP 网络（QEMU 虚拟网卡 enp0s1）
  networking.networkmanager.enable = true;

  # 引导器（UEFI）
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # 二进制缓存换源：清华 TUNA 优先（cache.nixos.org 由系统自动附加）
  nix.settings = {
    substituters = [
      "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
    ];
    # 启用 Flakes 与 nix-command（远程构建所需）
    experimental-features = [ "nix-command" "flakes" ];
  };

  # 系统版本（与 nixpkgs 通道一致，首次安装后不再变更）
  system.stateVersion = "26.05";
}
