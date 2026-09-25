# 实机硬件配置（x86_64 UEFI，4C/7.5G）
# 磁盘布局：nvme0n1 系统盘（p1 ESP 1G vfat = NIXBOOT，p2 ext4 根 = NIXROOT）；
# sda 1TB 数据盘（GPT 单分区 ext4 = SRVDATA，挂载 /srv 承载 NAS 数据）。
{ config, lib, pkgs, modulesPath, ... }:

{
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usbhid" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    { device = "/dev/disk/by-label/NIXROOT";
      fsType = "ext4";
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-label/NIXBOOT";
      fsType = "vfat";
      options = [ "fmask=0022" "dmask=0022" ];
    };

  # 数据盘：1TB HDD 单分区 ext4，承载 /srv（shares/syncthing/gitea 等数据根）
  fileSystems."/srv" =
    { device = "/dev/disk/by-label/SRVDATA";
      fsType = "ext4";
    };

  # NVMe 根分区上的交换文件（zram 压缩交换之外的磁盘兜底，NixOS 自动创建）
  swapDevices = [ { device = "/swap/swapfile"; size = 8192; } ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
