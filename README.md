# nas-nix

基于 **NixOS Flakes** 的家庭 NAS 声明式配置仓库。全部系统状态以声明式代码描述并纳入 Git 版本控制，敏感信息通过 **agenix** 加密存储，支持从 macOS 一键远程构建部署与多代回滚。

## 特性

- **声明式系统管理**：SSH、Tailscale、Samba、Cockpit、Podman、zram、自动 GC 全部以 NixOS 模块声明
- **可复现**：`flake.lock` 锁定输入版本，任一环境可重建一致系统
- **原子部署与回滚**：基于 NixOS generation，`switch` 原子切换，`--rollback` 一键回滚
- **安全**：SSH 密钥认证、Tailscale 私有组网、敏感数据 agenix 加密入库
- **模块化扩展**：应用服务"一服务一文件"，按需增删不影响系统核心
- **系统干净**：声明式包管理 + 自动垃圾回收，无历史包残留

## 仓库结构

```
├── flake.nix                 # Flake 入口：输入定义与主机装配
├── flake.lock                # 输入锁定（随仓库提交）
├── deploy.sh                 # 一键部署脚本（switch/预演/回滚/冒烟）
├── hosts/
│   └── nas/
│       ├── default.nix              # 主机级配置组装
│       └── hardware-configuration.nix
├── modules/
│   ├── system/               # 系统层模块（ssh/agenix/tailscale/samba/cockpit/podman/tools/zram/nix-gc）
│   └── services/             # 应用服务模块（syncthing，按需扩展）
└── secrets/
    ├── secrets.nix           # agenix CLI 加密规则（仅供 CLI，不导入配置）
    ├── tailscale-auth.age    # Tailscale 认证密钥（加密）
    ├── samba-nas-password.age# Samba 口令（加密）
    └── root-password-hash.age# root 登录口令哈希（加密）
```

## 快速开始

### 前置条件

- NAS 已安装 NixOS，可从管理机密钥登录 `root@<nas-ip>`
- 管理机（macOS）已安装 Nix；`age` 随系统或经 `brew install age` 提供
- NAS 已生成 SSH 主机密钥（`/etc/ssh/ssh_host_ed25519_key`）

### 远程部署（从 macOS）

一键部署（构建在 NAS 上完成 `--build-host`，切换也在 NAS 执行 `--target-host`）：

```bash
./deploy.sh                 # 构建并切换（默认目标 192.168.64.4）
./deploy.sh smoke           # 部署后冒烟验证
./deploy.sh dry-run         # 预演（构建但不切换）
./deploy.sh rollback        # 回滚到上一代
TARGET=192.168.64.4 ./deploy.sh   # 指定目标主机
```

等价的原生命令（供自定义流程参考）：

```bash
nix run .#nixos-rebuild -- switch \
  --flake .#nas \
  --build-host root@<nas-ip> \
  --target-host root@<nas-ip>
```

### 升级依赖

```bash
nix flake lock --update-input nixpkgs
# 再按上述命令重新部署
```

## 敏感数据（agenix）

敏感信息以 age 加密成 `.age` 文件入库，明文不落盘；只有持有对应私钥的主机/用户可解密。

- **加密规则**：[secrets/secrets.nix](secrets/secrets.nix) 声明每个 `.age` 文件允许解密的公钥（NAS 主机密钥 + 管理机密钥）
- **解密声明**：[modules/system/agenix.nix](modules/system/agenix.nix) 声明解密后挂载到 `/run/agenix/<name>` 供服务消费
- **解密方式**：部署激活阶段以 NAS 主机私钥 `/etc/ssh/ssh_host_ed25519_key` 自动解密（`age.identityPaths` 默认即主机密钥）

新增或修改密钥：

```bash
cd secrets
agenix -e tailscale-auth.age          # 编辑并重新加密（默认用 ~/.ssh 私钥）
agenix -e samba-nas-password.age
agenix -r                             # 修改 secrets.nix 公钥后重加密全部
```

编辑后提交 `.age` 文件并重新部署。**注意**：不要用 `builtins.readFile` 把明文读入配置（会落进 Nix store）。

### Tailscale 认证密钥

Tailscale 的节点注册要求持有凭据（auth key / OAuth client / 交互登录），安全模型上**至少需要一次手动创建**。本项目采用**可重用 + 永不过期**的 auth key，将手动操作压缩到一次性，此后全自动：

- 在 [Tailscale 管理控制台](https://login.tailscale.com/admin/settings/keys) 生成 auth key（勾选 **Reusable + No expiration**），执行 `agenix -e tailscale-auth.age` 填入并保存
- 节点**首次上线**时由 `tailscaled-autoconnect` 服务消费 `/run/agenix/tailscale-auth` 自动登录；登录状态持久化于 `/var/lib/tailscale/tailscaled.state`，此后即使删除该 key 也不影响已上线节点
- 新增机器或整机重建时，同一仓库配置自动完成组网，无需再次获取密钥

> **换机迁移**：`.age` 文件加密时绑定机器 SSH 主机公钥。新机需将自身公钥加入 `secrets.nix` 后执行 `agenix -r` 重加密；root 口令等密码哈希本身是声明式常量，随配置迁移有效，无需重新生成。

## 内置服务

| 服务 | 端口 | 说明 |
| --- | --- | --- |
| SSH | 22 | 密钥认证，禁用密码登录 |
| Cockpit | 9090 | 系统状态监控与管理面板（`https://<nas-ip>:9090`，root 登录，口令经 agenix 管理，含 Podman 容器管理） |
| Podman | — | 无守护进程 OCI 容器运行时（容器经 Cockpit 的 podman 模块管理） |
| Syncthing | 8384（GUI）/ 22000（同步） | 多设备文件实时同步 |
| Samba | 445/139 | 家庭文件共享（public 匿名 / nas 用户认证） |
| Tailscale | — | 安全组网与远程访问 |
| zramSwap | — | 内存压缩交换（约物理内存 50%） |

## 冒烟清单

部署或回滚后可运行以下检查确认系统健康：

```bash
# agenix 密钥已挂载
ls /run/agenix/                          # 应见 tailscale-auth、samba-nas-password

# SSH
ssh root@<nas-ip>                        # 应免密登录，密码登录被拒

# Samba
smbclient //localhost/public -N -c ls    # 匿名可访问
smbclient //localhost/nas -U nas -c ls   # 用户认证可访问；错误口令被拒

# Cockpit
ss -tln | grep 9090                      # 面板监听

# Podman
podman info                               # 运行时健康
podman ps                                 # 容器列表（经 Cockpit podman 模块管理）

# Syncthing
ss -tln | grep 8384                      # GUI 监听（默认仅本机）

# zram / GC
zramctl                                  # 应见 /dev/zram0 [SWAP]
systemctl list-timers | grep nix-gc      # 自动 GC 定时器存在

# 回滚可用性
nix-env --list-generations --profile /nix/var/nix/profiles/system  # 存在多代可回滚
```

## 安全模型

- SSH 仅密钥认证，禁用密码登录，管理机公钥在 [modules/system/ssh.nix](modules/system/ssh.nix) 声明
- 全部敏感数据经 agenix 加密，仅绑定主机 SSH 密钥可解密；密钥文件可安全提交到 Git
- 防火墙默认开启，仅放行必需端口；远程访问经 Tailscale 私有网络

## 维护

修改配置 → 提交（`git commit`）→ `./deploy.sh` 一键部署。密钥编辑见上文 agenix 一节。开发计划与部署细节以本地 `plans/DEVELOPMENT_PLAN.md` 为准（该目录不入库）。
