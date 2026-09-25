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
    networking.firewall.allowedTCPPorts = [ 21115 21116 21117 ];
    networking.firewall.allowedUDPPorts = [ 21116 ];
  };
}