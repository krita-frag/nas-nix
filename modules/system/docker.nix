{ config, lib, pkgs, ... }:

# Docker：容器运行时底座（应用容器层宿主）
{
  virtualisation.docker.enable = true;
}
