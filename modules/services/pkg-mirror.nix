{ config, lib, pkgs, ... }:

# ─────────────────────────────────────────────────────────────
# 局域网专用包服务器（多语言统一入口）
# ─────────────────────────────────────────────────────────────
#
# 目标：把「每种语言的包管理器各自直连公网」收敛为「统一走 NAS」，换来三件事：
#   1. 一份客户端配置全家复用——新机器不必各自翻墙 / 配镜像源
#   2. 局域网缓存命中——同一份依赖只从公网拉一次，其余机器跑千兆内网
#   3. 出口故障时已缓存的依赖仍可安装
#
# 按生态的协议特性分两类后端：
#
#   A. 协议原生服务（协议有状态 / 需索引与权限管理，必须用专用实现）
#        Python  devpi-server :3141   按需缓存 PyPI + 私有索引 + Web UI（官方 NixOS 模块）
#        Go      athens       :3700   GOPROXY 协议，按需缓存（无官方模块，本文件自建 unit）
#
#   B. nginx 统一入口 :8081（承担三件事）
#        · 反代 A 类服务，让 pip / go 也能走单一地址（/pypi/ /go/）
#        · 缓存转发「纯 GET + URL 稳定」的上游（cargo 稀疏索引、npm registry）
#        · 静态托管本地产物（/raw/：Zig 依赖包、C++ 预编译产物、私有 wheel）
#
# 为什么 Rust / Zig / C++ 不用专用服务：
#   · Rust  稀疏索引是「按 crate 取索引文件 + config.json 里的 dl 模板」的纯 HTTP 协议，
#           用 nginx 缓存转发 index.crates.io / static.crates.io 最省资源。
#           全量镜像 crates.io 要数十 GB；真要离线再上 pkgs.panamax（见 docs）。
#   · Zig   依赖以「URL + 内容哈希」寻址，没有中心注册表可缓存（ZIGPROXY 协议尚未落地）。
#           做法是把 tarball 放进 /raw/，用 `zig fetch --save` 把 URL 指到本机，哈希不变。
#   · C++   conan_server 在 Conan 2 已拆为独立包，且官方仅定位为「本地仓库」——不支持上游
#           代理缓存、不推荐新部署（nixpkgs 的 pkgs.conan 也确实不含该可执行文件）。
#           C++ 走 vcpkg：私有 registry 复用本机 Gitea（git 协议），共享二进制缓存复用
#           Samba（vcpkg 的 files 后端直接指向共享目录），详见 docs/package-mirror.md。
#
# 设计取舍（两点，改动时别踩回去）：
#   1. 对外只有 :8081 一个放行端口。devpi 绑 127.0.0.1、athens 虽绑 0.0.0.0 但端口不在
#      防火墙白名单内，两者都只能经 nginx 反代访问——攻击面收敛到一个进程。
#   2. 反代一律用「静态地址 + 结尾斜杠」而非变量 / rewrite。这样 nginx 走
#      unparsed_uri 前缀替换，能原样保留 %2f 这类转义（npm 的 @scope%2fname 依赖这点）；
#      代价是上游域名在 nginx 启动/重载时解析一次，故下方对 nginx 加了失败自动重启。
#
# 客户端配置（pip / go / cargo / npm / zig / vcpkg）见 docs/package-mirror.md。
let
  cfg = config.services.pkgMirror;

  cacheZone = "pkg";
  baseUrl = "http://${cfg.hostName}:${toString cfg.port}";
  caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

  # cargo 稀疏索引根上的 config.json：必须由本机提供，才能把 dl 模板改写到 /crates-dl/，
  # 否则 cargo 会按上游给的原样地址回公网取包体，缓存形同虚设。
  # 用 {crate}/{version} 模板形式：cargo 见模板即按模板拼 URL，不会再追加旧式后缀。
  cratesConfigJson = pkgs.writeText "crates-io-config.json" (
    builtins.toJSON {
      dl = "${baseUrl}/crates-dl/{crate}/{version}/download";
      api = "https://crates.io";
    }
  );

  # 首页表格（与 docs/package-mirror.md 同源，改一处记得改另一处）
  rows =
    lib.optional cfg.python.enable {
      eco = "Python (pip)";
      url = "${baseUrl}/pypi/root/pypi/+simple/";
      hint = "pip config set global.index-url ${baseUrl}/pypi/root/pypi/+simple/";
    }
    ++ lib.optional cfg.go.enable {
      eco = "Go (go mod)";
      url = "${baseUrl}/go";
      hint = "go env -w GOPROXY=${baseUrl}/go,direct";
    }
    ++ lib.optional cfg.rust.enable {
      eco = "Rust (cargo)";
      url = "sparse+${baseUrl}/crates/";
      hint = "~/.cargo/config.toml 替换 crates-io 源（见文档）";
    }
    ++ lib.optional cfg.npm.enable {
      eco = "npm";
      url = "${baseUrl}/npm/";
      hint = "npm config set registry ${baseUrl}/npm/";
    }
    ++ lib.optional cfg.raw.enable {
      eco = "Zig / C++ / 任意产物";
      url = "${baseUrl}/raw/";
      hint = "产物放入 ${cfg.root}/raw/（Samba 共享 pkg-raw 可直接投放）";
    }
    ++ lib.optional cfg.nixCache.enable {
      eco = "Nix";
      url = "${baseUrl}/nix";
      hint = "substituters 增加本地址（需签名密钥，见文档）";
    };

  indexHtml = pkgs.writeText "pkg-mirror-index.html" ''
    <!doctype html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>NAS 包服务器</title>
    <style>
      :root { color-scheme: light dark; }
      body { font: 15px/1.65 -apple-system, "PingFang SC", "Microsoft YaHei", system-ui, sans-serif;
             margin: 0 auto; max-width: 62rem; padding: 2.5rem 1.25rem; }
      h1 { font-size: 1.5rem; margin: 0 0 .35rem; }
      p.lead { opacity: .72; margin: 0 0 1.9rem; }
      table { border-collapse: collapse; width: 100%; }
      th, td { text-align: left; padding: .6rem .7rem; border-bottom: 1px solid rgba(128,128,128,.28);
               vertical-align: top; }
      th { font-size: .78rem; text-transform: uppercase; letter-spacing: .05em; opacity: .58; font-weight: 600; }
      code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .87em;
             background: rgba(128,128,128,.13); padding: .12em .4em; border-radius: 4px;
             word-break: break-all; }
      .note { margin-top: 2rem; font-size: .87rem; opacity: .68; }
    </style>
    </head>
    <body>
    <h1>NAS 专用包服务器</h1>
    <p class="lead">统一入口 <code>${baseUrl}</code> · 仅局域网可达 · HTTP 只读，投放产物走 Samba 共享</p>
    <table>
      <thead><tr><th>生态</th><th>接入地址</th><th>客户端配置</th></tr></thead>
      <tbody>
    ${lib.concatMapStrings (r: ''
        <tr><td>${r.eco}</td><td><code>${r.url}</code></td><td><code>${r.hint}</code></td></tr>
    '') rows}
      </tbody>
    </table>
    <p class="note">完整配置与运维说明见仓库 <code>docs/package-mirror.md</code>。</p>
    </body>
    </html>
  '';

  # 首页用独立目录承载：nginx 的 root 会把完整 URI 拼到后面，故必须是 <root>/index.html
  indexRoot = pkgs.runCommand "pkg-mirror-index-root" { } ''
    mkdir -p $out
    cp ${indexHtml} $out/index.html
  '';

  # 需要 nginx 缓存并回源的 location 的公共头：这里必须显式开 SNI 与证书校验——
  # nginx 默认不校验证书也不发 SNI，对 Cloudflare 后面的上游会直接握手失败或静默降级。
  cacheCommon = ''
    proxy_cache ${cacheZone};
    proxy_ssl_server_name on;
    proxy_ssl_verify on;
    proxy_ssl_trusted_certificate ${caBundle};
    proxy_ssl_verify_depth 2;
    add_header X-Cache-Status $upstream_cache_status always;
  '';
