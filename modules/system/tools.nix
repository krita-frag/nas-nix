{ config, lib, pkgs, ... }:

# 运维工具集：轻量、低占用，覆盖 NAS 日常排查
{
  environment.systemPackages = with pkgs; [
    smartmontools # smartctl：磁盘 SMART 健康检查（smartd 守护待实机接入数据盘后再启用）
    ncdu          # 磁盘占用分析
    btop          # 终端实时系统监控
    jq            # JSON 处理（脚本/自动化）
  ];
}
