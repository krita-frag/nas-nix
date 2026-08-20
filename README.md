# nas-nix

基于 **NixOS Flakes** 的家庭 NAS 声明式配置仓库。全部系统状态以声明式代码描述并纳入 Git 版本控制，敏感信息通过 **agenix** 加密存储，支持从 macOS 一键远程部署与多代回滚。

## 特性

- **声明式系统管理**：SSH、Tailscale、Samba、Cockpit、Docker、zram、自动 GC 全部以 NixOS 模块声明
- **可复现**：`flake.lock` 锁定输入版本，任一环境可重建一致系统
- **原子部署与回滚**：基于 NixOS generation，`switch` 原子切换，`--rollback` 一键回滚
- **安全**：SSH 密钥认证、Tailscale 私有组网、敏感数据 agenix 加密入库
- **模块化扩展**：应用服务"一服务一文件"，按需增删不影响系统核心
- **系统干净**：声明式包管理 + 自动垃圾回收，无历史包残留

## 仓库结构

```
├── flake.nix                 # Flake 入口：输入定义与主机装配
├── flake.lock                # 输入锁定（随仓库提交）
├── hosts/
│   └── nas/
│       ├── default.nix              # 主机级配置组装
│       └── hardware-configuration.nix
├── modules/
│   ├── system/               # 系统层模块（ssh/tailscale/samba/cockpit/docker/zram/nix-gc）
│   └── services/             # 应用容器层模块（portainer/syncthing，按需扩展）
├── secrets/                  # agenix 加密的敏感数据与声明
└── DEVELOPMENT_PLAN.md       # 开发计划文档
```

## 快速开始

### 前置条件

- NAS 已安装 NixOS，可从管理机密钥登录 `root@<nas-ip>`
- 管理机（macOS）已安装 Nix 与 `age`

### 远程部署（从 macOS）

```bash
# 部署最新配置
nixos-rebuild switch \
  --flake .#nas \
  --target-host root@<nas-ip> \
  --use-remote-sudo

# 构建但不切换（预演）
nixos-rebuild dry-activate --flake .#nas --target-host root@<nas-ip>

# 回滚到上一代
nixos-rebuild switch --flake .#nas --target-host root@<nas-ip> --rollback
```

### 升级依赖

```bash
nix flake lock --update-input nixpkgs
nixos-rebuild switch --flake .#nas --target-host root@<nas-ip>
```

## 内置服务

| 服务 | 端口 | 说明 |
| --- | --- | --- |
| Cockpit | 9090 | 系统状态监控与管理面板 |
| Portainer | 9000 | Docker 容器管理面板 |
| Syncthing | 8384 | 多设备文件同步 |
| Samba | 445/139 | 家庭文件共享 |
| Tailscale | — | 安全组网与远程访问 |

## 安全模型

- SSH 仅密钥认证，禁用密码登录
- 全部敏感数据（口令、API 密钥、证书）经 agenix 加密，仅绑定主机 SSH key 可解密
- 防火墙默认开启，仅放行必需端口；远程访问经由 Tailscale 私有网络

## 维护

修改配置 → `git commit` → `nixos-rebuild switch`；密钥编辑使用 `agenix -e secrets/<file>.age`。详见 [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md) 第 9 节维护指南。
