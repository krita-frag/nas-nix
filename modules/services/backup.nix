{ config, lib, pkgs, ... }:

# 集中备份：restic 加密快照 + rclone 上传网盘（3-2-1 异地加密副本）。
#   - 数据范围：/srv/shares（Samba 共享）+ /srv/syncthing（同步数据）+ /var/lib/gitea
#     （Git 仓库 / OCI 镜像 / SQLite），即全量关键数据；
#   - 加密：restic 仓库口令经 agenix 解密挂载（restic-repo-password），明文不入库；
#   - 目标：repository 填入实际仓库后自动启用每日 03:00 备份（Persistent 补跑错过的任务），
#     留空则不定义备份服务——占位仓库会导致定时任务反复失败，故未配置时整体禁用；
#   - 保留策略：每日 7 份 + 每周 4 份 + 每月 12 份，prune 自动清理；
#   - 本地占用：仓库在远端，本机只有 restic 缓存，落数据盘 /srv/restic-cache
#     （系统盘不驻留缓存内容），并由 restic-cache-clean timer 每日清理 14 天前的缓存；
#   - 恢复：手动 `restic -r <repository> snapshots/restore`（见 README「备份与恢复」）。
{
  options.services.backup = {
    enable = lib.mkEnableOption "集中备份（restic + rclone）";

    repository = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "restic 仓库地址。填入实际目标后启用：S3 原生（s3:s3.<region>.amazonaws.com/<bucket>）或 rclone 桥接（rclone:<remote>:<path>）；留空禁用";
    };

    rcloneConf = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "rclone 配置文件路径（经 agenix 解密挂载，如 /run/agenix/rclone-conf）。repository 用 rclone:<remote>:<path> 桥接网盘时需要远端凭据，设置后以 RCLONE_CONFIG 环境变量供 restic 调用 rclone 使用";
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

    # rclone 远端凭据：仅 rclone:<remote>: 后端需要，经 agenix 加密挂载。
    # 条件定义：未设置 rcloneConf 时不声明密钥，避免缺失 .age 文件导致部署失败；
    # 实机接入时用 `nix run .#agenix -- -e rclone-conf.age` 生成后再填路径
    age.secrets."rclone-conf" = lib.mkIf (config.services.backup.rcloneConf != null) {
      file = ../../secrets/rclone-conf.age;
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

    # 缓存落点与定期清理：仅在启用（repository 非空）时定义，禁用期不产生任何备份单元。
    #   - 缓存落点：nixpkgs 模块把备份服务的 RESTIC_CACHE_DIR 指向系统盘
    #     /var/cache/restic-backups-<name>，这里用 mkForce 改指数据盘
    #     /srv/restic-cache，让备份缓存不驻留系统盘；
    #   - 定期清理：缓存规模随仓库增长，独立 timer 每日删除 14 天未写入的缓存文件。
    #     不用 systemd-tmpfiles 的 age 字段——实测它只判定目录自身（空目录超龄才删），
    #     不递归清理目录内容；
    #   - 缓存可再生，删除不影响仓库完整性与历史快照；仓库体积本身由 pruneOpts 保留策略控制。
    systemd = lib.mkIf (config.services.backup.repository != "") {
      tmpfiles.rules = [
        "d /srv/restic-cache 0700 root root -"
      ];

      # 扩展模块生成的单元：改缓存落点，并在 rclone 桥接时注入远端凭据（RCLONE_CONFIG）。
      # 模块自身已定义同键 RESTIC_CACHE_DIR，需 mkForce 提升优先级才能覆盖
      # （模块的 CacheDirectory 仍会建出空的 /var/cache/restic-backups-nas-data，不驻留内容）。
      services."restic-backups-nas-data".environment = {
        RESTIC_CACHE_DIR = lib.mkForce "/srv/restic-cache";
      } // lib.optionalAttrs (config.services.backup.rcloneConf != null) {
        RCLONE_CONFIG = config.services.backup.rcloneConf;
      };

      services.restic-cache-clean = {
        description = "清理 restic 缓存（删除 14 天前的缓存文件）";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.findutils}/bin/find /srv/restic-cache -mindepth 1 -mtime +14 -delete";
        };
      };

      timers.restic-cache-clean = {
        description = "每日清理 restic 缓存，避免占用增长";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
        };
      };
    };
  };
}
