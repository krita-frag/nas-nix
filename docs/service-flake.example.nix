# 自托管服务 Flake 模板 — 部署到 NixOS 本机（非容器）
#
# 用法：
#   1. 复制本文件到你的服务仓库根目录，重命名为 flake.nix
#   2. 修改 description、pname、version 与构建逻辑（Go/Rust/Node/Python 皆可）
#   3. 提交并推送到 Gitea；NAS 端按 docs/nixos-native-deploy.md 引用启用
#
# 本模板产出两种可复用单元（GitHub Actions 的对应物）：
#   - packages.${system}.default  构建产物（对应 artifact，nix build 产出二进制）
#   - nixosModules.default        服务声明（对应 action/marketplace，NAS imports 即启用）
{
  description = "自托管服务（NAS NixOS 本机声明式部署）";

  inputs = {
    # 与 nas-nix 一致的 nixpkgs 通道，保证构建环境与 NAS 一致
    nixpkgs.url = "git+https://mirrors.tuna.tsinghua.edu.cn/git/nixpkgs.git?ref=nixos-26.05&shallow=1";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux"; # 与 NAS 架构一致
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # ① 构建产物：nix build .#packages.x86_64-linux.default
      #    CI 亦可构建并推 binary cache，NAS 端只拉二进制（见文档第 4 节）
      packages.${system} = {
        default =
          pkgs.buildGoModule {
            pname = "myapp";
            version = "0.1.0";
            src = ./.;
            # 首次构建报错会提示正确 hash，复制填入后锁定依赖
            vendorHash = null;
          };
        # 其他语言替换示例（择一）：
        #   Rust:      pkgs.buildRustPackage { ... cargoHash = null; }
        #   Node 站点: pkgs.buildNpmPackage { ... npmDeps = pkgs.importNpmLock { npmRoot = ./.; }; }
        #   Python:    pkgs.python312.pkgs.buildPythonApplication { ... }
        #   静态站点:  pkgs.stdenv.mkDerivation { ... } 打包 HTML/JS 产物
      };

      # ② 服务模块：NAS 端 imports 后 services.myapp.enable = true 即启用
      #    systemd 托管、随 NixOS generation 原子回滚
      nixosModules.default =
        { config, lib, pkgs, ... }:
        let
          pkg = self.packages.${system}.default;
        in
        {
          options.services.myapp = {
            enable = lib.mkEnableOption "myapp 服务";
            port = lib.mkOption {
              type = lib.types.port;
              default = 8080;
              description = "myapp HTTP 监听端口";
            };
          };

          config = lib.mkIf config.services.myapp.enable {
            # 常驻服务（Web / API）：DynamicUser 免建用户，仅运行期存在
            systemd.services.myapp = {
              description = "myapp";
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                ExecStart = "${pkg}/bin/myapp --addr 0.0.0.0:${toString config.services.myapp.port}";
                Restart = "on-failure";
                RestartSec = 5;
                DynamicUser = true;
              };
            };

            # 定时任务（工具类服务用 systemd timer，不常驻）
            systemd.timers.myapp-daily = {
              description = "myapp 每日任务";
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnCalendar = "daily";
                Persistent = true;
              };
            };
            systemd.services.myapp-daily = {
              description = "myapp 每日任务执行";
              serviceConfig = {
                Type = "oneshot";
                ExecStart = "${pkg}/bin/myapp --cron daily";
                DynamicUser = true;
              };
            };

            # 放行端口（NAS 默认防火墙开启）
            networking.firewall.allowedTCPPorts = [ config.services.myapp.port ];
          };
        };
    };
}
