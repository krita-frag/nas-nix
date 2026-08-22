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
├── deploy.sh                 # 一键部署脚本（switch/预演/回滚/冒烟/check）
├── hosts/
│   └── nas/
│       ├── default.nix              # 主机级配置组装
│       └── hardware-configuration.nix
├── modules/
│   ├── system/               # 系统层模块
│   └── services/             # 应用服务模块（含 tailscale-serve.nix 通用 HTTPS 入口）
├── runner/                   # Gitea Actions kb-builder 预烘焙镜像（Dockerfile + 构建脚本）
└── secrets/
    ├── secrets.nix           # agenix CLI 加密规则（仅供 CLI，不导入配置）
    ├── tailscale-auth.age    # Tailscale 认证密钥（加密）
    ├── samba-nas-password.age# Samba 口令（加密）
    ├── root-password-hash.age# root 登录口令哈希（加密）
    ├── restic-repo-password.age# 备份仓库口令（加密）
    └── rclone-conf.age       # rclone 网盘凭据（加密，实机接入后生成）
```

## 快速开始

### 前置条件

- NAS 已安装 NixOS，可从管理机密钥登录 `root@<nas-ip>`
- NAS 已生成 SSH 主机密钥（`/etc/ssh/ssh_host_ed25519_key`）
- **VM 与实机**：仓库内 [hardware-configuration.nix](hosts/nas/hardware-configuration.nix) 为测试 VM 的 qemu-guest 版（含 VM 磁盘 UUID 与 swap）。实机安装需在 NAS 上运行 `nixos-generate-config` 重新生成该文件（自动探测磁盘、引导器与挂载），再提交回仓库；部署时用 `TARGET=<实机IP>` 覆盖默认 VM 地址即可，无需改动其他配置

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
./deploy.sh check           # 本地配置校验（nix eval，无需 SSH，部署前快检）
TARGET=192.168.64.4 ./deploy.sh   # 指定目标主机
```

