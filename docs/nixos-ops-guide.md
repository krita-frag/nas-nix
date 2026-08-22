# NixOS 运维问题排查指南

定位导向：只收录实际操作中**遇到并解决**的问题，按领域分组，每条给出 现象 → 原因 →
解决 → 验证。

## 问题索引

| 领域 | 症状 | 定位 |
| --- | --- | --- |
| 环境 | macOS `nix: command not found` | A1 |
| 环境 | 推送 GitHub 超时/失败 | A2 |
| 环境 | nixpkgs/二进制缓存拉取慢或失败 | A3 |
| 配置 | `nix eval` 报属性不存在 | B1 |
| 配置 | flake：新文件 not tracked by Git | B2 |
| 配置 | Nix 字符串内 `$var` 被当插值 | B3 |
| 配置 | 改口令后下次重建被还原 | B4 |
| 配置 | 某模块缺 `environment` 选项 | B5 |
| 密钥 | 缺 `.age` 文件导致部署失败 | C1 |
| 密钥 | 换机后 `.age` 解不开 | C2 |
| 密钥 | 明文误入配置 | C3 |
| 密钥 | 独立口令库无法声明式管理 | C4 |
| 容器 | 本机 127.0.0.1 被代理 502 | D1 |
| 容器 | 容器内访问不到宿主服务 | D2 |
| 容器 | 容器挂载不生效 | D3 |
| CI | act_runner 首次启动报未注册 | D4 |
| CI | 依赖 post-receive 钩子的部署不生效 | D5 |
| CI | job 每次重复安装依赖 | D6 |
| 网络 | `tailscale serve --bg` 挂起卡服务 | E1 |
| 网络 | Cockpit 面板 WebSocket 被拒 | E2 |
| 数据 | restic 无法注入 rclone 凭据 | F1 |
| 数据 | Caddy 站点根写入方无权限 | F2 |

## A. 环境与部署

### A1 macOS `nix: command not found`
**原因**：Determinate Nix 二进制在 `/nix/var/nix/profiles/default/bin`，默认不在 PATH。
**解决**：

```bash
export PATH="/nix/var/nix/profiles/default/bin:$PATH"
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
```

**验证**：`nix --version` 可用。

### A2 推送 GitHub 超时/失败
**原因**：公网 GitHub 直连受限。
**解决**：走本地代理：

```bash
git -c http.proxy=http://127.0.0.1:7897 push origin main
```

**验证**：推送成功。

### A3 nixpkgs/二进制缓存拉取慢或失败
**原因**：默认源（GitHub、cache.nixos.org）访问受限。
**解决**：nixpkgs 输入走 TUNA 镜像；二进制缓存换源：

```nix
# flake.nix
nixpkgs.url = "git+https://mirrors.tuna.tsinghua.edu.cn/git/nixpkgs.git?ref=nixos-26.05&shallow=1";
# 主机配置
nix.settings.substituters = [ "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store" ];
```

**验证**：构建命中 TUNA 缓存，速度明显提升。

## B. 配置与模块

### B1 `nix eval`/部署报属性不存在
**原因**：`.#<主机名>` 配置名不能直接求值，需完整属性路径。
**解决**：部署前用此做本地快检（比远程构建更快暴露语法/模块错误）：

```bash
nix eval --raw '.#nixosConfigurations.<主机名>.config.networking.hostName'
```

**验证**：输出主机名。

### B2 flake：`Path ... is not tracked by Git`
**原因**：新建模块/文件未加入版本控制，flake 复制 git 树时缺失。
**解决**：先 `git add` 新文件再构建。
**验证**：`nix eval`/部署通过。

### B3 Nix 字符串内 `$var` 被当插值
**原因**：`''...''` 缩进字符串中 `${...}`/`$` 被 Nix 求值。
**解决**：bash 变量写 `''${var}`：

```nix
script = ''
  usage=$(df -P / | awk 'NR==2{print $5}' | tr -d '%')
  echo "使用率 ''${usage}%"
'';
```

**验证**：脚本运行时变量正常展开。

### B4 改口令后下次重建被还原
**原因**：`users.mutableUsers = false`（声明式口令管理），运行时 `passwd` 改动不持久。
**解决**：口令一律由配置声明——root 用 agenix `hashedPasswordFile`；独立口令库见 C4。
**验证**：重建后口令保持。

### B5 某模块缺 `environment` 选项（如 nixpkgs restic）
**原因**：模块未提供该选项，无法直接注入环境变量。
**解决**：扩展其生成的 systemd 单元：

