{ config, lib, pkgs, ... }:

# 知识库静态站（Docs）：单仓库、单静态站、一条直链。
#
#   push main → Gitea Actions 构建 mkdocs → 强推 pages 分支
#     → Gitea post-receive 钩子就地检出到站点目录 → nginx 静态服务
#
# 相比 git-pages 引擎，本方案无 Webhook、无反向代理正则、无 DNS、无自定义
# 二进制构建；发布即 push，部署逻辑（nginx + 钩子 + 目录）全部收敛在本模块。
{
  options.services.docs = {
    enable = lib.mkEnableOption "Gitea 知识库静态站（mkdocs → pages 分支 → nginx 静态服务）";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "对外端口（nginx 静态服务）";
    };

    root = lib.mkOption {
      type = lib.types.path;
      default = "/var/www/docs";
      description = "站点目录：post-receive 钩子部署目标，同时是 nginx 静态根";
    };

    repo = lib.mkOption {
      type = lib.types.str;
      default = "zhou/nas-nix";
      description = "知识库仓库（owner/name）。push 其 pages 分支时自动部署";
    };
  };

  config = lib.mkIf config.services.docs.enable {
    # nginx 直接服务静态目录：无代理、无路径重写，URL 即站点根
    services.nginx = {
      enable = true;
      virtualHosts.docs = {
        listen = [ { addr = "0.0.0.0"; port = config.services.docs.port; } ];
        root = config.services.docs.root;
        locations."/" = {
          index = "index.html";
        };
      };
    };

    # 站点目录：gitea 用户可写（钩子检出），nginx 用户可读
    systemd.tmpfiles.rules = [
      "d ${config.services.docs.root} 0755 gitea gitea - -"
    ];

    # 部署钩子：Gitea 生成的 post-receive 包装脚本会逐个执行
    # hooks/post-receive.d/* 下可执行文件。这里声明式投放本仓库的部署脚本
    # （git 仅检出 pages 分支并清理残留，不依赖 tar 等额外工具）。
    # Gitea 升级/重建仓库可能重写包装脚本，但不会改动 post-receive.d/ 内容。
    system.activationScripts.docsHook = let
      hookScript = pkgs.writeShellScript "docs-deploy" ''
        set -euo pipefail
        while read -r _old _new ref; do
          [ "\${ref}" = "refs/heads/pages" ] || continue
          git --git-dir="\${GIT_DIR}" --work-tree="${config.services.docs.root}" checkout -f pages
          git --git-dir="\${GIT_DIR}" --work-tree="${config.services.docs.root}" clean -fdx
          exit 0
        done
      '';
    in
    lib.mkAfter ''
      hook_dir=/var/lib/gitea/repositories/${config.services.docs.repo}.git/hooks/post-receive.d
      mkdir -p "$hook_dir"
      install -o gitea -g gitea -m 0755 ${hookScript} "$hook_dir/docs-deploy"
    '';

    networking.firewall.allowedTCPPorts = [ config.services.docs.port ];
  };
}
