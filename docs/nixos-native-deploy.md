# 自托管服务部署到 NixOS 本机（非容器）

容器方案（见 [container-deploy.md](container-deploy.md)）适合"交付即运行"的常驻服务；
当服务/工具需要作为 **NixOS 系统的一部分**（systemd 托管、随系统回滚、复用 NAS 的 Nix 环境）
而非容器运行时，采用本方案：服务仓库做成 **flake**，NAS 端声明式引用启用。

## 1. 概念：GitHub Actions 的 Nix 对应物

| GitHub Actions | NixOS 对应 | 角色 |
| --- | --- | --- |
| artifact（构建产物） | `packages.${system}.default` | CI/本机构建的二进制，与部署解耦 |
| action（可复用步骤） | `nixosModules.default` | 可复用的服务声明单元，NAS `imports` 即启用 |
| marketplace（可复用市场） | flake input | 任意 flake 可被引用、锁定版本、分发复用 |

整体链路：

```
Gitea 仓库（flake：packages + nixosModules）
        │ git push
        ▼
NAS flake 增加 input 引用 → hosts/nas 导入模块 → ./deploy.sh 声明式部署
        （可选：CI 先 nix build 并推 binary cache，NAS 免编译拉取）
```

## 2. 服务仓库侧（用模板起步）

1. 复制 [service-flake.example.nix](service-flake.example.nix) 到服务仓库根目录，改名 `flake.nix`
2. 修改 `pname`/`version`、构建逻辑（Go/Rust/Node/Python/静态站点，模板内有替换示例）
3. 提交并推送到 Gitea（需 allow 匿名拉取，或按第 3 节用 SSH 方式引用）

本地验证构建：`nix build .#packages.x86_64-linux.default`

## 3. NAS 端引用启用

**flakes 输入**（[flake.nix](../flake.nix) 的 `inputs` 增加；Gitea 默认走 HTTP 匿名只读）：

```nix
inputs = {
  # ...现有 inputs...
  myapp.url = "git+http://127.0.0.1:3000/<owner>/<repo>?ref=main";
};
```

**把 inputs 注入模块参数**（`nixosSystem` 的 modules 中加一行）：

```nix
modules = [
  { _module.args.inputs = inputs; }   # 让 hosts/nas/default.nix 能访问 inputs
  ./hosts/nas
];
```

**主机装配**（[hosts/nas/default.nix](../hosts/nas/default.nix)）：

```nix
{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    # ...现有 imports...
    inputs.myapp.nixosModules.default
  ];
  services.myapp.enable = true;
  services.myapp.port = 8080;
}
```

随后 `./deploy.sh` 一键部署：myapp 以 systemd 服务运行、`DynamicUser` 免建用户、
端口自动放行，随 NixOS generation 原子切换与回滚。

## 4. 工具 / 定时任务类

- **命令行工具**：NAS 上直接 `nix run git+http://127.0.0.1:3000/<owner>/<repo>#default`
  （运行远端 flake 的包，一条命令，无需 clone/install）
- **定时任务**：在 `nixosModules.default` 里声明 `systemd.timers`（模板已含每日任务示例），
  随系统托管、无需常驻进程

## 5. （可选）构建解耦：CI 构建 → binary cache

若希望 NAS 完全免编译（构建交给 CI），在 NAS 用 Podman Quadlet 跑一个轻量
binary cache（如 AtCoder attic / harmonia），流程：

1. Gitea Actions：`nix build` → `nix copy --to http://cache:5000`（产物进 cache）
2. NAS 配置 `nix.settings.substituters` 加入 cache 地址与公钥
3. `./deploy.sh` 时 NAS 直接拉取二进制闭包，本机零编译

效果等同 GitHub Actions artifacts：构建产物与部署解耦，且带内容寻址校验。

## 6. 验证与回滚

```bash
systemctl status myapp             # 服务运行状态（DynamicUser 用户）
curl -sf http://<nas-ip>:<port>/   # Web 服务响应
systemctl list-timers | grep myapp # 定时任务存在
./deploy.sh rollback               # 随系统回滚到上一代
```
