{ config, lib, pkgs, ... }:

# 统一知识库中心（Docs）：任意 Gitea 仓库可注册一个知识库（pages 分支），
# 主页 index 聚合所有已注册知识库的链接，站点按 <root>/<owner>/<name>/ 分区。
#
#   push main → Gitea Actions 构建 mkdocs → 强推 pages 分支
#     → Gitea post-receive 钩子就地检出到 /var/www/docs/<owner>/<name>/ → nginx 静态服务
#
# 注册新知识库：
#   1) 在 services.docs.repos 列表加一行 "owner/name"（部署后自动在主页聚合链接并投放钩子）；
#   2) 该仓库放一份 .gitea/workflows/docs.yml（模板见 docs/kb-workflow.example.yml）；
#   3) 配置 PAGES_TOKEN secret（write:repository 权限 API token）。
#
# 相比 git-pages 引擎，本方案无 Webhook、无反向代理正则、无 DNS、无自定义
# 二进制构建；发布即 push，部署逻辑（nginx + 钩子 + 目录 + 主页）全部收敛在本模块。
{
  options.services.docs = {
    enable = lib.mkEnableOption "统一知识库中心（mkdocs → pages 分支 → nginx 静态服务）";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "对外端口（nginx 静态服务）";
    };

    root = lib.mkOption {
      type = lib.types.path;
      default = "/var/www/docs";
      description = "站点根目录：各知识库部署在 root/<owner>/<name>/，主页 index.html 由构建期生成";
    };

    repos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "zhou/nas-nix" ];
      description = "已注册知识库仓库（owner/name）。push 其 pages 分支时自动部署到 root/<owner>/<name>/ 并在主页聚合链接";
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
    ] ++ (map
      (repo: "d ${config.services.docs.root}/${repo} 0755 gitea gitea - -")
      config.services.docs.repos);

    # 主页 index：构建期由 repos 列表生成（列知识库名 + 链接），激活时写入站点根。
    # 钩子只写各知识库子目录、不覆盖主页，因此主页只随配置更新。
    # 同时在激活阶段预创建各仓库站点子目录并赋 gitea 所有权——
    # post-receive 钩子以 gitea 用户运行，父目录必须可由 gitea 写入才能 mkdir 子目录。
    system.activationScripts.docsIndex = let
      indexHtml = pkgs.writeText "docs-index.html" (let
        items = lib.concatMapStringsSep "\n" (repo:
          let
            parts = lib.splitString "/" repo;
            owner = lib.elemAt parts 0;
            name = lib.elemAt parts 1;
          in
            ''
              <li class="kb">
                <a href="/${repo}/">${name}</a>
                <span class="owner">${owner}</span>
              </li>
            '') config.services.docs.repos;
      in
        ''
          <!DOCTYPE html>
          <html lang="zh">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>NAS 知识库中心</title>
            <style>
              body { font-family: system-ui, -apple-system, sans-serif; max-width: 40rem; margin: 4rem auto; padding: 0 1rem; color: #1f2933; line-height: 1.6; }
              h1 { font-size: 1.6rem; border-bottom: 2px solid #e4e7eb; padding-bottom: .6rem; }
              .sub { color: #7b8794; font-size: .9rem; margin-top: -.4rem; }
              ul { list-style: none; padding: 0; margin-top: 2rem; }
              li.kb { display: flex; justify-content: space-between; align-items: baseline; padding: .8rem 0; border-bottom: 1px solid #f0f3f5; }
              a { color: #2563eb; text-decoration: none; font-weight: 500; }
              a:hover { text-decoration: underline; }
              .owner { color: #9aa5b1; font-size: .85em; }
            </style>
          </head>
          <body>
            <h1>NAS 知识库中心</h1>
            <p class="sub">已注册 ${toString (lib.length config.services.docs.repos)} 个知识库</p>
            <ul>
          ${items}
            </ul>
          </body>
          </html>
        '');
    in
    lib.mkAfter (lib.concatStrings [
      ''
        mkdir -p ${config.services.docs.root}
        chown gitea:gitea ${config.services.docs.root}
      ''
      (lib.concatMapStringsSep "\n" (repo: ''
        mkdir -p ${config.services.docs.root}/${repo}
        chown gitea:gitea ${config.services.docs.root}/${repo}
      '') config.services.docs.repos)
      ''
        install -o gitea -g gitea -m 0644 ${indexHtml} ${config.services.docs.root}/index.html
      ''
    ]);

    # 部署钩子：为每个已注册仓库投放一份 post-receive 钩子。
    # Gitea 生成的包装脚本（hooks/post-receive）会逐个执行 post-receive.d/*
    # 并把 stdin 逐行传入，但它只在自身 shell 内设置 GIT_DIR 而不导出，
    # 因此钩子不能依赖 GIT_DIR——构建期直接把 git-dir 与站点子目录烘焙进脚本。
    # Gitea 升级/重建仓库可能重写包装脚本，但不会改动 post-receive.d/ 内容。
    system.activationScripts.docsHook = lib.mkAfter (
      lib.concatMapStringsSep "\n" (repo: let
        hookScript = pkgs.writeShellScript
          "docs-deploy-${lib.strings.sanitizeDerivationName repo}" ''
            # Gitea 可能以受限环境运行钩子（PATH 无 git），构建期烘焙 git/coreutils 路径
            export PATH="${pkgs.git}/bin:${pkgs.coreutils}/bin:$PATH"
            set -euo pipefail
            site="${config.services.docs.root}/${repo}"
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
        '') config.services.docs.repos
    );

    networking.firewall.allowedTCPPorts = [ config.services.docs.port ];
  };
}
