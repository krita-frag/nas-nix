# NixOS NAS 声明式配置仓库 — 开发计划

## 1. 项目概述

以 **NixOS Flakes** 为技术底座，构建一套面向家庭网络的 NAS 声明式配置仓库。全部系统状态（包、服务、用户、网络、权限）以声明式代码描述并纳入 **Git** 版本控制；敏感信息（密码、API 密钥、证书）通过 **agenix** 加密存储。仓库满足"随时可重建"原则：任何一台设备可在全新环境按文档从零重建出完全一致的 NAS。

### 核心目标

| 目标 | 说明 |
| --- | --- |
| 声明式 | 一切可声明的内容均写在配置中，无手动作业残留 |
| 可复现 | `flake.lock` 锁定所有输入版本，重建结果一致 |
| 可回滚 | 基于 NixOS generation 实现原子化部署与一键回滚 |
| 安全 | SSH 密钥认证、敏感数据 agenix 加密、Tailscale 私有组网 |
| 干净 | 依赖 Nix 垃圾回收与声明式特性，系统无历史包残留 |
| 可扩展 | 模块化结构，应用服务按需增删，不动系统核心 |

---

## 2. 技术选型与架构

### 2.1 技术底座

| 组件 | 用途 |
| --- | --- |
| NixOS（unstable） | 操作系统，声明式系统管理 |
| Flakes | 项目级可复现性单元，锁定输入、统一入口 |
| Git | 版本控制与远程托管，配置原子提交 |
| agenix | 基于 age 的加密密钥/密码管理，密钥文件可入库 |
| NixOS 模块系统 | 模块化复用，按需组合功能 |

### 2.2 Flake 输入

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  agenix.url  = "github:ryantm/agenix";
};
```

`home-manager` 暂不作为必选依赖；若后续出现用户态配置需求（如自定义 shell、编辑器）再行引入，保持基线最小化。

### 2.3 架构总览

```
┌──────────────────────────────────────────────┐
│                管理端 (macOS)                 │
│  git + nix 客户端 + age 密钥                  │
│  nixos-rebuild --target-host 远程部署         │
└──────────────────────┬───────────────────────┘
                       │ SSH / Tailscale
┌──────────────────────▼───────────────────────┐
│              NixOS NAS 主机                   │
│                                              │
│  系统层（modules/system/）                    │
│   ├─ ssh.nix       密钥认证、禁密码           │
│   ├─ tailscale.nix 安全组网                   │
│   ├─ samba.nix     文件共享                   │
│   ├─ cockpit.nix   系统管理面板               │
│   ├─ docker.nix    容器运行时                 │
│   ├─ zram.nix      内存压缩交换               │
│   └─ nix-gc.nix    自动垃圾回收               │
│                                              │
│  应用容器层（modules/services/，按需扩展）     │
│   ├─ portainer.nix 容器管理面板               │
│   └─ syncthing.nix 多设备文件同步             │
│                                              │
│  密钥层（secrets/，agenix 加密入库）          │
└──────────────────────────────────────────────┘
```

---

## 3. 项目结构设计

```
nas-nix/
├── flake.nix                    # 入口：inputs 定义 + 主机配置组装
├── flake.lock                   # 输入锁定（必须提交 Git）
├── .gitignore                   # 忽略构建产物、密钥备份等
├── README.md                    # 仓库说明与快速上手
├── DEVELOPMENT_PLAN.md          # 本计划文档
├── hosts/
│   └── nas/
│       ├── default.nix          # 主机级配置：import 系统层 + 应用层模块
│       └── hardware-configuration.nix  # 硬件探测生成，纳入版本控制
├── modules/
│   ├── system/                  # 系统层模块（可跨主机复用）
│   │   ├── ssh.nix
│   │   ├── tailscale.nix
│   │   ├── samba.nix
│   │   ├── cockpit.nix
│   │   ├── docker.nix
│   │   ├── zram.nix
│   │   └── nix-gc.nix
│   └── services/                # 应用容器层模块（按需新增文件即扩展）
│       ├── portainer.nix
│       └── syncthing.nix
├── secrets/
│   ├── secrets.nix              # agenix 声明：文件路径、属主、权限
│   ├── tailscale-auth.age       # Tailscale 认证密钥
│   ├── samba-passwords.age      # Samba 用户口令
│   └── ...                      # 其余敏感文件，加密后随仓库提交
└── docs/
    └── ...                      # 部署、维护等补充文档（后续充实）
