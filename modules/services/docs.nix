{ config, lib, ... }:

# 统一知识库中心（Docs Hub）：单一 MkDocs 站点，无子站割裂。
#
# 架构（单一注册点 + 统一 UI）：
#   - 内容仓库：任意 Gitea 仓库只需根目录有 docs/（MkDocs Material Markdown 源），
#     零配置（无需各自 mkdocs.yml / workflow / token / 钩子）；
#   - 注册：在 docs-hub/repos.json 的 repos 列表加一行（owner/name + 可选 desc），
#     唯一注册点，驱动 Gitea Actions 统一构建（docs-hub.yml）；
#   - hub 仓库（nas-nix）：workflow 运行 docs-hub/build.sh，clone 各内容仓库并把
#     docs/ 合并到统一 docs_dir（按 <owner>/<name>/ 组织），从 repos.json 生成统一
#     主页（卡片聚合）与 MkDocs nav（每个知识库一个顶部 tab），
#     以单一 mkdocs.yml（Material 主题）构建成完整站点——统一主题、统一导航、全站搜索，
#     直接把站点写入挂载的 /var/www/docs（runner 容器）并强推 pages 分支作为构建完成信号；
#   - NAS 上 Caddy 静态服务 :8080。
#
#   push hub main → Gitea Actions 统一构建 → 直接部署到 /var/www/docs → Caddy 服务
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
    # 站点内容完全由 hub 仓库 Actions 构建产物提供，本模块只负责静态服务与目录准备；
    # 注册点 repos.json 仅驱动 workflow，Nix 侧无需读取。

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

    # 旧 nginx 仅服务 docs，已由 Caddy 取代，整体停用以减少运行面
    services.nginx.enable = lib.mkDefault false;

    # 站点根目录：runner 容器（root）写入，Caddy 用户只读
    systemd.tmpfiles.rules = [
      "d ${config.services.docs.root} 0755 root root - -"
    ];

    networking.firewall.allowedTCPPorts = [ config.services.docs.port ];
  };
}