```nix
systemd.services."<服务名>".serviceConfig.Environment = "KEY=VALUE";
```

**验证**：`systemctl show <服务名> -p Environment` 可见。

## C. 敏感数据（agenix）

### C1 缺 `.age` 文件导致部署失败
**原因**：`age.secrets` 引用了不存在的 `.age` 文件。
**解决**：未生成/未启用时用 `lib.mkIf` 条件声明，别硬引用（如 rclone 凭据仅在配置
`rcloneConf` 后才声明密钥）。
**验证**：`nix eval` 通过。

### C2 换机后 `.age` 解不开
**原因**：`.age` 加密绑定机器 SSH 主机公钥（`secrets.nix` 接收者）。
**解决**：新机公钥加入 `secrets.nix` 接收者后重加密全部：

```bash
nix run .#agenix -- -r    # 在 secrets/ 目录执行
```

**验证**：部署机可自解密（`/etc/ssh/ssh_host_ed25519_key`）。

### C3 明文误入配置
**原因**：`builtins.readFile` 把明文拷进 Nix store，随 `/nix` 可被读取。
**解决**：一律用 agenix 解密挂载 `/run/agenix/<name>`，配置只引用其路径。
**验证**：`grep -r <明文> /nix/store` 无结果。

### C4 独立口令库无法声明式管理
**原因**：Samba 等服务的口令是独立口令库（smbpasswd），无声明式选项。
**解决**：oneshot 服务在激活阶段从 agenix 解密文件注入：

```nix
systemd.services.set-passwords = {
  after = [ "samba-smbd.service" ];
  serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
  script = ''
    pass=$(cat ${config.age.secrets.samba.password.path})
    printf '%s\n%s\n' "$pass" "$pass" | smbpasswd -a -s <用户>
  '';
};
```

**验证**：`pdbedit -L` 可见用户，口令可登录。

## D. 容器与 CI（Podman / act_runner）

### D1 本机 127.0.0.1 服务被代理 502
**原因**：系统级 `http_proxy` 指向外部代理，访问本机 `127.0.0.1` 也被代理转发而失败。
**解决**：相关服务/容器声明 `no_proxy=127.0.0.1,localhost`（大小写各一份）。
**验证**：job 内 `git clone http://127.0.0.1:3000/...` 成功。

### D2 容器内访问不到宿主服务
**原因**：act_runner 默认给每个 job 建隔离桥接网络，容器内 `127.0.0.1` 是容器自身。
**解决**：`container.network: "host"`，容器与宿主共享网络命名空间。
**验证**：job 内 `curl 127.0.0.1:<端口>` 可达。

### D3 容器挂载不生效
**原因**：act 仅挂载 `valid_volumes` 白名单内的宿主路径，未列入的**静默忽略**。
**解决**：挂载路径同时加入 `valid_volumes`。
**验证**：job 内 `ls` 挂载目录有内容。

### D4 act_runner 首次启动报未注册
**原因**：`preStart` 检测 `.runner` 不存在且无注册令牌时退出。
**解决**：Gitea 后台生成注册令牌 → 写入 `/var/lib/gitea-runner/registration-token` →
`systemctl restart gitea-runner`，此后自动注册并持久。
**验证**：`systemctl is-active gitea-runner`，Gitea 后台显示在线 runner。

### D5 依赖 post-receive 钩子的部署不生效
**原因**：Gitea **HTTP 推送不执行 post-receive 钩子**。
**解决**：部署改由 runner 挂载目标目录直接写入（如构建产物写站点根），不依赖钩子。
**验证**：push 后站点/产物更新。

### D6 job 每次重复安装依赖
**原因**：每次运行 `apt-get`/`pip` 重复下载。
**解决**：本地预烘焙镜像 + `force_pull: false` 命中本地镜像免联网；host job 把 runner
`path` 指向 `config.system.path` 复用系统工具链。
**验证**：job 秒级开始，无安装输出。

## E. 网络与服务入口

### E1 `tailscale serve --bg` 挂起卡服务
**原因**：Serve 未在管理台启用时命令**挂起而非报错**，导致 systemd 服务卡住。
**解决**：timeout 兜底 + 静默成功 + 低频 timer 重跑：

```bash
timeout 5 tailscale serve --bg --https=<端口> http://127.0.0.1:<端口> || true
```

管理台启用后 timer 自动重跑生效，无需重启。
**验证**：`tailscale serve status` 显示配置。

### E2 Cockpit 面板 WebSocket 被拒
**原因**：模块默认仅放行 `https://localhost:9090` 来源。
**解决**：用 fnmatch 通配主机部分，与具体 IP/网段解耦：

