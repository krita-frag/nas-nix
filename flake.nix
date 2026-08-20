{
  description = "NixOS NAS 声明式配置仓库";

  inputs = {
    # 稳定通道：与安装介质版本一致，NAS 稳定优先
    # 经清华 TUNA 镜像拉取，规避 GitHub 访问问题
    nixpkgs.url = "git+https://mirrors.tuna.tsinghua.edu.cn/git/nixpkgs.git?ref=nixos-26.05&shallow=1";
  };

  outputs = { self, nixpkgs, ... }:
    {
      nixosConfigurations.nas = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./hosts/nas
        ];
      };
    };
}
