{ config, lib, pkgs, ... }:

# Cockpit：Web 系统状态监控与管理面板
{
  services.cockpit.enable = true;
  # 插件经 plugins 声明（打包进 Cockpit 运行环境，而非散落 systemPackages）：
  # - cockpit-podman  容器管理（独立包）
  # - cockpit-files   文件浏览（独立包，面板内直接管理共享目录）
  # storaged / networkmanager / users 等核心插件随 cockpit 主包内置，无需声明
  services.cockpit.plugins = with pkgs; [
    cockpit-podman
    cockpit-files
  ];

  # Cockpit 内置的 kdump（内核转储）模块依赖 kexec-tools 提供的崩溃转储服务
  environment.systemPackages = [ pkgs.kexec-tools ];

  # 允许 WebSocket 的来源（模块默认仅放行 https://localhost:9090）。
  # 主机部分用 fnmatch 通配符 `*`，与具体 IP/网段无关——无论是虚拟机、
  # 实机局域网还是 Tailscale 域名都能访问；端口引用 cockpit 配置项避免硬编码。
  # 安全性：仍要求 Origin 必须为 https 且端口为 9090，跨站 WebSocket 仍被拦截。
  services.cockpit.allowed-origins = [
    "https://*:${toString config.services.cockpit.port}"
  ];

  # 放行 Web 面板端口
  networking.firewall.allowedTCPPorts = [ 9090 ];
}
