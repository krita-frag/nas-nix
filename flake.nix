{
  description = "NixOS NAS 声明式配置仓库";

  inputs = {
    # 稳定通道：与安装介质版本一致，NAS 稳定优先
    # 经清华 TUNA 镜像拉取，规避 GitHub 访问问题
    nixpkgs.url = "git+https://mirrors.tuna.tsinghua.edu.cn/git/nixpkgs.git?ref=nixos-26.05&shallow=1";
    # 敏感数据加密：基于 age，密钥文件可安全入库
    # vendor 本地 path input：首装机（nixos-install）无法访问 GitHub，
    # 从仓库内源码直接读取，安装/部署全程零 GitHub 依赖
    agenix.url = "path:./vendor/agenix";
    # NPanel：NixOS 原生 Web 门面（本机 Gitea 镜像仓库；主源确认后可切 GitHub）
    npanel.url = "git+http://nas.local:3000/zhou/npanel.git?ref=main";
  };

  outputs = { self, nixpkgs, agenix, npanel, ... }:
    let
      # 部署工具：从 macOS（aarch64-darwin）驱动远程构建/切换
      nixos-rebuild = system: nixpkgs.legacyPackages.${system}.nixos-rebuild;
      # agenix CLI：管理端加密/编辑密钥；ssh-to-age：SSH 公钥转 age 接收者
      agenix-cli = system: agenix.packages.${system}.default;
      ssh-to-age = system: nixpkgs.legacyPackages.${system}.ssh-to-age;
      # kb-builder 预烘焙镜像构建：把 runner/build-kb-image.sh 打包成可执行命令，
      # 重装系统后 `nix run .#kb-builder` 一条命令恢复 Gitea Actions 构建环境
      kb-builder = system: nixpkgs.legacyPackages.${system}.writeShellScriptBin "kb-builder" ''
        export KB_BUILDER_DOCKERFILE=${./runner/kb-builder.Dockerfile}
        exec bash ${./runner/build-kb-image.sh}
      '';
      # 多主机脚手架：`nix run .#new-host -- <hostname>` 生成 hosts/<name>/ 占位配置
      # 并提示接入步骤（硬件配置/注册/密钥重加密），新增机器零模板复制
      new-host = system: nixpkgs.legacyPackages.${system}.writeShellScriptBin "new-host" ''
        exec bash ${./scripts/new-host.sh} "$@"
      '';
    in
    {
      packages = {
        aarch64-darwin.nixos-rebuild = nixos-rebuild "aarch64-darwin";
        x86_64-linux.nixos-rebuild = nixos-rebuild "x86_64-linux";
        aarch64-darwin.agenix = agenix-cli "aarch64-darwin";
        aarch64-darwin.ssh-to-age = ssh-to-age "aarch64-darwin";
        aarch64-darwin.kb-builder = kb-builder "aarch64-darwin";
        x86_64-linux.kb-builder = kb-builder "x86_64-linux";
        aarch64-darwin.new-host = new-host "aarch64-darwin";
        x86_64-linux.new-host = new-host "x86_64-linux";
      };

      # 自动从 hosts/ 推导（仅用顶层条目，纯求值可靠）：
      #   hosts/<name>/default.nix        → nixosConfigurations.<name>（完整配置）
      #   hosts/<name>-bootstrap.nix       → nixosConfigurations.<name>-bootstrap（首装最小系统）
      # 新增机器：建 hosts/<name>/ 目录（+ 可选同级 bootstrap 文件），零 flake 改动。
      nixosConfigurations =
        let
          hostRoot = ./hosts;
          entries = builtins.readDir hostRoot;
          # 主机 = hosts/ 下的目录，目录名即主机名；排序保证输出确定
          hostNames = builtins.sort (a: b: a < b)
            (builtins.filter (n: entries.${n} == "directory")
              (builtins.attrNames entries));
          mkSystem = modules: nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = [ agenix.nixosModules.age npanel.nixosModules.default ] ++ modules;
          };
          # 完整配置：import hosts/<name>/
          full = builtins.listToAttrs (map
            (n: { name = n; value = mkSystem [ (hostRoot + "/${n}") ]; })
            hostNames);
          # 首装最小系统：存在 hosts/<name>-bootstrap.nix → <name>-bootstrap
          bootStrapHosts = builtins.filter
            (n: entries.${n + "-bootstrap.nix"} == "regular") hostNames;
          boot = builtins.listToAttrs (map
            (n: { name = "${n}-bootstrap";
                  value = mkSystem [ (hostRoot + "/${n}-bootstrap.nix") ]; })
            bootStrapHosts);
        in full // boot;
    };
}
