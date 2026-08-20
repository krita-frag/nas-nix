{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  # 主机名
  networking.hostName = "nas";
  # DHCP 网络（QEMU 虚拟网卡 enp0s1）
  networking.networkmanager.enable = true;

  # 引导器（UEFI）
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # SSH：密钥认证，禁用密码登录
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # 管理端公钥（macOS）
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGMhourtyuIlX/oTPUpsLzKlv2xU7aEkWld4pj8ucm2D cc567821@163.com"
  ];

  # 系统版本（与 nixpkgs 通道一致，首次安装后不再变更）
  system.stateVersion = "26.05";
}
