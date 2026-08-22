{ config, lib, pkgs, ... }:

# 主动健康监控：每小时检查磁盘水位与关键服务状态，异常写入 journald（tag: nas-monitor）。
# 设计取向：不引入额外面板/依赖，仅 systemd timer + 轻量脚本；告警落点 journald，
# 可用 `journalctl -t nas-monitor` 查看，后续可扩展通知渠道（如邮件）或备份成功检查。
{
  systemd.services.nas-monitor = {
    description = "NAS health checks (disk water level + key services)";
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      # 根分区水位：使用率 > 85% 视为高危（Samba/Syncthing/Gitea 数据同盘）
      usage=$(${pkgs.coreutils}/bin/df -P / | ${pkgs.gawk}/bin/awk 'NR==2{print $5}' | tr -d '%')
      if [ -n "$usage" ] && [ "$usage" -gt 85 ]; then
        echo "WARN 磁盘使用率 ''${usage}% 超过 85%" | ${pkgs.systemd}/bin/systemd-cat -t nas-monitor
      fi

      # 关键服务状态异常告警（正常 active/activating/deactivating 不输出）
      for s in sshd tailscaled gitea gitea-runner caddy samba-smbd syncthing; do
        st=$(${pkgs.systemd}/bin/systemctl is-active "$s" 2>/dev/null || echo unknown)
        case "$st" in
          active|activating|deactivating) : ;;
          *) echo "WARN 服务 $s 状态异常：$st" | ${pkgs.systemd}/bin/systemd-cat -t nas-monitor ;;
        esac
      done
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
}
