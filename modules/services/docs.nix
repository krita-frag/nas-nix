{ config, lib, pkgs, ... }:

# 统一知识库中心：单一 MkDocs 站点，无子站割裂。引擎为独立仓库 nas-docs。
#
# 架构（单一注册点 + 统一 UI，引擎与内容仓库解耦）：
#   - 内容仓库：任意 Gitea 仓库只需根目录有 docs/（纯 Markdown 源），或 .kb.yml
#     覆盖 标题/文档路径/自定义导航，零配置（无需各自 mkdocs.yml / workflow / token / 钩子）；
#   - 引擎（nas-docs）：repos.json 为唯一注册点（owner/name + 可选 desc），
#     build.sh 读 repos.json clone 各内容仓库、按 <owner>/<name>/ 合并 docs 到统一
#     docs_dir，生成统一主页（卡片聚合）与 MkDocs nav（每个知识库一个顶部 tab），
#     以单一 mkdocs.yml（Material 主题）构建完整站点——统一主题、统一导航、全站搜索；
#   - 触发：push nas-docs main（引擎/注册变更）+ schedule 每 6h（内容同步）+ 手动 dispatch；
#   - 部署：构建产物直接写入挂载的 /var/www/docs（runner 容器），并强推 pages 分支
#     作为构建完成信号；NAS 上 Caddy 静态服务 :8080。
#
# 说明：部署由 runner 容器完成（挂载 /var/www/docs，见 gitea.nix 的 container.options），
# 不依赖 Gitea post-receive 钩子——Gitea 的 HTTP 推送不会执行仓库 post-receive.d 钩子，
# 且 gitea 服务沙箱（ProtectSystem=strict）下 /var/www/docs 只读。
{
  options.services.docs = {
    enable = lib.mkEnableOption "统一知识库中心（单一 MkDocs 站点 + Caddy 静态服务）";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "对外端口（Caddy 静态服务）";
    };

    root = lib.mkOption {
      type = lib.types.path;
      default = "/var/www/docs";
      description = "站点根目录：runner 容器把聚合构建产物（含主页与各知识库子站）直接写入该目录";
    };
  };

  config = lib.mkIf config.services.docs.enable {
    # 站点内容完全由引擎仓库（nas-docs）Actions 构建产物提供，本模块只负责静态服务与目录准备；
    # 注册点 repos.json 位于引擎仓库（nas-docs），仅驱动 workflow，Nix 侧无需读取。

    # Caddy 静态服务站点根：纯文件服务，无代理、无路径重写，URL 即站点根。
    # 仅端口监听（无 host）不触发 ACME。
    services.caddy = {
      enable = true;
      virtualHosts.":${toString config.services.docs.port}" = {
        extraConfig = ''
          root * ${config.services.docs.root}
          encode gzip
          try_files {path} {path}/ {path}/index.html
          file_server
        '';
      };
    };

    # nginx 不承担本机静态服务（Caddy 提供），整体停用减少运行面
    services.nginx.enable = lib.mkDefault false;

    # 尾网 HTTPS 入口：Caddy 仅 HTTP 监听 :8080，强制 https 的抓取工具（WebFetch 类
    # LLM 爬虫）无法直连内网 http。经 tailscale serve 把站点挂到尾网 HTTPS
    # （https://<机器名>.ts.net/）：有效证书、无公网暴露、仅 tailnet 内节点可达，
    # 站点 URL 不变，只是多一条 HTTPS 入口。serve 配置持久于 tailscaled 状态。
    #
    # 一次性手动步骤：Serve 需在 tailnet 管理台启用（https://login.tailscale.com/admin）。
    # 未启用时 `tailscale serve --bg` 会挂住而非报错退出，故用 timeout 兜底并静默成功，
    # 服务始终 active（exited），不制造失败噪音；配套每小时 timer 重新应用配置，
    # 管理台启用 Serve 后最多 1 小时自动生效，无需重启。
    systemd.services.tailscale-serve-docs = {
      description = "Expose docs site over tailnet HTTPS (tailscale serve)";
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      # --bg 幂等：已配置则立即返回；Serve 未启用时挂起，由 timeout 兜底后静默成功
      script = ''
        timeout 20 ${pkgs.tailscale}/bin/tailscale serve --bg --https=443 http://127.0.0.1:${toString config.services.docs.port} || true
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
    };

    # 每小时重跑一次 serve 配置：Serve 在管理台启用后自动生效，无需重启/开机
    systemd.timers.tailscale-serve-docs = {
      description = "Periodically (re)apply docs tailscale serve config";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "1h";
        Persistent = true;
      };
    };

    # 站点根目录：runner 写入（host 直跑以 gitea-runner 用户、容器以 root），Caddy 只读。
    # d 创建/修正顶层属主；Z 递归 chown 整棵树（不含 mode，避免把 html/css 变为可执行），
    # 保证升级前由 root 容器写入的旧内容子目录也可被 gitea-runner 递归删除/覆盖
    systemd.tmpfiles.rules = [
      "d ${config.services.docs.root} 0755 gitea-runner gitea-runner - -"
      "Z ${config.services.docs.root} - gitea-runner gitea-runner - -"
    ];

    networking.firewall.allowedTCPPorts = [ config.services.docs.port ];
  };
}
