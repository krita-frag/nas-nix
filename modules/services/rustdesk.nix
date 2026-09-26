{ config, lib, pkgs, ... }:

# RustDesk 内网远程桌面服务端：hbbs（ID/信使）+ hbbr（中继）。
# 局域网内客户端填：
#   ID/中继服务器 = <nas>.local  端口按默认；Key = dataDir/id_ed25519.pub 内容
# 首次 hbbs 启动在 dataDir 生成 id_ed25519(.pub)，客户端需用该公钥做认证。
{
  options.services.rustdesk = {
    enable = lib.mkEnableOption "RustDesk 内网远程桌面服务端（hbbs + hbbr）";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/srv/rustdesk";
      description = "数据/密钥目录（首启生成 id_ed25519.pub 供客户端）";
    };

    lanInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "enp1s0" "wlo1" ];
      description = ''
        允许访问 RustDesk 端口的局域网网卡名。端口仅在这些网卡与 tailscale0 上放行。
        hbbs/hbbr 不支持绑定地址（--help 无 bind 选项），只能由防火墙按接口收窄；
        本机 IPv6 为全局地址，LAN 与外网客户端地址形态相同，故无法用源地址区分。
      '';
    };
  };

  config = lib.mkIf config.services.rustdesk.enable {
    systemd.tmpfiles.rules = [
      "d ${config.services.rustdesk.dataDir} 0755 root root -"
    ];

    systemd.services = {
      rustdesk-hbbs = {
        description = "RustDesk ID/rendezvous server (hbbs)";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.rustdesk-server}/bin/hbbs";
          WorkingDirectory = config.services.rustdesk.dataDir;
          Restart = "on-failure";
          RestartSec = "2s";
        };
      };
      rustdesk-hbbr = {
        description = "RustDesk relay server (hbbr)";
        after = [ "network.target" ];
        wants = [ "rustdesk-hbbs.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.rustdesk-server}/bin/hbbr";
          WorkingDirectory = config.services.rustdesk.dataDir;
          Restart = "on-failure";
          RestartSec = "2s";
        };
      };
    };

    # 端口：21115(TCP NAT 探测)/21116(TCP+UDP 数据与心跳)/21117(TCP 中继)
    # 仅在内网网卡与 tailscale0 放行，公网（含全局 IPv6）不可达。
    networking.firewall.interfaces = lib.genAttrs
      ([ "tailscale0" ] ++ config.services.rustdesk.lanInterfaces)
      (_: {
        allowedTCPPorts = [ 21115 21116 21117 ];
        allowedUDPPorts = [ 21116 ];
      });
  };
}