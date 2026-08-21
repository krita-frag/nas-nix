{ config, lib, pkgs, ... }:

# 内存调优：面向低内存场景
# 策略均按比例或通用值设定，随实际内存自适应，不按机型硬编码
{
  # 1. zram 压缩交换：低内存压力下的首选出路，避免磁盘换页抖动
  #    memoryPercent 按物理内存比例分配（4G→2G、8G→4G），压缩算法默认 zstd
  zramSwap.enable = true;
  zramSwap.memoryPercent = 50;

  # 2. 内核内存行为
  boot.kernel.sysctl = {
    # 保守使用交换：NAS 服务常驻内存优先；zram 优先级高于磁盘 swap，
    # 仅压力过大时经 zram 压缩兜底，磁盘 swap 在 zram 耗尽后才介入
    "vm.swappiness" = 20;
    # 文件系统元数据缓存（dentry/inode）更持久，利于 Samba/Syncthing 高频文件访问
    "vm.vfs_cache_pressure" = 50;
  };

  # 3. systemd-oomd：内存压力下优先回收而非整机冻结，
  #    防止 4GB 低内存场景下系统无响应
  systemd.oomd.enable = true;
}
