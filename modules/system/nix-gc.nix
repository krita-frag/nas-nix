{ config, lib, pkgs, ... }:

# 自动垃圾回收：定期清理旧代与缓存，保持系统干净
{
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;
}
