{ config, lib, pkgs, ... }:

# Tailscale Serve 多服务 HTTPS 入口：把本机 HTTP 服务经 tailscale serve 挂到尾网
# HTTPS（https://<机器名>.ts.net/[:端口]），有效证书、无公网暴露、仅 tailnet 内可达。
# 服务模块只需向 services.tailscaleServe.rules 追加条目（name/https/target）即可暴露。
#
# Serve 需在 tailnet 管理台启用（https://login.tailscale.com/admin）；未启用时
# `tailscale serve --bg` 会挂起而非报错退出，故用 timeout 兜底并静默成功，
# 服务始终 active（exited），不制造失败噪音；配套低频 timer 重新应用配置，
# 管理台启用 Serve 后自动生效，无需重启。
{
  options.services.tailscaleServe = {
    enable = lib.mkEnableOption "Tailscale Serve 多服务 HTTPS 入口";

    rules = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "规则名（日志/注释用）";
          };
          https = lib.mkOption {
            type = lib.types.port;
            default = 443;
            description = "尾网 HTTPS 端口";
          };
          target = lib.mkOption {
            type = lib.types.str;
            description = "本机目标地址（http://127.0.0.1:PORT）";
          };
        };
      });
      default = [ ];
      description = "需要经尾网 HTTPS 暴露的本机 HTTP 服务";
    };
  };

  config = lib.mkIf config.services.tailscaleServe.enable {
    systemd.services.tailscale-serve = {
      description = "Expose services over tailnet HTTPS (tailscale serve)";
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      # --bg 幂等：已配置则立即返回；Serve 未启用时挂起，由 timeout 兜底后静默成功
      script = lib.concatMapStringsSep "\n" (rule: ''
        timeout 5 ${pkgs.tailscale}/bin/tailscale serve --bg --https=${toString rule.https} ${rule.target} || true
      '') config.services.tailscaleServe.rules;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
    };

    # 低频重跑 serve 配置：Serve 在管理台启用后自动生效，无需重启/开机
    systemd.timers.tailscale-serve = {
      description = "Periodically (re)apply tailscale serve rules";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "6h";
        Persistent = true;
      };
    };
  };
}