```

### 设计原则

- **主机与模块分离**：`hosts/<机器名>/` 只做装配，具体能力放 `modules/`，便于未来接入第二台主机。
- **系统层与应用层分离**：系统层模块稳定、变更少；应用层模块独立、增删不影响系统核心。
- **密钥与配置分离**：明文配置可公开，所有敏感内容以 `.age` 加密文件入库。
- **硬件配置入库**：`hardware-configuration.nix` 一并提交，保证全量可重建。

---

## 4. 模块划分

### 4.1 系统层模块（modules/system/）

| 模块 | 关键配置 | 设计理由 |
| --- | --- | --- |
| ssh.nix | `services.openssh.enable`、`passwordAuthentication = false`、`kbdInteractiveAuthentication = false`；授权公钥写入 `users.users.<name>.openssh.authorizedKeys.keys` | 仅密钥认证，杜绝弱口令爆破；公钥非敏感，明文入库 |
| tailscale.nix | `services.tailscale.enable`；认证密钥来自 agenix 解密文件（`authKeyFile`） | 实现内网组网与远程访问，无需开放公网端口；ACL 在 Tailscale 控制台管理 |
| samba.nix | `services.samba` 与 `services.samba.shares`；用户口令由激活脚本从 agenix 解密后执行 `smbpasswd` | 家庭文件共享，读写权限按目录细分；口令不经明文配置 |
| cockpit.nix | `services.cockpit.enable`、防火墙放行 9090 | Web 方式查看系统资源、日志、存储与服务状态 |
| docker.nix | `virtualisation.docker.enable`、`docker` 用户组授权 | 容器运行时底座；作为 Portainer 等应用的宿主 |
| zram.nix | `zramSwap.enable`、`zramSwap.memoryPercent`（约 50，zstd 压缩） | 内存压缩交换提升低内存场景响应，替代物理 swap |
| nix-gc.nix | `nix.gc.automatic`、`nix.gc.dates`（weekly）、`nix.gc.options --delete-older-than`、`nix.optimise.automatic` | 定期清理旧 generation 与缓存，保持系统干净 |

### 4.2 应用容器层模块（modules/services/）

| 模块 | 关键配置 | 设计理由 |
| --- | --- | --- |
| portainer.nix | `virtualisation.oci-containers.backend = "docker"`，`containers.portainer`（挂载 docker.sock、持久化数据卷） | 图形化管理 Docker 容器，降低日常运维门槛 |
| syncthing.nix | `services.syncthing.enable`、GUI 端口 8384、数据目录指定 | 多设备文件实时同步，去中心化无需云中转 |

### 4.3 扩展机制

应用层模块采用"一服务一文件"约定：新增服务只需在 `modules/services/` 添加一个 `.nix`，再在主机 `default.nix` 中 `import` 一行即可。此结构支持后续按需接入任意容器化或系统级服务（详见第 10 节扩展路径）。

---

## 5. 配置实现步骤

### 阶段 0 — 环境准备

1. NAS 安装 NixOS（iso 安装器），完成分区与基础系统安装。
2. 配置 SSH 密钥认证并确认可从 macOS 免密登录（密钥对在管理端生成，公钥注入系统）。
3. macOS 端安装 Nix 客户端（作为 Flakes 构建环境）与 `age`（agenix 加密工具）。

### 阶段 1 — Flake 骨架与基线系统

1. 初始化 Git 仓库，创建 `flake.nix` 与 `flake.lock`。
2. 定义 `nixosConfigurations.nas`，引用 `hosts/nas/hardware-configuration.nix` 与 `hosts/nas/default.nix`。
3. 提交 `hardware-configuration.nix`，验证 `nix flake check` 通过。
4. 首次远程部署：`nixos-rebuild switch --flake .#nas --target-host root@<nas>`，确认基线系统可重建。

### 阶段 2 — 系统层模块逐个落地

按依赖顺序依次实现并逐一部署验证：

1. **ssh.nix**（先行，保证远程部署安全链路）
2. **tailscale.nix**（打通远程访问通道；先以手动 `tailscale up` 验证，再接入 agenix 密钥）
3. **nix-gc.nix**（立即生效，保证系统维护机制先行）
4. **zram.nix**（内存优化）
5. **docker.nix**（容器运行时，为应用层做准备）
6. **samba.nix**（文件共享，口令走 agenix）
7. **cockpit.nix**（管理面板）

