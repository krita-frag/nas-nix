#!/usr/bin/env bash
# 新增一台 NAS 主机的脚手架：生成 hosts/<name>/ 占位配置并提示后续步骤
# 用法: nix run .#new-host -- <hostname>
set -euo pipefail

NAME="${1:?用法: nix run .#new-host -- <hostname>}"
if [ ! -d hosts ] || [ ! -f flake.nix ]; then
  echo "错误：请在本仓库根目录运行。" >&2
  exit 1
fi
DIR="hosts/${NAME}"
if [ -e "$DIR/default.nix" ]; then
  echo "已存在 ${DIR}/default.nix，中止。" >&2
  exit 1
fi
mkdir -p "$DIR"

cat > "$DIR/default.nix" <<EOF
{ config, lib, pkgs, modulesPath, ... }:

# 新主机占位组装：从 bootstrap 可运行的最小集合起步，
# 其余服务模块按需在 imports 中追加（见 hosts/nas/default.nix 作参照）。
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/system/ssh.nix
    ../../modules/system/tailscale.nix
    ../../modules/system/memory.nix
    ../../modules/system/agenix.nix
  ];

  networking.hostName = "${NAME}";
  networking.networkmanager.enable = true;

  system.stateVersion = "26.05";
}
EOF

cat > "$DIR/hardware-configuration.nix" <<EOF
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
EOF

echo "已生成 ${DIR}/。后续步骤（flake 已自动推导，无需手工注册）："
echo "  1) 在 NAS 上运行 nixos-generate-config 覆盖 ${DIR}/hardware-configuration.nix"
echo "  2) 如需首装最小系统，建同级文件 hosts/${NAME}-bootstrap.nix（参照 hosts/nas-bootstrap.nix）"
echo "  3) 把新机 SSH 主机公钥加入 secrets/secrets.nix，并 cd secrets && nix run .#agenix -- -r"
echo "  4) HOST=${NAME} TARGET=<地址> ./deploy.sh"