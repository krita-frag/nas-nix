{
  description = "NixOS NAS 声明式配置仓库";

  inputs = {
    # 稳定通道：与安装介质版本一致，NAS 稳定优先
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
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