每个模块实现后执行一次部署与对应冒烟测试（见第 7 节），确保问题即时暴露、不积压。

### 阶段 3 — 应用容器层模块

1. **portainer.nix**：声明式定义容器，挂载 docker.sock，验证面板可管理容器。
2. **syncthing.nix**：启用服务，确认多设备同步与 GUI 访问。

### 阶段 4 — agenix 安全接入

1. 生成 age 身份：利用 NAS 的 SSH host key（`ssh-to-age` 转换）作为解密身份，管理端以对应公钥加密，避免额外密钥分发。
2. 编写 `secrets/secrets.nix` 声明各加密文件的路径、属主与权限。
3. 依次加密并替换 Tailscale 认证密钥、Samba 口令等敏感项，确认激活时自动解密注入。
4. 验证"重建不依赖交互"：全新主机克隆仓库后 `nixos-rebuild` 即可解密全部密钥。

### 阶段 5 — 测试与部署流水线固化

1. 固化 `nix flake check`、格式检查等门禁。
2. 将冒烟测试清单写入 `docs/`，形成部署后标准验证流程。
3. 验证回滚链路（`nixos-rebuild switch --rollback`）。
4. 编写 README：新环境从零重建步骤。

---

## 6. 安全措施

| 层级 | 措施 |
| --- | --- |
| SSH | 仅密钥认证，禁用密码与键盘交互认证；公钥明文管理，私钥仅存管理端 |
| 组网 | Tailscale 私有网络，SSH 与共享仅对组网内主机开放，不暴露公网端口 |
| 防火墙 | NixOS 默认防火墙开启，仅放行必需端口（Cockpit 9090、Syncthing 8384、Samba 内部） |
| 密钥 | 全部敏感数据（口令、API 密钥、证书）经 agenix 加密入库；解密身份绑定主机 SSH key，无额外密钥散落 |
| 容器 | Docker 仅对授权用户组开放；Portainer 绑定 docker.sock 仅限内网管理 |
| 账户 | 仅保留必要用户，root 禁密码登录；共享目录按用户细分读写权限 |
| 版本控制 | 仓库可托管公开远端，加密密钥文件随仓库提交但内容不可读 |

### 敏感数据清单（需 agenix 加密）

- Tailscale 认证密钥
- Samba 用户口令
- （按需）Cockpit / 其他服务的凭据与证书

---

## 7. 测试计划

### 7.1 构建期检查（本地，未接触生产）

| 检查项 | 命令 |
| --- | --- |
| Flake 整体校验 | `nix flake check` |
| 生成待部署系统而不应用 | `nix build .#nixosConfigurations.nas.config.system.build.toplevel` |
| 预测部署变更 | `nixos-rebuild dry-activate --flake .#nas --target-host root@nas` |
| 配置格式规范 | `nixpkgs-fmt --check`（或 `alejandra --check`） |
| 密钥可解密校验 | `agenix -d secrets/<file>.age`（在持有身份的主机上） |

### 7.2 部署后冒烟测试清单

| 能力 | 验证方式 |
| --- | --- |
| SSH | 密钥免密登录成功；密码登录被拒 |
| Tailscale | `tailscale status` 显示节点正常，跨设备可达 |
| Samba | 从客户端挂载共享、读写文件、权限校验 |
| Cockpit | 浏览器访问面板，资源/服务视图正常 |
| Docker | `docker ps` 正常，授权用户可管理 |
| Portainer | 面板可见容器列表并能操作 |
| Syncthing | 设备间文件同步成功，GUI 可访问 |
| zram | `zramctl` 显示交换设备与压缩生效 |
| 垃圾回收 | `nix-collect-garbage` 后旧 generation 被清理 |

### 7.3 可重建性测试

- 在全新主机克隆仓库，按 README 从零 `nixos-rebuild`，验证无需交互即恢复完整系统。
- 建议定期用 NixOS VM（`nixosTest`）对关键模块做一次虚拟环境集成验证，后续随测试基础设施完善逐步引入。

---

## 8. 部署流程

### 8.1 常规部署（从 macOS 远程）