in
{
  options.services.pkgMirror = {
    enable = lib.mkEnableOption "局域网专用包服务器（多语言统一入口）";

    hostName = lib.mkOption {
      type = lib.types.str;
      default = "nas.local";
      description = ''
        客户端使用的局域网主机名（由 hosts/nas/default.nix 的 Avahi/mDNS 提供解析）。
        用于生成 cargo 索引的下载模板与首页示例，务必与客户端实际访问地址一致。
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "统一入口端口（Caddy 已占用 8080 供知识库使用）。";
    };

    root = lib.mkOption {
      type = lib.types.path;
      default = "/srv/pkg";
      description = "数据根目录（静态产物 /raw/ 位于其下）。";
    };

    cacheMaxSize = lib.mkOption {
      type = lib.types.str;
      default = "200g";
      description = ''
        nginx 代理缓存上限。随命中逐步增长，到上限后按 LRU 淘汰。
        只作用于「按需拉取的公网包」，/raw/ 下自管产物不占此配额。
      '';
    };

    python = {
      enable = (lib.mkEnableOption "Python：devpi-server（PyPI 按需缓存 + 私有索引）") // { default = true; };

      port = lib.mkOption {
        type = lib.types.port;
        default = 3141;
        description = "devpi-server 监听端口（仅绑 127.0.0.1，对外统一走 nginx）。";
      };

      extraPackages = lib.mkOption {
        default = (ps: [ ]);
        defaultText = lib.literalExpression "ps: [ ]";
        example = lib.literalExpression "ps: with ps; [ devpi-web ]";
        type = lib.types.functionTo (lib.types.listOf lib.types.package);
        description = ''
          devpi 插件。默认空集最稳；想要可浏览的 Web UI 可设为 ps: with ps; [ devpi-web ]。
        '';
      };
    };

    go = {
      enable = (lib.mkEnableOption "Go：athens（GOPROXY 按需缓存）") // { default = true; };

      port = lib.mkOption {
        type = lib.types.port;
        default = 3700;
        description = "athens 监听端口（绑 0.0.0.0，但不在防火墙白名单内，仅本机 nginx 反代可达）。";
      };

      upstream = lib.mkOption {
        type = lib.types.str;
        default = "https://goproxy.cn,direct";
        example = "https://proxy.golang.org,direct";
        description = ''
          athens 回源用的 GOPROXY（传给其内部 go mod download，逗号分隔构成回退链）。
          默认走国内镜像；纯离线或自定义上游时改这里。
        '';
      };
    };

    rust = {
      enable = (lib.mkEnableOption "Rust：cargo 稀疏索引缓存转发") // { default = true; };

      indexUpstream = lib.mkOption {
        type = lib.types.str;
        default = "https://index.crates.io";
        example = "https://rsproxy.cn/index";
        description = ''
          cargo 稀疏索引上游（不含结尾斜杠）。请求 /crates/<前缀>/<crate> 转发到此。
          索引是高频请求，国内提速可换 https://rsproxy.cn/index
          （实测 0.39s vs index.crates.io 的 0.5~1.2s，且更稳定）。
        '';
      };

      cratesUpstream = lib.mkOption {
        type = lib.types.str;
        default = "https://static.crates.io/crates";
        description = ''
          .crate 包体上游（不含结尾斜杠）。请求 /crates-dl/<crate>/<version>/download
          转发到 <上游>/<crate>/<version>/download。

          注意：这里必须是**直出**端点。rsproxy.cn 一类国内镜像的下载端点会 307 跳到
          另一台 CDN 主机（lf3-static.rsproxy.cn），nginx 不跟随上游重定向，cargo 拿到
          跳转后会直接去公网 CDN——缓存就白做了。故 rsproxy 只建议用于 indexUpstream。
        '';
      };
    };

    npm = {
      enable = (lib.mkEnableOption "npm：registry 缓存转发") // { default = true; };

      upstream = lib.mkOption {
        type = lib.types.str;
        default = "https://registry.npmmirror.com";
        description = ''
          npm registry 上游（不含结尾斜杠）。元数据与 tarball 同主机，纯反代即可命中缓存。
          注意：客户端需设 replace-registry-host=always，否则 tarball 仍走公网（见文档）。
        '';
      };
    };

    raw = {
      enable = (lib.mkEnableOption "本地产物静态托管（/raw/：Zig 依赖、C++ 产物、私有 wheel）") // { default = true; };

      sambaShare = (lib.mkEnableOption "为 /raw/ 追加同名 Samba 共享，便于局域网投放产物") // { default = true; };

      sambaUser = lib.mkOption {
        type = lib.types.str;
        default = "nas";
        description = "可写该共享的用户（须为 modules/system/samba.nix 中已存在的用户）。";
      };
    };

    nixCache = {
      enable = (lib.mkEnableOption "Nix 二进制缓存（harmonia，供局域网其他机器 / Gitea runner 复用本机构建产物）") // { default = false; };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5000;
        description = "harmonia 监听端口（仅绑 127.0.0.1，对外统一走 nginx /nix/）。";
      };

      signKeyPath = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/agenix/nix-cache-sign-key";
        description = ''
          缓存签名私钥。**强烈建议配置**：不签名时客户端必须全局关掉 require-sigs
          才肯使用该缓存，等于同时放弃了所有 substitution 的签名校验。
          生成：nix-store --generate-binary-cache-key nas.local-1 <私钥> <公钥>
          私钥经 agenix 加密入库，公钥填到客户端的 trusted-public-keys。
        '';
      };
    };

    tailscaleHttpsPort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      example = 10000;
      description = ''
        非 null 时经 Tailscale Serve 额外暴露一个尾网 HTTPS 入口（有效证书、仅 tailnet 可达）。
        Tailscale 仅支持 443 / 8443 / 10000，前两者已被知识库与 Gitea 占用。
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # ── 目录骨架 ────────────────────────────────────────────────
    # raw 属主给了可写共享用户，但权限是 0775：others 仍可读，
    # nginx（nginx 用户）因此无需加入额外组也能只读服务。
    systemd.tmpfiles.rules = [
      "d ${cfg.root} 0755 root root -"
    ] ++ lib.optionals cfg.raw.enable [
      "d ${cfg.root}/raw 0775 ${cfg.raw.sambaUser} users -"
    ];

    # ── Python：devpi-server（官方模块，负责首次 devpi-init）──────
    services.devpi-server = lib.mkIf cfg.python.enable {
      enable = true;
      host = "127.0.0.1";
      port = cfg.python.port;
      extraPackages = cfg.python.extraPackages;
      # openFirewall 保持 false：只允许本机 nginx 反代
    };

    # ── Go：athens（nixpkgs 有包无模块，自建 unit）─────────────
    systemd.services.athens = lib.mkIf cfg.go.enable {
      description = "Athens Go module proxy (GOPROXY)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      environment = {
        # athens 无 bind 选项（只能给端口），因此监听全接口；
        # 端口未列入防火墙白名单，外部访问被挡在 nginx 之外。
        ATHENS_PORT = ":${toString cfg.go.port}";
        ATHENS_STORAGE_TYPE = "disk";
        ATHENS_DISK_STORAGE_ROOT = "/var/lib/athens/storage";
        ATHENS_DOWNLOAD_MODE = "sync";
        ATHENS_LOG_LEVEL = "info";
        # athens 用内部 go mod download 回源，这里决定回源走哪个上游
        ATHENS_GO_BINARY_ENV_VARS = "GOPROXY=${cfg.go.upstream}";
        GOPATH = "/var/lib/athens/gopath";
        HOME = "/var/lib/athens";
        # go / git 走 https 回源需要 CA（systemd 服务不继承登录 shell 的证书变量）
        SSL_CERT_FILE = caBundle;
        GIT_SSL_CAINFO = caBundle;
      };

      path = [ pkgs.go pkgs.git pkgs.cacert ];

      serviceConfig = {
        Type = "simple";
        ExecStart = lib.getExe pkgs.athens;
        DynamicUser = true;
        StateDirectory = "athens";
        # athens 的 disk 后端不自建目录，先建好再启动（含 gopath）
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/lib/athens/storage /var/lib/athens/gopath";
        Restart = "on-failure";
        RestartSec = "5s";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        LimitNOFILE = 65536;
      };
    };

    # ── Nix 二进制缓存：harmonia（官方模块）────────────────────
    services.harmonia = lib.mkIf cfg.nixCache.enable {
      cache = {
        enable = true;
        # 只绑回环：本机 nginx 反代，避免局域网直连
        settings.bind = "127.0.0.1:${toString cfg.nixCache.port}";
        signKeyPaths = lib.optional (cfg.nixCache.signKeyPath != null) cfg.nixCache.signKeyPath;
      };
    };

    # ── 统一入口：nginx（承担反代 + 缓存 + 静态托管）────────────
    services.nginx = {
      # 知识库模块里为「减少运行面」把 nginx 设成 mkDefault false（静态服务交给 Caddy）。
      # 这里必须打开：Caddy 不带缓存能力，而 cargo / npm 的按需缓存正是本服务的核心。
      enable = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      # 私有 wheel、预编译产物等大文件可能经此中转
      clientMaxBodySize = "2g";

      proxyCachePath.${cacheZone} = {
        enable = true;
        keysZoneName = cacheZone;
        keysZoneSize = "64m";
        levels = "1:2";
        inactive = "365d";
        maxSize = cfg.cacheMaxSize;
        useTempPath = false;
      };

      appendHttpConfig = ''
        # 缓存键必须带上 Accept：npm 的「精简元数据 / 完整元数据」靠该头区分，
        # 而 nginx 的 proxy_cache 不解析 Vary，不入键两者会互相污染。
        proxy_cache_key "$scheme$request_method$request_uri$http_accept";
        proxy_cache_lock on;
        proxy_cache_lock_timeout 60s;
        proxy_cache_background_update on;
        proxy_cache_revalidate on;
        # 上游普遍带 no-cache / Set-Cookie，对「内容寻址、永不改写」的包体来说
        # 这些头只会让缓存失效，故整体忽略，TTL 交由各 location 的 proxy_cache_valid 决定。
        proxy_ignore_headers Cache-Control Expires Set-Cookie;
        # 回源失败时用陈旧的缓存兜底（离线可用性的关键）
        proxy_cache_use_stale error timeout updating http_429 http_500 http_502 http_503 http_504;
        proxy_connect_timeout 15s;
        proxy_read_timeout 300s;
      '';

      # vhost 名写成 ":端口" 是 nixpkgs nginx 的约定：据此推导 listen（0.0.0.0 + [::]），
      # 且不设置 server_name，从而成为该端口的默认 vhost（任意 Host 都命中）。
      virtualHosts.":${toString cfg.port}" = {
        locations =
          {
            # 首页：声明式生成的客户端配置速查表
            "/" = {
              root = indexRoot;
              extraConfig = "index index.html;";
            };
          }
          // lib.optionalAttrs cfg.python.enable {
            "/pypi/" = {
              proxyPass = "http://127.0.0.1:${toString cfg.python.port}/";
              extraConfig = ''
                # devpi 靠 X-outside-url 生成带子路径前缀的链接。不给它，devpi 会
                # 返回缺 /pypi 前缀的地址，pip 解析后直接 404——这是 devpi 挂子路径的
                # 标准做法（参见 devpi 上游 issue #840）。
                proxy_set_header X-outside-url ${baseUrl}/pypi;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-Proto $scheme;
              '';
            };
          }
          // lib.optionalAttrs cfg.go.enable {
            # GOPROXY 协议的回包不含任何 URL，因此前缀剥离安全无副作用
            "/go/" = {
              proxyPass = "http://127.0.0.1:${toString cfg.go.port}/";
            };
          }
          // lib.optionalAttrs cfg.rust.enable {
            # 稀疏索引。精确匹配优先级高于前缀匹配，故下面的 config.json 覆盖不会被这里吃掉。
            "/crates/" = {
              proxyPass = "${cfg.rust.indexUpstream}/";
              extraConfig = ''
                ${cacheCommon}
                proxy_cache_valid 200 302 7d;
                # 404 也要缓存：crate 不存在时 cargo 依赖它做判断，且要能离线复现
                proxy_cache_valid 404 5m;
              '';
            };
            # 索引根上的 config.json 由本机提供，把 dl 模板指向 /crates-dl/
            "= /crates/config.json" = {
              alias = cratesConfigJson;
              extraConfig = ''
                default_type application/json;
                add_header Cache-Control "no-cache" always;
              '';
            };
            "/crates-dl/" = {
              proxyPass = "${cfg.rust.cratesUpstream}/";
              extraConfig = ''
                ${cacheCommon}
                # .crate 内容寻址、永不改写，长缓存
                proxy_cache_valid 200 302 90d;
              '';
            };
          }
          // lib.optionalAttrs cfg.npm.enable {
            "/npm/" = {
              proxyPass = "${cfg.npm.upstream}/";
              extraConfig = ''
                ${cacheCommon}
                proxy_cache_valid 200 302 6h;
                proxy_cache_valid 404 5m;
              '';
            };
          }
          // lib.optionalAttrs cfg.raw.enable {
            # 静态产物仓库：只读 HTTP + 目录索引；投放走 Samba（见下）
            "/raw/" = {
              alias = "${cfg.root}/raw/";
              extraConfig = ''
                autoindex on;
                autoindex_exact_size off;
                autoindex_localtime on;
              '';
            };
          }
          // lib.optionalAttrs cfg.nixCache.enable {
            "/nix/" = {
              proxyPass = "http://127.0.0.1:${toString cfg.nixCache.port}/";
              extraConfig = ''
                # 二进制缓存内容寻址不可变，长缓存
                proxy_cache ${cacheZone};
                proxy_cache_valid 200 90d;
              '';
            };
          };
      };
    };

    # nginx 的反代目标在启动/重载时解析一次域名：开机瞬间 DNS 不可用会让它启动失败。
    # 加失败重启兜底，DNS 恢复后自动上线（无需人工介入）。
    systemd.services.nginx.serviceConfig = {
      Restart = lib.mkForce "on-failure";
      RestartSec = lib.mkForce 10;
    };

    # ── 产物投放：复用现有 Samba（vcpkg 二进制缓存也指向此共享）──
    services.samba.settings = lib.mkIf (cfg.raw.enable && cfg.raw.sambaShare) {
      "pkg-raw" = {
        path = "${cfg.root}/raw";
        "read only" = "no";
        "valid users" = cfg.raw.sambaUser;
        "browseable" = "yes";
        "create mask" = "0644";
        "directory mask" = "0755";
        comment = "包服务器产物投放（Zig 依赖包 / C++ 预编译产物 / 私有 wheel）";
      };
    };

    # ── 暴露面：只放行统一入口 ──────────────────────────────────
    networking.firewall.allowedTCPPorts = [ cfg.port ];

    # ── 可选：尾网 HTTPS 入口 ──────────────────────────────────
    services.tailscaleServe.rules = lib.optional (cfg.tailscaleHttpsPort != null) {
      name = "pkg";
      https = cfg.tailscaleHttpsPort;
      target = "http://127.0.0.1:${toString cfg.port}";
    };
  };
}
