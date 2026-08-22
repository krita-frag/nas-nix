{ config, lib, pkgs, ... }:

# 运维工具集 + 构建工具链预装。
# nas-host（本机直跑）的 Actions job 继承宿主 PATH（gitea.nix 中 runner path 指向
# config.system.path，即全部 systemPackages），因此本文件是工具链唯一声明点：
# 新增工具仅在此添加，job 内即可直接使用，免每次下载/安装。
{
  environment.systemPackages = with pkgs; [
    smartmontools # smartctl：磁盘 SMART 健康检查（smartd 守护待实机接入数据盘后再启用）
    ncdu          # 磁盘占用分析
    btop          # 终端实时系统监控
    jq            # JSON 处理（脚本/自动化）

    # Actions 基础：解释器/运行时与版本控制（runner 本机直跑 job 依赖）
    git
    python3
    nodejs    # JS/TS 运行时（高频 CI 依赖，体积中等）
    which     # CI 脚本高频引用（host job PATH 默认无 which）

    # 编译/构建工具链：go/rust 构建、C 原生链接与常见构建系统
    go
    rustc
    cargo
    gcc
    gnumake    # make：经典构建工具（nixpkgs 中属性名为 gnumake）
    cmake      # 常见构建系统（体积中等，覆盖大量 C/C++ 项目）
    ninja      # 快速构建后端（配合 cmake/meson，体积小）
    pkg-config # 原生库发现（编译 C/C++ 依赖所需，极小）

    # 编译加速：ccache 缓存 C/C++/Rust 编译产物，重复构建显著提速（体积小）
    ccache

    # 通用工具：解压/打包与打补丁（CI 高频，均极小）
    unzip
    zip
    patch
    zstd # 快速压缩（体积小，替代 gzip 用于产物/缓存）
  ];
}
