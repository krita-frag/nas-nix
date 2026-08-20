{ config, lib, pkgs, ... }:

# zramSwap：内存压缩交换，提升低内存场景响应
{
  zramSwap.enable = true;
  # 约占物理内存一半，算法默认 zstd
  zramSwap.memoryPercent = 50;
}
