{ config, lib, pkgs, ... }:

# Syncthing：多设备文件实时同步（去中心化，无云中转）
{
  services.syncthing = {
    enable = true;
    # 独立运行用户，避免以 root 同步文件；home=dataDir（模块自动建属主）
    user = "syncthing";
    dataDir = "/srv/syncthing";
    # 声明式管理设备与文件夹（初始为空，由 GUI 添加后固化）
    overrideDevices = true;
    overrideFolders = true;
    # GUI 默认仅本机可访问；启用密码认证后再对外（agenix 阶段）
    guiAddress = "127.0.0.1:8384";
  };

  # 同步通道：22000/tcp 对等传输、21027/udp 局域网发现
  networking.firewall.allowedTCPPorts = [ 22000 ];
  networking.firewall.allowedUDPPorts = [ 21027 ];
}