```nix
services.cockpit.allowed-origins = [ "https://*:${toString config.services.cockpit.port}" ];
```

**验证**：局域网/tailnet 打开面板正常。

## F. 数据与站点

### F1 restic 无法注入 rclone 凭据
**原因**：nixpkgs restic 模块无 `environment` 选项。
**解决**：扩展其生成的 systemd 单元（见 B5）：

```nix
systemd.services."restic-backups-<名>".serviceConfig.Environment =
  "RCLONE_CONFIG=/run/agenix/rclone-conf";
```

**验证**：备份日志无凭据错误，异地仓库可写。

### F2 Caddy 站点根写入方无权限
**原因**：站点根属主与写入方（构建用户/容器）不一致，且容器旧内容无法被递归覆盖。
**解决**：tmpfiles 建目录 + 递归修属主（`Z` 不含 mode，避免 html/css 被置为可执行）：

```nix
systemd.tmpfiles.rules = [
  "d /var/www/site 0755 <写入用户> <写入组> - -"
  "Z /var/www/site - <写入用户> <写入组> - -"
];
```

**验证**：构建后站点可正常更新。

## G. 排查命令速查（实战用到的）

### 部署 / 回滚

```bash
nixos-rebuild switch --flake .#<主机名> --build-host root@<IP> --target-host root@<IP>   # 远程部署
nixos-rebuild dry-activate ...                 # 预演（构建不切换）
nixos-rebuild switch ... --rollback            # 回滚上一代
nix-env --list-generations --profile /nix/var/nix/profiles/system   # 查看代际
readlink /nix/var/nix/profiles/system          # 当前代指向
nix eval --raw '.#nixosConfigurations.<主机名>.config.networking.hostName'   # 部署前本地快检
bash -n <脚本>.sh                              # bash 语法快检（部署脚本/构建脚本）
ssh -o BatchMode=yes -o ConnectTimeout=8 root@<IP> 'true'   # SSH 密钥连通性（无交互）
```

### systemd / 服务

```bash
systemctl is-active <svc1> <svc2>              # 批量服务状态
systemctl status <svc>                         # 详细状态 + 最近日志
systemctl cat <svc>                            # 查看生成的单元（脚本/ExecStart/环境）
systemctl show <svc> -p Environment            # 单元注入的环境变量（验 B5/F1）
systemctl list-unit-files | grep <关键字>       # 单元是否存在（如 restic 备份单元）
systemctl list-timers | grep <关键字>           # 定时器下次触发与补跑状态
journalctl -u <svc> -n 50 --no-pager           # 服务日志
journalctl -t <tag> -n 50                      # 监控/自定义 tag 日志（告警）
```

### 网络 / 端口 / 代理

```bash
ss -tln | grep -E ':(3000|8080|9090|445|8384)\b'   # 端口监听确认
curl -sf http://127.0.0.1:<端口>/              # 本机 HTTP 探活
env | grep -i proxy                            # 排查代理 502（D1）：查看代理环境变量
systemctl --no-pager unset-environment http_proxy https_proxy all_proxy   # 清除误设的系统级代理
tailscale serve status                         # serve 配置（验 E1）
```

### 容器 / CI

```bash
podman ps && podman images | grep <镜像>        # 容器与本地镜像（验 D6 预烘焙镜像）
ls /run/docker.sock                            # Docker 兼容 socket 是否存在
ls /etc/containers/registries.conf.d/          # registry 配置（镜像加速/本地仓库）
systemctl is-active gitea-runner               # runner 状态
ls /var/lib/gitea-runner/.runner               # runner 是否已注册（验 D4）
```

### 密钥 / 数据 / 清理

```bash
ls /run/agenix/                                # agenix 密钥是否挂载（验 C 系）
nix run .#agenix -- -d <name>.age              # 解密查看明文（secrets/ 目录）
df -h /                                        # 磁盘水位
restic -r <仓库> snapshots && restic -r <仓库> check   # 备份验证
restic -r <仓库> mount /mnt/restore            # 挂载浏览历史版本
restic -r <仓库> restore latest --target /tmp/restore --include <路径>   # 恢复
nix-collect-garbage -d                         # 手动清理旧代与缓存
```

### 知识库站点

```bash
curl -sf http://<IP>:8080/ | grep <关键词>       # 站点主页可访问（Caddy）
git ls-remote http://<IP>:3000/<用户>/<仓库>.git refs/heads/pages   # 构建完成信号分支
```
