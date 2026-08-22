{
  description = "NixOS NAS 声明式配置仓库";

  inputs = {
    # 稳定通道：与安装介质版本一致，NAS 稳定优先
    # 经清华 TUNA 镜像拉取，规避 GitHub 访问问题
    nixpkgs.url = "git+https://mirrors.tuna.tsinghua.edu.cn/git/nixpkgs.git?ref=nixos-26.05&shallow=1";
    # 敏感数据加密：基于 age，密钥文件可安全入库
    agenix.url = "github:ryantm/agenix";
  };

  outputs = { self, nixpkgs, agenix, ... }:
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
    in
    {
      packages = {
        aarch64-darwin.nixos-rebuild = nixos-rebuild "aarch64-darwin";
        x86_64-linux.nixos-rebuild = nixos-rebuild "x86_64-linux";
        aarch64-darwin.agenix = agenix-cli "aarch64-darwin";
        aarch64-darwin.ssh-to-age = ssh-to-age "aarch64-darwin";
        aarch64-darwin.kb-builder = kb-builder "aarch64-darwin";
        x86_64-linux.kb-builder = kb-builder "x86_64-linux";
      };

      nixosConfigurations.nas = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          # agenix 模块：提供 age.secrets 声明式解密
          agenix.nixosModules.age
          ./hosts/nas
        ];
      };
    };
}
