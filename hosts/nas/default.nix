{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    ./hardware-configuration.nix
    # 系统层模块
    ../../modules/system/ssh.nix
    ../../modules/system/tailscale.nix
    ../../modules/system/samba.nix
    ../../modules/system/cockpit.nix
    ../../modules/system/podman.nix
    ../../modules/system/tools.nix
    ../../modules/system/memory.nix
    ../../modules/system/nix-gc.nix
    ../../modules/services/syncthing.nix
    ../../modules/services/gitea.nix
    ../../modules/services/docs.nix
    # agenix 密钥声明（加密文件在 secrets/*.age，规则文件 secrets/secrets.nix 仅供 CLI 使用）
    ../../modules/system/agenix.nix
  ];

  # 主机名
  networking.hostName = "nas";
  # DHCP 网络（由 NetworkManager 管理，虚拟网卡或实机网卡均可）
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

  # 声明式口令管理：用户口令完全由配置（含 agenix 密钥）决定，
  # 运行时 passwd 改动在下次重建时还原，保证系统可复现与干净。
  users.mutableUsers = false;

  # 统一知识库中心：引擎（nas-docs）push main / 6h 定时 / 手动 dispatch 经 Actions
  # 聚合构建所有注册知识库并写入站点根，Caddy 静态服务（见 modules/services/docs.nix）。
  # 注册新知识库：在引擎仓库 repos.json 的 repos 列表加一行即可（无需改本文件）。
  services.docs = {
    enable = true;
  };
}
