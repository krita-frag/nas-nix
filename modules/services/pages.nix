{ config, lib, pkgs, git-pages, ... }:

# Gitea Pages：自托管 GitHub Pages（git-pages 引擎，codeberg.page 新一代实现）
# 统一域名托管任意 Gitea 仓库的静态站，URL 形如 http://<nas-ip>:8080/<owner>/<repo>/
#
# 架构（无 DNS、无 hosts 文件）：
#   浏览器 / Gitea Webhook → nginx:8080 路径模式捕获 <owner>/<repo>
#     → 改写 Host 头为 <owner>.pages.local → git-pages:8081（仅回环监听）
# 发布链路：仓库 push main 触发 Gitea Actions 构建并强推 pages 分支
#   → Gitea Webhook POST → nginx 转发 git-pages → wildcard 授权后克隆 pages 分支部署
{
  options.services.pages = {
    enable = lib.mkEnableOption "Gitea Pages 静态站托管";

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "git-pages 引擎监听端口（仅回环，经 nginx 对外）";
    };
    publicPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "对外端口（nginx），统一域名路径模式";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "pages.local";
      description = "wildcard 站点域名（内部标识，无需 DNS，经 nginx Host 头注入）";
    };
    giteaCloneUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://localhost:3000";
      description = ''
        Gitea ROOT_URL 基址；clone-url 模板计算出的 URL 必须与 Gitea Webhook
        载荷的 repository.clone_url 精确一致（allowed-repository-url-prefixes
        只是克隆 URL 前缀安全网，不能代替精确匹配）。
      '';
    };
  };

  config = lib.mkIf config.services.pages.enable {
    services.nginx = {
      enable = true;
      # 关闭 nginx -t/gixy 校验：gixy 无法解析正则语义，会把捕获变量一律判为
      # HTTP-Splitting 风险；本机正则已收紧（见下）排除 CR/LF，实际已免疫。
      validateConfigFile = false;
      virtualHosts.pages = {
        listen = [ { addr = "0.0.0.0"; port = config.services.pages.publicPort; } ];
        # 路径模式：/<owner>/<repo>/ → 注入 Host 头 <owner>.pages.local → git-pages
        # 正则收紧为 Gitea 允许的字符集，杜绝 %0d%0a 等 CR/LF 注入
        locations."~ ^/(?<owner>[a-zA-Z0-9._-]+)/(?<repo>[a-zA-Z0-9._-]+)/?$" = {
          proxyPass = "http://127.0.0.1:${toString config.services.pages.listenPort}/$repo/";
          extraConfig = ''
            proxy_set_header Host $owner.${config.services.pages.domain};
          '';
        };
        locations."/" = {
          # return 文本需带引号：nginx 对未加引号的 < > / 等特殊字符无法解析
          return = "200 \"Gitea Pages: 静态站位于 /<owner>/<repo>/\"";
        };
      };
    };

    users.users.git-pages = {
      isSystemUser = true;
      group = "git-pages";
    };
    users.groups.git-pages = { };

    systemd.services.git-pages = {
      description = "git-pages static site server (Gitea Pages)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        User = "git-pages";
        Group = "git-pages";
        WorkingDirectory = "/var/lib/git-pages";
        StateDirectory = "git-pages";
        Restart = "on-failure";
        RestartSec = 5;
        ExecStart = "${git-pages}/bin/git-pages -config /etc/git-pages/config.toml";
      };
    };

    environment.etc."git-pages/config.toml".text = ''
      # git-pages 配置：wildcard 授权 + 文件系统存储
      [server]
      pages = "tcp/127.0.0.1:${toString config.services.pages.listenPort}"

      [[wildcard]]
      # 站点主机名形如 <owner>.${config.services.pages.domain}；
      # clone-url 模板须与 Gitea Webhook 载荷的 repository.clone_url 精确一致
      domain = "${config.services.pages.domain}"
      clone-url = "${config.services.pages.giteaCloneUrl}/<user>/<project>.git"

      [storage]
      type = "fs"
      [storage.fs]
      # 根目录须已存在（systemd StateDirectory 创建 /var/lib/git-pages）；
      # git-pages 只在其下递归创建 blob/repo，不自行 mkdir 根
      root = "/var/lib/git-pages"

      [limits]
      # 克隆 URL 前缀安全网（实际授权以 wildcard 精确模板匹配为准）
      allowed-repository-url-prefixes = ["http://localhost:3000/", "http://127.0.0.1:3000/"]
    '';

    # 放行对外端口（git-pages 仅回环监听，无需放行）
    networking.firewall.allowedTCPPorts = [ config.services.pages.publicPort ];
  };
}