知识库发布不在此脚本：引擎仓库 [nas-docs](https://github.com/krita-frag/nas-docs) 自带 `publish.sh` 触发统一构建。

新机引导：GitHub 为主源、Gitea 为本地镜像。新 NAS 尚无 Gitea 时，从 GitHub 克隆本仓库与 nas-docs；Gitea 搭建好后把两仓库镜像到 Gitea（`<gitea-user>/*`）。文内 GitHub 链接为本项目实际地址，fork 或改名后请替换为你自己的地址。

等价的原生命令（供自定义流程参考）：

```bash
nix run .#nixos-rebuild -- switch \
  --flake .#nas \
  --build-host root@<nas-ip> \
  --target-host root@<nas-ip>
```

### 新机引导清单

从零搭建一台 NAS（VM 或实机）的完整步骤：

1. **安装 NixOS**：生成并保存 `hardware-configuration.nix`（VM 用仓库内 qemu-guest 版；实机用 `nixos-generate-config` 重新生成）
2. **克隆仓库**：从 GitHub 克隆本仓库与 [nas-docs](https://github.com/krita-frag/nas-docs)（GitHub 为主源，Gitea 为本地镜像）
3. **授权密钥**：把新机 SSH 主机公钥（`/etc/ssh/ssh_host_ed25519_key.pub`）加入 [secrets/secrets.nix](secrets/secrets.nix) 接收者，在 `secrets/` 执行 `nix run .#agenix -- -r` 重加密全部 `.age`；管理机公钥已在 [modules/system/ssh.nix](modules/system/ssh.nix) 与 secrets.nix 声明
4. **首次部署**：`TARGET=<新机IP> ./deploy.sh`（首次构建较久）；若密钥仍解不开 `.age`，回到上一步确认接收者
5. **Gitea 初始化**：浏览器打开 `http://<nas-ip>:3000` 创建管理员账号（仅一次）
6. **注册 runner**：Gitea 后台生成注册令牌 → NAS 上写入 `/var/lib/gitea-runner/registration-token` → `systemctl restart gitea-runner`（见「内置服务」节）
7. **镜像仓库**：把 nas-nix、nas-docs 推到 Gitea（`<gitea-user>/*`），后续 Actions 从 Gitea 拉取构建
8. **启用 Serve**（可选）：在 [Tailscale 管理台](https://login.tailscale.com/admin) 启用 Serve，供强制 https 的爬虫经尾网 HTTPS 访问知识库（最多 1 小时内自动生效）

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
| Syncthing | 8384（GUI，仅本机）/ 22000（同步） | 多设备文件实时同步 |
| Samba | 445/139 | 家庭文件共享（public 匿名 / nas 用户认证） |
| Tailscale | — | 安全组网与远程访问 |
| Gitea | 3000（Web）/ 22（git SSH） | 自托管 Git 服务，内置 GitHub Actions 兼容 CI（job 容器经 Podman 运行）与 OCI 镜像仓库；经 Tailscale Serve 提供尾网 HTTPS 入口 `https://<机器名>.ts.net:8443/`（仅 tailnet 内可达） |
| 知识库 Docs | 8080 | 统一知识库中心（单一 MkDocs 站点）：`<nas-ip>:8080/` 统一主页 + 统一导航 + 全站搜索，各知识库位于 `/owner/name/`；引擎仓库（nas-docs）经 Actions 把各仓库 docs/ 合并为单一站点 → 直接写入站点根，Caddy 静态服务；另经 Tailscale Serve 提供尾网 HTTPS 入口 `https://<机器名>.ts.net/`（供强制 https 的爬虫，仅 tailnet 内可达） |
| 内存调优 | — | zram 压缩交换（物理内存 50%）+ 内核内存策略（swappiness/vfs_cache_pressure）+ systemd-oomd 防冻结 |
| 备份 | — | restic 加密快照 + rclone 网盘（3-2-1 异地加密副本，见下节） |

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

4. 仓库内启用 Actions，`.gitea/workflows/*.yaml` 即按 GitHub Actions 语法执行。

#### Runner 标签（`runs-on`）与性能取向

构建性能取决于 job 环境：runner 经 systemd 注入 `git/python3/bash`，本机直跑（`nas-host`）无容器/镜像/安装开销，最快；预烘焙镜像（`kb-builder`）把依赖一次装进本地镜像，容器隔离且免每次安装。二者均直连本机 Gitea（`127.0.0.1:3000`，host 网络），并声明 `no_proxy` 绕过管理机代理，避免访问本机 127.0.0.1 被代理 502。

| 标签 | 运行方式 | 适用 | 参考耗时 |
| --- | --- | --- | --- |
| `nas-host` | NixOS 宿主以 `gitea-runner` 用户直跑（无容器） | 受信任仓库，最快 | 知识库整体构建 ~20s |
| `kb-builder` | Podman 容器（本地预烘焙镜像，git/mkdocs 已预装） | 需容器隔离的仓库 | 知识库整体构建 ~40s |
| `ubuntu-latest` 等 | Podman 容器（node:20-bookworm） | 通用/第三方 action | 含每次依赖安装 |

- 知识库引擎默认用 `kb-builder`（容器隔离，收敛信任边界）；`nas-host` 的 job 直接以 `gitea-runner` 权限在宿主执行，信任边界扩大，仅限高度受信任的本地仓库使用。
- host job 复用宿主工具：runner PATH 指向 `config.system.path`（systemPackages 聚合），[tools.nix](modules/system/tools.nix) 预装的 git/python3/node/go/rust/gcc/make/cmake/ccache 等工具链对 job 直接可见，免每次下载安装；新增工具只需在该文件添加。
- 预烘焙镜像在 NAS 本地构建（`nix run .#kb-builder`，等价 `bash runner/build-kb-image.sh`，与 runner 共用镜像存储免 registry push）；镜像随系统重装丢失，重建一条命令即可。
- 知识库构建的 Python 依赖（mkdocs-material 等）复用持久缓存 venv（`/var/lib/gitea-runner/kb-cache` 或容器 `/kb-cache`），跨运行不重复 pip install。
- 信任收敛：Gitea 已关闭匿名自助注册（`service.DISABLE_REGISTRATION`），账号由管理员后台创建；`PAGES_TOKEN` 建议用独立非管理员账号（如 `kb-robot`）的 write:repository token，泄露时不波及管理账号。

### 知识库中心（Docs）

Docs 是**单一 MkDocs 站点**：引擎独立于内容仓库，位于 **nas-docs**（唯一注册点 `repos.json` + 统一渲染），内容仓库只提供 Markdown。统一 UI（全站同一 Material 主题、同一导航、全站搜索，无子站割裂）。无 Webhook、无反向代理正则、无逐仓库钩子/token/workflow。

架构（引擎 nas-docs 的 `build.sh`，Nix 侧见 [modules/services/docs.nix](modules/services/docs.nix)）：

```
push nas-docs main / 每 6h 定时 / 手动 dispatch
  → Actions 读 repos.json → clone 各内容仓库（docs/ 或 .kb.yml 指定路径）
  → 合并到统一 docs_dir（<owner>/<name>/）→ 生成统一主页与 nav → 单一 mkdocs build
  → 直接写入站点根 /var/www/docs → Caddy 静态服务 :8080
```

为任意 Gitea 仓库注册知识库（内容仓库零配置，无需 mkdocs.yml / workflow / token / 钩子）：

1. 内容仓库根目录放 `docs/` 知识库源（纯 Markdown），或加 `.kb.yml` 覆盖标题/路径/自定义导航
2. 在引擎仓库 nas-docs 的 `repos.json` 的 `repos` 列表加一行（`owner`/`name` + 可选 `desc`）
3. 在引擎仓库 nas-docs 运行 `GITEA_PASS=<口令> bash publish.sh`（触发立即重建）或等待每 6h 定时自动同步

之后引擎每次重建自动把该仓库构建进统一站点，主页自动出现新卡片。

**尾网 HTTPS 入口**（供强制 https 的爬虫抓取）：站点默认仅 HTTP 监听，另经 Tailscale Serve 挂到尾网 `https://<机器名>.ts.net/`（仅 tailnet 内可达、无公网暴露）。通用模块 [tailscale-serve.nix](modules/services/tailscale-serve.nix) 统一管理：Docs 在 `https://<机器名>.ts.net/`（443），Gitea 在 `https://<机器名>.ts.net:8443/`。一次性手动步骤：在 [Tailscale 管理台](https://login.tailscale.com/admin) 启用 **Serve**，此后本机服务自动生效，无需重启。

### 备份与恢复（restic + rclone）

集中备份遵循 **3-2-1**：NAS 为本地主副本，restic 加密快照 + rclone 上传网盘作异地加密副本。数据范围见 [modules/services/backup.nix](modules/services/backup.nix)（默认 `/srv/shares` + `/srv/syncthing` + `/var/lib/gitea` 全量关键数据）。

- **启用**：在 [hosts/nas/default.nix](hosts/nas/default.nix) 的 `services.backup.repository` 填入实际仓库（S3 原生 `s3:s3.<region>.amazonaws.com/<bucket>` 或 rclone 桥接 `rclone:<remote>:<path>`），部署后自动启用每日 03:00 备份（`Persistent` 补跑错过的任务）。留空为骨架状态，不执行备份
- **口令**：restic 仓库口令经 agenix 加密（`restic-repo-password.age`，nas + 管理机双接收者），明文不入库；需要时在 `secrets/` 执行 `nix run .#agenix -- -d restic-repo-password.age` 解密
- **rclone 凭据**：rclone 桥接后端需远端凭据，在 `secrets/` 执行 `nix run .#agenix -- -e rclone-conf.age` 填入 rclone 配置，再把路径填入 `services.backup.rcloneConf`（如 `/run/agenix/rclone-conf`），模块以 `RCLONE_CONFIG` 注入备份服务
- **保留策略**：每日 7 份 + 每周 4 份 + 每月 12 份，prune 自动清理

常用操作（NAS 上）：

```bash
# 备份状态
systemctl status restic-backups-nas-data
# 查看快照
restic -r <repository> snapshots
# 挂载浏览历史版本
restic -r <repository> mount /mnt/restore
# 恢复单个文件
restic -r <repository> restore latest --target /tmp/restore --include "path/to/file"
```

**整机恢复演练**（灾难恢复 runbook，建议定期演练）：

1. 新机安装 NixOS 并完成仓库引导（见「新机引导清单」），部署配置到可运行状态
2. 恢复数据：`restic -r <repository> restore latest --target / --path /srv/shares --path /srv/syncthing --path /var/lib/gitea`，或 `restic -r <repository> mount /mnt/restore` 挂载后按需复制
3. 校验：Samba/Syncthing/Gitea 服务正常、关键数据与备份源 diff 一致、`restic check` 通过
4. 密钥适配：新机公钥加入 [secrets.nix](secrets/secrets.nix) 后 `nix run .#agenix -- -r` 重加密全部 `.age`

### 自托管服务一键部署（Gitea → NAS）

在 Gitea 开发的服务可一键部署到 NAS 测试：push 触发 Actions 经 Podman 构建镜像 → 推入 Gitea 内置镜像仓库 → NAS 本机运行（开发期 `docker run` 临时容器，稳定后 Quadlet/systemd 托管并固化进 NixOS）。完整流程、Actions 模板与 Quadlet 示例见 [docs/container-deploy.md](docs/container-deploy.md)。

服务/工具若需作为 **NixOS 系统一部分**（非容器，systemd 托管、随系统回滚、可复用模块），用服务 flake 模板接入：见 [docs/nixos-native-deploy.md](docs/nixos-native-deploy.md) 与 [docs/service-flake.example.nix](docs/service-flake.example.nix)。

## 冒烟清单

部署或回滚后可运行以下检查确认系统健康：

```bash
# agenix 密钥已挂载
ls /run/agenix/                          # 应见 tailscale-auth、samba-nas-password、root-password-hash、restic-repo-password

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
ls /etc/containers/registries.conf.d/gitea-registry.conf  # 本机镜像仓库（insecure）配置

# 知识库 Docs
ss -tln | grep 8080                         # Caddy 对外端口监听
systemctl is-active caddy                   # Caddy 服务
curl -sf http://127.0.0.1:8080/ | grep -o 'NAS 知识库中心'   # 主页（MkDocs 聚合所有注册知识库）
git ls-remote http://127.0.0.1:3000/<gitea-user>/nas-docs.git refs/heads/pages  # 引擎 pages 信号分支存在
tailscale serve status                    # 应显示 https://<机器名>.ts.net/ → http://127.0.0.1:8080（启用 Serve 前为 No serve config）

# zram / GC
zramctl                                  # 应见 /dev/zram0 [SWAP]
sysctl vm.swappiness vm.vfs_cache_pressure  # 应为 20 / 50
systemctl is-active systemd-oomd         # oomd 已启用
systemctl list-timers | grep nix-gc      # 自动 GC 定时器存在

# 回滚可用性
nix-env --list-generations --profile /nix/var/nix/profiles/system  # 存在多代可回滚
```

## 安全模型

### 暴露面（攻击面）

- SSH 仅密钥认证（禁用密码/键盘交互登录），限尝试次数（`MaxAuthTries=3`），管理机公钥在 [modules/system/ssh.nix](modules/system/ssh.nix) 声明
- 全部敏感数据经 agenix 加密，仅绑定主机 SSH 密钥可解密；密钥文件可安全提交到 Git
- 防火墙默认开启，仅放行必需端口；远程访问经 Tailscale 私有组网（tailnet），无公网端口转发
- **无全局代理**：NAS 不依赖系统级 HTTP 代理（nixpkgs 走 TUNA 镜像、知识库构建走本机 Gitea，公网 Git 拉取在管理机进行），避免重启丢失的隐式代理依赖与本机 127.0.0.1 访问被代理 502 的隐患；如曾有手动 `systemctl set-environment http_proxy=...`，执行 `systemctl --no-pager unset-environment http_proxy https_proxy all_proxy` 清除

本机放行端口及暴露范围：

| 端口 | 服务 | 暴露范围 |
| --- | --- | --- |
| 22 | SSH（仅密钥） | LAN / tailnet |
| 3000 | Gitea Web | LAN / tailnet |
| 8080 | 知识库 Docs（Caddy，公开只读） | LAN / tailnet，另经 tailscale serve 提供尾网 HTTPS |
| 9090 | Cockpit（HTTPS + root 口令） | LAN / tailnet |
| 445/139 | Samba 文件共享 | LAN |
| 22000 | Syncthing 同步 | LAN |
| 8384 | Syncthing GUI | 仅本机（127.0.0.1） |

除 SSH 外，其余服务均未绑定到公网网卡，配合无公网端口映射，外部网络无法直达；Cockpit/Gitea 均为独立认证，知识库为公开只读静态站点。

### 信任边界

- **runner 为高信任主体**：`gitea-runner` 使用 host 网络（job 内 `127.0.0.1` 即宿主 Gitea），持有 `PAGES_TOKEN`（write:repository 权限 API token）、可写 `/var/www/docs` 与 `/kb-cache`（见 [gitea.nix](modules/services/gitea.nix)）。其中 `nas-host` 标签的 job 直接以 `gitea-runner` 权限在宿主执行（无容器隔离），`kb-builder`/`ubuntu-latest` 等容器标签经 Podman 隔离。因此能触发引擎构建的主体即等同于可写入站点内容与宿主 Gitea 部分仓库。
- 触发路径：push nas-docs main、6h 定时、手动 dispatch，以及被 `repos.json` 注册的内容仓库（其 Markdown 会被聚合进统一站点）。给仓库开放 Gitea 写权限或注册进知识库即视为加入该信任圈。
- **外部访问者只读**：Caddy 静态服务无任何写能力；`gitea` 服务沙箱（`ProtectSystem=strict`）下 `/var/www/docs` 只读，部署由 runner（host 直跑或 job 容器）完成。
- 知识库与 Gitea 走内网明文 HTTP，信任边界为 LAN/tailnet 本身，不应对公网暴露；如需公网访问请先置于 tailnet 或反向代理加 TLS。

### 密钥轮换

- **管理端 SSH 密钥**：更换密钥对后同步更新 [ssh.nix](modules/system/ssh.nix) 与 [secrets.nix](secrets/secrets.nix) 两处公钥，在 `secrets/` 执行 `nix run .#agenix -- -r` 重加密全部 `.age` 文件，再部署。
- **PAGES_TOKEN / Gitea API token 泄露**：在 Gitea 后台撤销并重建 token，更新 nas-docs 仓库的 Actions secret（`PAGES_TOKEN`），旧 token 立即失效。
- **换机迁移**：`.age` 文件加密时绑定机器 SSH 主机公钥，新机将自身公钥加入 `secrets.nix` 后重加密即可（见「敏感数据」节）。

## 维护

修改配置 → 提交（`git commit`）→ `./deploy.sh` 一键部署。密钥编辑见上文 agenix 一节。
