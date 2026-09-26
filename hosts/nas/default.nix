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
    ../../modules/system/monitoring.nix
    ../../modules/services/syncthing.nix
    ../../modules/services/gitea.nix
    ../../modules/services/docs.nix
    ../../modules/services/tailscale-serve.nix
    ../../modules/services/backup.nix
    ../../modules/services/rustdesk.nix
    ../../modules/services/pkg-mirror.nix
    # NPanel：NixOS 原生 Web 门面（flake input 来自本机 Gitea 镜像，见 flake.nix）
    ../../modules/services/npanel.nix
    # agenix 密钥声明（加密文件在 secrets/*.age，规则文件 secrets/secrets.nix 仅供 CLI 使用）
    ../../modules/system/agenix.nix
  ];

  # 主机名
  networking.hostName = "nas";
  # DHCP 网络（由 NetworkManager 管理，虚拟网卡或实机网卡均可）
  networking.networkmanager.enable = true;

  # mDNS 局域网主机名：启用 avahi，同 LAN 内可用 nas.local 访问（Web/SMB），
  # 不依赖局域网 IP（IP 漂移/换网段主机名不变）。
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

  # 家庭 WiFi：NM 连接配置（含 PSK）经 agenix 解密后注入 system-connections。
  # 双频同名路由：5GHz（autoconnect-priority=10）优先、2.4GHz 兜底，NM 开机自动连接；
  # 有线口接入时 NM 同样自动 DHCP，无需额外配置。
  environment.etc."NetworkManager/system-connections/home-wifi.nmconnection" = {
    source = config.age.secrets.wifi-nm.path;
    mode = "0600";
  };

  # 硬件固件：安装介质自带全套固件（wlo1 可用），但最小安装默认不带任何
  # 固件（enableRedistributableFirmware 缺省 = enableAllFirmware = false），
  # WiFi 驱动因缺固件无法 probe、网卡直接消失。必须显式开启。
  hardware.enableRedistributableFirmware = true;

  # 引导器（UEFI + GRUB，GPT 分区表）：与 nas-bootstrap 保持一致，
  # 避免 deploy 切换时从 systemd-boot 换成 grub 引入引导器变更风险。
  # efiInstallAsRemovable 写入 ESP 的 EFI/BOOT/BOOTX64.EFI 回退文件，
  # 固件回退扫描可命中；canTouchEfiVariables=false，残留 NVRAM 项进系统后用 efibootmgr 清。
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
    # 启用 Flakes 与 nix-command（远程构建所需）
    experimental-features = [ "nix-command" "flakes" ];
  };

  # swap 文件父目录：hardware-configuration.nix 声明 /swap/swapfile，
  # mkswap 单元不会自建父目录（2026-09-09 实机部署时踩坑），tmpfiles 兜底创建
  systemd.tmpfiles.rules = [ "d /swap 0700 root root -" ];

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

  # RustDesk 内网远程桌面：hbbs(ID) + hbbr(中继)，见 modules/services/rustdesk.nix
  # lanInterfaces 限定端口放行的内网网卡（另有 tailscale0 始终放行）；
  # 有线口未接线时同样列出，插网线即可用。
  services.rustdesk = {
    enable = true;
    lanInterfaces = [ "enp1s0" "enp3s0" "wlo1" ];
  };

  # 局域网专用包服务器：统一入口 http://nas.local:8081（多语言一套配置）
  #   /pypi/  Python（devpi 按需缓存 PyPI + 私有索引）
  #   /go/    Go（athens，GOPROXY 按需缓存）
  #   /crates/ /crates-dl/  Rust（cargo 稀疏索引缓存转发）
  #   /npm/   npm（registry 缓存转发）
  #   /raw/   Zig 依赖包、C++ 预编译产物、私有 wheel（Samba 共享 pkg-raw 投放）
  # 其余可选项（Nix 二进制缓存 / 尾网 HTTPS）默认关闭，见模块内注释。
  # 客户端配置与运维见 docs/package-mirror.md。
  services.pkgMirror = {
    enable = true;
  };

  # 尾网 HTTPS 入口：Docs(:443 根)、Gitea(:8443)、Cockpit(:9443) 经 tailscale serve
  # 挂到尾网稳定主机名 https://nas-1.tailf2ba32.ts.net[;PORT]（有效证书、仅 tailnet 可达），
  # 不依赖局域网 IP（IP 漂移/换网段主机名不变）。见 modules/services/tailscale-serve.nix。
  services.tailscaleServe = {
    enable = true;
    rules = [
      { name = "docs";    https = 443;  target = "http://127.0.0.1:8080"; }
      { name = "gitea";   https = 8443; target = "http://127.0.0.1:3000"; }
      { name = "cockpit"; https = 9443; target = "https://127.0.0.1:9090"; }
    ];
  };

  # 集中备份：restic 加密快照。本地测试仓库曾把本机盘写满（94G / 116G，2026-09-26），
  # 已删除并停用：repository 留空即禁用备份服务（见 modules/services/backup.nix）。
  # 启用前先把 repository 指到真实目标（S3 原生或 rclone:<remote>:<path>），
  # 严禁再指向本机磁盘。
  services.backup = {
    enable = true;
    repository = "";
  };
}