```bash
# 1. 提交配置变更（原子提交，与 generation 一一对应）
git add -A && git commit -m "描述本次变更"

# 2. 远程构建并切换
nixos-rebuild switch \
  --flake .#nas \
  --target-host root@<nas-ip> \
  --use-remote-sudo

# 3. 执行冒烟测试清单（见 7.2）
```

### 8.2 原子化与回滚

- NixOS 每次 `switch` 生成新的 generation，切换本身是原子操作：失败则系统自动回退旧 generation。
- 手动回滚：`nixos-rebuild switch --flake .#nas --target-host root@nas --rollback`。
- 多代历史：`nix-env --list-generations` 查看，启动菜单（systemd-boot）亦保留历史条目可选进入。
- 配合 Git：`git revert` 配置文件后再 `switch`，配置与系统状态始终对齐。

### 8.3 依赖升级

```bash
nix flake lock --update-input nixpkgs   # 锁定新版本输入
nixos-rebuild switch --flake .#nas --target-host root@nas
```

升级后保留多代，运行稳定一周后由 `nix-gc` 按策略自动清理旧代。

---

## 9. 维护指南

| 场景 | 操作 |
| --- | --- |
| 修改系统配置 | 编辑对应模块 → 提交 Git → `nixos-rebuild switch` |
| 更新依赖 | `nix flake lock --update-input <input>` 后重新部署 |
| 编辑加密密钥 | 在管理端 `agenix -e secrets/<file>.age`，保存后提交 Git |
| 添加新密钥 | 在 `secrets/secrets.nix` 声明 → `agenix -r` 重加密并生成新文件 |
| 手动清理 | `nix-collect-garbage -d`（自动 GC 已按周执行，通常无需手动） |
| 检查状态 | Cockpit 面板、`nix-env --list-generations`、`nix flake check` |
| 更换/新增 NAS | 克隆仓库 → 新机生成 `hardware-configuration.nix` → 补入密钥公钥 → 部署 |
| 托管远端 | 推送 Git 远端；加密密钥随仓库托管无泄露风险 |

---

## 10. 扩展路径

应用层模块结构已为扩展预留路径，按优先级排列：

| 类别 | 候选服务 | 接入方式 |
| --- | --- | --- |
| 媒体服务 | Jellyfin / Plex | `modules/services/` 新文件或 Docker 容器 |
| 下载管理 | qBittorrent、Sonarr、Radarr | 容器化，`oci-containers` 声明 |
| 备份 | BorgBackup + borgmatic、restic | 系统级定时任务 + 加密密钥 |
| 监控告警 | Uptime Kuma、Grafana + Prometheus | 容器化 + 数据卷持久化 |
| 智能家居 | Home Assistant | 容器或 NixOS 服务 |
| 文件网关 | Nextcloud | 容器化，引入数据库依赖 |
| 多主机 | 第二台 NixOS 设备 | `hosts/<新机>/` + 复用 `modules/system/` |

扩展约定：新增服务不改动系统层模块；仅新增 `modules/services/<name>.nix` 并在主机装配处启用，实现"系统稳定、应用灵活"。

---

## 11. 里程碑与任务清单

### M0 环境与基线（阶段 0–1）
- [ ] NAS 安装 NixOS 并配置 SSH 密钥认证
- [ ] macOS 端安装 Nix 客户端与 `age`
- [ ] 初始化 Git 仓库与 Flake 骨架
- [ ] 基线系统首次远程部署成功

### M1 系统层完备（阶段 2）
- [ ] ssh / tailscale / nix-gc / zram / docker / samba / cockpit 七模块全部落地
- [ ] 各模块冒烟测试通过
- [ ] Tailscale 远程访问链路验证

### M2 应用层与安全（阶段 3–4）
- [ ] Portainer、Syncthing 部署验证
- [ ] agenix 全量接入，无明文敏感数据残留
- [ ] 全新环境"克隆即重建"验证通过

### M3 运维固化（阶段 5）
- [ ] 构建期检查与冒烟测试清单文档化
- [ ] 回滚链路验证
- [ ] README 与维护指南完成

### 完成定义（DoD）
- 任一全新环境按文档可无交互重建完整 NAS；
- 全部敏感数据经 agenix 加密且可解密恢复；
- 所有配置原子化提交，任意变更可回滚；
- 系统无历史包残留，垃圾回收自动运行。
