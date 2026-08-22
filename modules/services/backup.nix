{ config, lib, pkgs, ... }:

# 集中备份：restic 加密快照 + rclone 上传网盘（3-2-1 异地加密副本）。
#   - 数据范围：/srv/shares（Samba 共享）+ /srv/syncthing（同步数据）+ /var/lib/gitea
#     （Git 仓库 / OCI 镜像 / SQLite），即全量关键数据；
#   - 加密：restic 仓库口令经 agenix 解密挂载（restic-repo-password），明文不入库；
#   - 目标：repository 填入实际仓库后自动启用每日 03:00 备份（Persistent 补跑错过的任务），
#     留空则不定义备份服务——占位仓库会导致定时任务反复失败，故未配置时整体禁用；
#   - 保留策略：每日 7 份 + 每周 4 份 + 每月 12 份，prune 自动清理；
#   - 恢复：手动 `restic -r <repository> snapshots/restore`（见 README「备份与恢复」）。
{
  options.services.backup = {
    enable = lib.mkEnableOption "集中备份（restic + rclone）";

    repository = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "restic 仓库地址。填入实际目标后启用：S3 原生（s3:s3.<region>.amazonaws.com/<bucket>）或 rclone 桥接（rclone:<remote>:<path>）；留空禁用";
    };

    paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/srv/shares" "/srv/syncthing" "/var/lib/gitea" ];
      description = "备份的数据目录";
    };
  };

  config = lib.mkIf config.services.backup.enable {
    # restic：备份客户端；rclone：网盘桥接（rclone:<remote>: 后端仓库时使用）
    environment.systemPackages = with pkgs; [ restic rclone ];

    # 仓库口令：restic 初始化/读写仓库均需；经 agenix 加密，仅在需要时解密
    age.secrets.restic-repo-password = {
      file = ../../secrets/restic-repo-password.age;
      owner = "root";
      group = "root";
      mode = "0400";
    };

    # 仓库未配置时整体不定义备份服务（避免定时任务以占位仓库反复失败）
    services.restic.backups.nas-data = lib.mkIf (config.services.backup.repository != "") {
      initialize = true;
      paths = config.services.backup.paths;
      repository = config.services.backup.repository;
      passwordFile = config.age.secrets.restic-repo-password.path;
      timerConfig = {
        OnCalendar = "03:00";
        Persistent = true;
      };
      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 4"
        "--keep-monthly 12"
      ];
    };
  };
}
