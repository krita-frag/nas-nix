{
  description = "NixOS NAS 声明式配置仓库";

  inputs = {
    # 稳定通道：与安装介质版本一致，NAS 稳定优先
    # 经清华 TUNA 镜像拉取，规避 GitHub 访问问题
    nixpkgs.url = "git+https://mirrors.tuna.tsinghua.edu.cn/git/nixpkgs.git?ref=nixos-26.05&shallow=1";
    # 敏感数据加密：基于 age，密钥文件可安全入库
    agenix.url = "github:ryantm/agenix";
    # 自托管 GitHub Pages 引擎（codeberg.page 新一代实现）：
    # flake 直接产出静态 musl 二进制，供 services/pages.nix 本机托管
    git-pages.url = "github:whitequark/git-pages";
  };

  outputs = { self, nixpkgs, agenix, git-pages, ... }:
    let
      # 部署工具：从 macOS（aarch64-darwin）驱动远程构建/切换
      nixos-rebuild = system: nixpkgs.legacyPackages.${system}.nixos-rebuild;
      # agenix CLI：管理端加密/编辑密钥；ssh-to-age：SSH 公钥转 age 接收者
      agenix-cli = system: agenix.packages.${system}.default;
      ssh-to-age = system: nixpkgs.legacyPackages.${system}.ssh-to-age;
    in
    {
      packages = {
        aarch64-darwin.nixos-rebuild = nixos-rebuild "aarch64-darwin";
        x86_64-linux.nixos-rebuild = nixos-rebuild "x86_64-linux";
        aarch64-darwin.agenix = agenix-cli "aarch64-darwin";
        aarch64-darwin.ssh-to-age = ssh-to-age "aarch64-darwin";
      };

      nixosConfigurations.nas = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        # git-pages 引擎二进制：flake 直接产出静态 musl Go 程序，
        # 经 specialArgs 注入 modules/services/pages.nix 本机托管
        specialArgs = { git-pages = git-pages.packages.x86_64-linux.default; };
        modules = [
          # agenix 模块：提供 age.secrets 声明式解密
          agenix.nixosModules.age
          ./hosts/nas
        ];
      };
    };
}
