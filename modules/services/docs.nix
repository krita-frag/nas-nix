{ config, lib, pkgs, ... }:

# 统一知识库中心（Docs Hub）：聚合式单站。
#
# 架构（消除多仓库割裂，单一注册点 + 统一 UI）：
#   - 内容仓库：任意 Gitea 仓库只需根目录有 mkdocs.yml + docs/（MkDocs Material），
#     无需 workflow / token / 钩子；
#   - 注册：在 docs-hub/repos.json 的 repos 列表加一行（owner/name），
#     同时驱动 Nix 模块（本文件）与 Gitea Actions 聚合构建（docs-hub.yml）；
#   - hub 仓库（默认 nas-nix）：workflow 读取 repos.json，逐一构建各内容仓库
#     MkDocs 产物到 static/<owner>/<name>/，复制 repos.json 到 data/，
#     经 Hugo 生成统一聚合主页（layouts/index.html），强推 pages 分支；
#   - NAS 上 hub 仓库唯一的 post-receive 钩子把 pages 分支检出到站点根，
#     Caddy 静态服务 :8080。
#
#   push hub main → Gitea Actions 聚合构建 → 强推 pages → 钩子检出到根 → Caddy 服务
{
  options.services.docs = {
    enable = lib.mkEnableOption "统一知识库中心（Hugo 聚合 + MkDocs 子站 + Caddy 静态服务）";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "对外端口（Caddy 静态服务）";
    };

    root = lib.mkOption {
      type = lib.types.path;
      default = "/var/www/docs";
      description = "站点根目录：pages 分支（含聚合主页与各知识库子站）就地检出到该目录";
    };

    hubRepo = lib.mkOption {
      type = lib.types.str;
      default = "zhou/nas-nix";
      description = "hub 仓库（owner/name）：其 pages 分支即完整站点，唯一 post-receive 钩子部署该分支";
    };
  };

  config = lib.mkIf config.services.docs.enable {
    # 站点内容完全由 pages 分支（hub 仓库聚合构建产物）提供，本模块只负责
    # 静态服务与钩子部署；注册点 repos.json 仅驱动 workflow，Nix 侧无需读取。

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

    # 站点根目录：gitea 用户可写（钩子检出），Caddy 用户可读
    systemd.tmpfiles.rules = [
      "d ${config.services.docs.root} 0755 gitea gitea - -"
    ];

    # 部署钩子（仅 hub 仓库一条）：pages 分支检出到站点根。
    # Gitea 生成的包装脚本（hooks/post-receive）会逐个执行 post-receive.d/*
    # 并把 stdin 逐行传入，但它只在自身 shell 内设置 GIT_DIR 而不导出，
    # 因此钩子不能依赖 GIT_DIR——构建期直接把 git-dir 与站点根烘焙进脚本。
    # Gitea 升级/重建仓库可能重写包装脚本，但不会改动 post-receive.d/ 内容。
    system.activationScripts.docsHook = lib.mkAfter (let
      repo = config.services.docs.hubRepo;
      hookScript = pkgs.writeShellScript "docs-deploy-hub" ''
        # Gitea 可能以受限环境运行钩子（PATH 无 git），构建期烘焙 git/coreutils 路径
        export PATH="${pkgs.git}/bin:${pkgs.coreutils}/bin:$PATH"
        set -euo pipefail
        site="${config.services.docs.root}"
        while read -r _old _new ref; do
          [ "''${ref}" = "refs/heads/pages" ] || continue
          mkdir -p "$site"
          git --git-dir="/var/lib/gitea/repositories/${repo}.git" --work-tree="$site" checkout -f pages
          git --git-dir="/var/lib/gitea/repositories/${repo}.git" --work-tree="$site" clean -fdx
          exit 0
        done
      '';
    in
      ''
        hook_dir=/var/lib/gitea/repositories/${repo}.git/hooks/post-receive.d
        mkdir -p "$hook_dir"
        install -o gitea -g gitea -m 0755 ${hookScript} "$hook_dir/docs-deploy"
      '');

    networking.firewall.allowedTCPPorts = [ config.services.docs.port ];
  };
}
