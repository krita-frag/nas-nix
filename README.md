# nas-nix

基于 **NixOS Flakes** 的家庭 NAS 声明式配置仓库。全部系统状态以声明式代码描述并纳入 Git 版本控制，敏感信息通过 **agenix** 加密存储，支持从 macOS 一键远程构建部署与多代回滚。

## 特性

- **声明式系统管理**：SSH、Samba、Cockpit、Podman、自动 GC 全部以 NixOS 模块声明
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
│   ├── system/               # 系统层模块
│   └── services/             # 应用服务模块
└── secrets/
    ├── secrets.nix           # agenix CLI 加密规则（仅供 CLI，不导入配置）
    ├── tailscale-auth.age    # Tailscale 认证密钥（加密）
    ├── samba-nas-password.age# Samba 口令（加密）
    └── root-password-hash.age# root 登录口令哈希（加密）
```

## 快速开始

### 前置条件

- NAS 已安装 NixOS，可从管理机密钥登录 `root@<nas-ip>`
- NAS 已生成 SSH 主机密钥（`/etc/ssh/ssh_host_ed25519_key`）

### macOS 管理机安装与配置

管理端只需要 Nix 与 age；构建、切换、密钥加解密全部经本仓库 flake 提供，不要求全局安装额外 CLI。

1. **Nix（Determinate Nix）**
   - 安装后二进制位于 `/nix/var/nix/profiles/default/bin/nix`，默认不在 PATH
   - [deploy.sh](deploy.sh) 已自动处理该路径，直接运行脚本即可
   - 如需在终端直接使用 `nix` 命令，在 `~/.zshrc` 追加：

   ```bash
   export PATH="/nix/var/nix/profiles/default/bin:$PATH"
   ```

2. **Homebrew 与 age**

   ```bash
   brew install age
   ```

   `age`（当前 v1.3.1）供 agenix 加密与本地解密校验使用。

3. **SSH 密钥认证**
   - 管理机已有 `~/.ssh/id_ed25519`，对应公钥已授权在 [modules/system/ssh.nix](modules/system/ssh.nix)（NAS root 登录）与 [secrets/secrets.nix](secrets/secrets.nix)（`admin` 接收者）
   - 更换密钥对时需同步更新上述两处公钥，并对 `.age` 文件重加密（见下文）
   - 首次连接将 NAS 主机指纹加入 `~/.ssh/known_hosts`

4. **agenix CLI（仓库内置，无需全局安装）**
   - nixpkgs 已不向 darwin 提供 agenix 包，本仓库在 [flake.nix](flake.nix) 暴露 `.#agenix`
   - 在 `secrets/` 目录以 `nix run .#agenix -- <子命令>` 调用，见下文「敏感数据（agenix）」一节

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
nix run .#agenix -- -e tailscale-auth.age     # 编辑并重新加密（默认用 ~/.ssh 私钥）
nix run .#agenix -- -e samba-nas-password.age
nix run .#agenix -- -r                        # 修改 secrets.nix 公钥后重加密全部
```

编辑后提交 `.age` 文件并重新部署。**注意**：不要用 `builtins.readFile` 把明文读入配置（会落进 Nix store）。

### Tailscale 认证密钥

Tailscale 的节点注册要求持有凭据（auth key / OAuth client / 交互登录），安全模型上**至少需要一次手动创建**。本项目采用**可重用 + 永不过期**的 auth key，将手动操作压缩到一次性，此后全自动：

- 在 [Tailscale 管理控制台](https://login.tailscale.com/admin/settings/keys) 生成 auth key（勾选 **Reusable + No expiration**），执行 `nix run .#agenix -- -e tailscale-auth.age` 填入并保存
- 节点**首次上线**时由 `tailscaled-autoconnect` 服务消费 `/run/agenix/tailscale-auth` 自动登录；登录状态持久化于 `/var/lib/tailscale/tailscaled.state`，此后即使删除该 key 也不影响已上线节点
- 新增机器或整机重建时，同一仓库配置自动完成组网，无需再次获取密钥

> **换机迁移**：`.age` 文件加密时绑定机器 SSH 主机公钥。新机需将自身公钥加入 `secrets.nix` 后执行 `nix run .#agenix -- -r` 重加密；root 口令等密码哈希本身是声明式常量，随配置迁移有效，无需重新生成。

## 内置服务

| 服务 | 端口 | 说明 |
| --- | --- | --- |
| SSH | 22 | 密钥认证，禁用密码登录 |
| Cockpit | 9090 | 系统状态监控与管理面板（`https://<nas-ip>:9090`，root 登录，口令经 agenix 管理，含 Podman 容器管理） |
| Podman | — | 无守护进程 OCI 容器运行时（容器经 Cockpit 的 podman 模块管理） |
| Syncthing | 8384（GUI）/ 22000（同步） | 多设备文件实时同步 |
| Samba | 445/139 | 家庭文件共享（public 匿名 / nas 用户认证） |
| Tailscale | — | 安全组网与远程访问 |
| Gitea | 3000（Web）/ 22（git SSH） | 自托管 Git 服务，内置 GitHub Actions 兼容 CI（job 容器经 Podman 运行） |
| 内存调优 | — | zram 压缩交换（物理内存 50%）+ 内核内存策略（swappiness/vfs_cache_pressure）+ systemd-oomd 防冻结 |

### Gitea Actions 首次配置

Gitea 部署后安装向导已锁定（`INSTALL_LOCK`），首次使用需一次性完成以下步骤：

1. 浏览器打开 `http://<nas-ip>:3000`，创建首个管理员账号（仅一次）
2. 管理员 → Actions → Runners → **Create new runner**，复制注册令牌
3. 在 NAS 上写入令牌并重启 runner 服务（自动完成注册，此后持久）：

   ```bash
   ssh root@<nas-ip>
   echo '<注册令牌>' > /var/lib/gitea-runner/registration-token
   systemctl restart gitea-runner
   ```

4. 仓库内启用 Actions，`.gitea/workflows/*.yaml` 即按 GitHub Actions 语法执行；job 容器由 **Podman** 运行（经 Docker 兼容 socket），镜像走已配置的 Docker Hub 加速。

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

# Gitea / Actions
ss -tln | grep 3000                      # Gitea Web 监听
systemctl is-active gitea gitea-runner   # Gitea 与 runner 服务
curl -sf http://127.0.0.1:3000/api/v1/version  # Gitea 版本 API 应答
ls /run/docker.sock                      # Podman Docker 兼容 socket（runner 依赖）

# zram / GC
zramctl                                  # 应见 /dev/zram0 [SWAP]
sysctl vm.swappiness vm.vfs_cache_pressure  # 应为 20 / 50
systemctl is-active systemd-oomd         # oomd 已启用
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
