#!/usr/bin/env bash
#
# 干净安装脚本（在 NixOS live 环境内以 root 运行）
#
# 目标：一次做对引导器，杜绝 loop 坑。
# 背景：此前用 losetup 把目标文件系统挂到 /dev/loopX 再跑 nixos-install，
#       grub-install 会把 core.img 的 prefix 写成 /dev/loopX，重启后该设备
#       不存在 → "unknown filesystem" → grub rescue。本脚本只挂真实分区。
#
# 用法（抹盘前必须显式带 ZAP=1，防误操作）:
#   ./install.sh /dev/nvme0n1            # 实机
#   ./install.sh /dev/vda                # VM 验证（virtio 磁盘）
#   ZAP=1 ./install.sh /dev/nvme0n1      # 确认并执行
#   FLAKE=.#nas-bootstrap INSTALL_REPO=/tmp/nas-src ./install.sh /dev/nvme0n1
#
set -euo pipefail

DEV="${1:?用法: install.sh <磁盘设备，如 /dev/nvme0n1 或 /dev/vda>}"
REPO="${INSTALL_REPO:-/tmp/nas-src}"
FLAG="${FLAKE:-.#nas-bootstrap}"
BOOT_LABEL=NIXBOOT
ROOT_LABEL=NIXROOT

# 安全闸：整盘操作前必须显式 ZAP=1
if [ "${ZAP:-0}" != "1" ]; then
  echo "危险操作：即将抹掉 ${DEV} 并重建为 标准 GPT(ESP + 根)。如确认请 ZAP=1 重跑。" >&2
  exit 1
fi

for c in sgdisk partprobe mkfs.vfat mkfs.ext4 nixos-install; do
  command -v "$c" >/dev/null || { echo "缺少工具: $c（live 环境应自带）" >&2; exit 1; }
done

echo "==> [1/6] 卸载可能残留的 /mnt /mnt/boot"
mountpoint -q /mnt/boot 2>/dev/null && umount /mnt/boot || true
mountpoint -q /mnt 2>/dev/null && umount /mnt || true

echo "==> [2/6] 清空旧分区表 + 重建标准 GPT（${DEV}）"
sgdisk --zap-all "$DEV"
sgdisk --new=1:0:+1G --typecode=1:ef00 --change-name=1:"$BOOT_LABEL" "$DEV"
sgdisk --new=2:0:0   --typecode=2:8300 --change-name=2:"$ROOT_LABEL" "$DEV"

echo "==> [3/6] 让内核重新读取分区表（关键：不再用 loop 绕道）"
partprobe "$DEV"
sleep 2
udevadm settle

# 按设备名推断分区号（nvme/mmc 用 p1/p2，其余用 1/2）
case "$DEV" in
  *nvme*|*mmc*|*loop*) PBOOT="${DEV}p1"; PROOT="${DEV}p2" ;;
  *)                   PBOOT="${DEV}1"; PROOT="${DEV}2" ;;
esac
for p in "$PBOOT" "$PROOT"; do
  if [ ! -e "$p" ]; then
    echo "错误：内核未识别新分区 $p。" >&2
    echo "先 partprobe/partx，若仍无则重启 live 让内核重新扫盘；切勿用 losetup 凑合。" >&2
    exit 1
  fi
done
echo "     ESP=${PBOOT}  根=${PROOT}"

echo "==> [4/6] 格式化"
mkfs.vfat -F 32 -n "$BOOT_LABEL" "$PBOOT"
mkfs.ext4 -L "$ROOT_LABEL" "$PROOT"

echo "==> [5/6] 挂载真实分区"
# 必须先挂根、再在其下建 /boot：先建 /mnt/boot 会在挂根后被新文件系统盖住而消失。
mount "$PROOT" /mnt
mkdir -p /mnt/boot
mount "$PBOOT" /mnt/boot
findmnt /mnt /mnt/boot || true  # 仅展示挂载点；部分文件系统无 LABEL 时 findmnt 返回非零，不阻断

echo "==> [6/6] nixos-install（${FLAG}，来自 ${REPO}）"
if [ ! -f "$REPO/flake.nix" ]; then
  echo "错误：flake 源不存在 ${REPO}/flake.nix（先把仓库拷到目标机）" >&2
  exit 1
fi
cd "$REPO"
nixos-install --flake "$FLAG" --no-root-passwd --no-channel-copy

echo
echo "==> 完成。重启前提示："
echo "  - 引导项写入真分区，old NVRAM 里的坏 grub 项需在进系统后清掉："
echo "      efibootmgr   # 看 BootOrder / Bootxxxx"
echo "      efibootmgr -b <坏项Num> -B   # 删除残留坏项"
echo "  - 若固件不进新引导，进 live 后重跑 grub-install --removable 补回退文件。"