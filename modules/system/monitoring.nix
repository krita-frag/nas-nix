{ config, lib, pkgs, ... }:

# 主动健康监控：每小时检查磁盘水位与关键服务状态，异常写入 journald（tag: nas-monitor）。
# 设计取向：不引入额外面板/依赖，仅 systemd timer + 轻量脚本；告警落点 journald，
# 可用 `journalctl -t nas-monitor` 查看。可选 notifyCommand：告警全文经 stdin 传给
# 通知命令（如 ntfy/Apprise/脚本），留空则仅写 journald，后续可扩展其他通知渠道。
{
  options.services.monitoring = {
    notifyCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "告警通知命令（告警全文经 stdin 传入，如 `curl -s -d @- https://ntfy.sh/<topic>`）；留空仅写 journald";
    };
  };

  config = {
    systemd.services.nas-monitor = {
      description = "NAS health checks (disk water level + key services)";
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        warn_file=$(mktemp)

        # 根分区水位：使用率 > 85% 视为高危（Samba/Syncthing/Gitea 数据同盘）
        usage=$(${pkgs.coreutils}/bin/df -P / | ${pkgs.gawk}/bin/awk 'NR==2{print $5}' | tr -d '%')
        if [ -n "$usage" ] && [ "$usage" -gt 85 ]; then
          echo "WARN 磁盘使用率 ''${usage}% 超过 85%" >> "$warn_file"
        fi

        # 关键服务状态异常告警（正常 active/activating/deactivating 不输出）
        for s in sshd tailscaled gitea gitea-runner caddy samba-smbd syncthing; do
          st=$(${pkgs.systemd}/bin/systemctl is-active "$s" 2>/dev/null || echo unknown)
          case "$st" in
            active|activating|deactivating) : ;;
            *) echo "WARN 服务 $s 状态异常：$st" >> "$warn_file" ;;
          esac
        done

        # 汇总告警：journald 记录 + 可选通知渠道（stdin 传入全文）
        if [ -s "$warn_file" ]; then
          ${pkgs.systemd}/bin/systemd-cat -t nas-monitor < "$warn_file"
          ${lib.optionalString (config.services.monitoring.notifyCommand != null) ''
            cat "$warn_file" | ${config.services.monitoring.notifyCommand}
          ''}
        fi
        rm -f "$warn_file"
      '';
    };

    systemd.timers.nas-monitor = {
      description = "Run NAS health checks hourly";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true;
      };
    };
  };
}
