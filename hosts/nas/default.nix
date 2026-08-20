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
  ];

  # 主机名
  networking.hostName = "nas";
  # DHCP 网络（QEMU 虚拟网卡 enp0s1）
  networking.networkmanager.enable = true;

  # 引导器（UEFI）
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # 二进制缓存换源：清华 TUNA 优先（cache.nixos.org 由系统自动附加）
  nix.settings.substituters = [
    "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
  ];

  # 系统版本（与 nixpkgs 通道一致，首次安装后不再变更）
  system.stateVersion = "26.05";
}
