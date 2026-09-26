# 局域网专用包服务器（多语言）

把「每种语言的包管理器各自直连公网」收敛为「统一走 NAS」，换来三件事：

1. **一份客户端配置全家复用** —— 新机器不必各自配镜像源/代理；
2. **局域网缓存命中** —— 同一份依赖只从公网拉一次，其余机器跑千兆内网；
3. **出口故障时已缓存的依赖仍可安装**（回源失败会退用陈旧缓存）。

实现：`modules/services/pkg-mirror.nix`，在 `hosts/nas/default.nix` 以 `services.pkgMirror.enable = true` 启用。

## 架构

```
                        局域网客户端（pip / go / cargo / npm / zig / vcpkg）
                                          │
                                http://nas.local:8081        ← 唯一放行端口
                                          │
                        ┌─────────────────┴──────────────────┐
                        │      nginx（统一入口 + 磁盘缓存）    │
                        └──┬────────┬────────┬────────┬──────┘
             反代（协议原生）│        │        │        │ 缓存转发 / 静态托管
              ┌───────────┘        │        │        └──────────────┐
              │                    │        │                       │
      /pypi/  ▼            /go/    ▼        │  /crates/ /crates-dl/ ▼
      devpi-server:3141     athens:3700     │  index.crates.io / static.crates.io
      按需缓存 PyPI              按需缓存     │  /npm/ → registry.npmmirror.com
      + 私有索引                 GOPROXY     │  /raw/ → /srv/pkg/raw（本地产物）
                                            │  /nix/ → harmonia:5000（可选）
```

两类后端的划分依据是**协议特性**，不是偏好：

| 生态 | 后端 | 为什么 |
| --- | --- | --- |
| Python | `devpi-server`（NixOS 官方模块） | 需要索引/上传/权限语义，纯反代做不到私有包 |
| Go | `athens`（nixpkgs 有包、无模块，本仓库自建 unit） | GOPROXY 是有状态协议，需按模块生成元数据 |
| Rust | nginx 缓存转发 | 稀疏索引是「取文件 + `config.json` 指定下载模板」的纯 HTTP，反代即够 |
| npm | nginx 缓存转发 | registry 是纯 GET，元数据与 tarball 同主机 |
| Zig | `/raw/` 静态托管 | 依赖以「URL + 内容哈希」寻址，**没有**中心注册表可缓存 |
| C++ | Gitea（私有 registry）+ Samba（二进制缓存） | 见下文「C++ 为什么不是 conan_server」 |

### 两个关键设计取舍（改动时别踩回去）

**1. 只对外放行 :8081 一个端口。** devpi 绑 `127.0.0.1`，athens 虽绑 `0.0.0.0` 但端口不在防火墙白名单内，二者都只能经 nginx 反代访问 —— 攻击面收敛到一个进程。

**2. 反代一律用「静态地址 + 结尾斜杠」，不用变量/`rewrite`。** 这样 nginx 走 `unparsed_uri` 前缀替换，能原样保留 `%2f` 这类转义（npm 的 `@scope%2fname` 依赖这点）；用 `rewrite` 会让 nginx 改用归一化 URI 从而破坏转义。代价是上游域名在 nginx 启动/重载时解析一次，故模块对 nginx 加了 `Restart=on-failure` 兜底。

## 客户端配置

统一入口一律是 `http://nas.local:8081`（mDNS 提供解析，见 `hosts/nas/default.nix` 的 Avahi 配置）。

### Python（pip / uv）

```bash
pip config set global.index-url http://nas.local:8081/pypi/root/pypi/+simple/
pip config set global.trusted-host nas.local      # 明文 HTTP 需显式信任
```

uv：

```bash
export UV_INDEX_URL=http://nas.local:8081/pypi/root/pypi/+simple/
export UV_INSECURE_HOST=nas.local
```

私有包上传（需先设过 devpi root 口令）：

```bash
pip install devpi-client
devpi use http://nas.local:8081/pypi
devpi login root
devpi upload --index root/private
```

> **切国内上游（可选）**：devpi 默认回源 `pypi.org`。要换成清华 TUNA 有两条路：
> 在 NAS 上一次性执行（推荐，无需改配置）
> ```bash
> nix shell nixpkgs#devpi-client --command bash -c '
>   devpi use http://127.0.0.1:3141
>   devpi login root --password=""          # 首次为空口令，会要求设新口令
>   devpi user -m root password=<新口令>
>   devpi index root/pypi mirror_url=https://pypi.tuna.tsinghua.edu.cn/simple/'
> ```
> 或在客户端用 `pip install -i https://pypi.tuna.tsinghua.edu.cn/simple/` 临时绕开（不享受局域网缓存）。

### Go

```bash
go env -w GOPROXY=http://nas.local:8081/go,direct
```

`direct` 作为回退项保留：NAS 不可用时 go 自动退回直连，不会把你的构建卡死。
私有模块仓库用 `GOPRIVATE` / `GONOSUMDB` 排除校验，与是否走本代理无关。

### Rust（cargo）

`~/.cargo/config.toml`：

```toml
[source.crates-io]
replace-with = "nas"

[source.nas]
registry = "sparse+http://nas.local:8081/crates/"
```

必须用 **source replacement**（`replace-with`），不能只在 `[registries]` 里加一个替代 registry ——
后者无法替换 crates-io 的身份标识。

> **注意**：本服务只覆盖 **crate 依赖**。`rustup` 的工具链/组件下载走 `static.rust-lang.org`，
> 不在此列。若需连工具链一起离线，改用 `pkgs.panamax` 做全量镜像（代价是数万 GB 级磁盘）。

### npm

```bash
npm config set registry http://nas.local:8081/npm/
npm config set replace-registry-host always
```

`replace-registry-host=always` **不是可选项**：npm registry 元数据里的 `dist.tarball` 是绝对
URL，不把主机替换回本代理的话，包体仍会从公网取，缓存只能命中元数据。

pnpm / yarn 对 tarball 主机改写的支持不一致，若无对应开关，包体可能仍走公网。

### Zig

Zig 没有中心注册表，依赖是「URL + 内容哈希」，所以做法是**自托管 tarball + 让哈希不变**：

```bash
# 1. 把依赖源码包放进 NAS（Samba 共享 pkg-raw，或 scp 到 /srv/pkg/raw/）
# 2. 用 zig fetch 把 URL 指到本机，哈希由 zig 重新计算并写入
zig fetch --save=httpz http://nas.local:8081/raw/httpz-0.1.0.tar.gz
```

哈希是内容寻址的，镜像只是换了 URL，`build.zig.zon` 里的 hash 语义完全不变 ——
这也是为什么不需要（也无法）缓存 Zig「注册表」。

### C++

#### vcpkg（推荐）

两件事分别解决「包定义从哪来」和「编译产物复用」：

**1. 私有/镜像 registry —— 复用本机 Gitea**（无需新服务）

把 `microsoft/vcpkg` 镜像到 Gitea（新建仓库 → 镜像 → 上游 `https://github.com/microsoft/vcpkg`），
然后项目里放 `vcpkg-configuration.json`：

```json
{
  "default-registry": {
    "kind": "git",
    "repository": "http://nas.local:3000/<gitea-user>/vcpkg",
    "baseline": "<镜像仓库某个 commit>"
  }
}
```

**2. 共享二进制缓存 —— 复用本机 Samba**（真正的加速点：避免每台机器重编译）

vcpkg 的 `files` 后端直接指向共享目录即可，无需额外服务：

```bash
# 客户端先挂载 //nas.local/pkg-raw
export VCPKG_BINARY_SOURCES="files,<挂载点>/vcpkg-cache,readwrite"
```

#### 为什么不是 conan_server

`conan_server` 在 Conan 2 已拆成独立的 `conan-server` pip 包（`pkgs.conan` 不含该可执行文件），
且官方文档明确其定位是「本地仓库」——**没有上游代理缓存能力**，无法缓存 ConanCenter，
仅建议小团队测试使用，新部署被推荐转向 Artifactory CE。

因此本方案对 Conan 的处理是：

- **公共包**：客户端直连 ConanCenter（无法在 LAN 缓存，除非另跑 Artifactory CE 容器）；
- **私有包/离线包**：用 `conan cache save` 打包，放进 `/raw/`，他人 `conan cache restore` 取用：

```bash
conan cache save "*" --file /tmp/pkgs.tgz        # 导出
cp /tmp/pkgs.tgz <pkg-raw 挂载点>/conan/          # 投放到 NAS
# 其他机器
conan cache restore <挂载点>/conan/pkgs.tgz
```

若后续确实需要完整的 Conan 上游缓存，再单独加一个 Artifactory CE 的容器服务（约占 1.5 GB 内存）。

## 运维

### 缓存与数据位置

| 路径 | 内容 | 说明 |
| --- | --- | --- |
| `/var/cache/nginx/pkg` | cargo / npm 反向代理缓存 | 上限由 `services.pkgMirror.cacheMaxSize` 控制，LRU 淘汰 |
| `/var/lib/devpi` | devpi 索引与已缓存的 PyPI 包 | 由官方模块的 `StateDirectory` 管理 |
| `/var/lib/athens` | 已缓存的 Go 模块 | 本模块自建 unit 管理 |
| `/srv/pkg/raw` | 自管产物（Zig 包、C++ 产物、wheel） | 也可经 Samba 共享 `pkg-raw` 投放 |

### 常用操作

```bash
# 看某次请求是否命中缓存（HIT / MISS / STALE / EXPIRED）
curl -sI http://nas.local:8081/crates/se/rd/serde | grep -i x-cache-status

# 缓存占用
du -sh /var/cache/nginx/pkg

# 清空反向代理缓存（产物与 devpi/athens 缓存不受影响）
sudo systemctl stop nginx
sudo rm -rf /var/cache/nginx/pkg
sudo systemctl start nginx

# 上游域名 IP 变动后刷新解析（nginx 在启动/重载时解析一次）
sudo systemctl reload nginx

# 服务状态
systemctl status nginx devpi-server athens
```

### 换上游

改 `hosts/nas/default.nix` 的 `services.pkgMirror` 选项即可（改一处集中生效）。索引是高频请求，
国内可只把**索引**换到 rsproxy：

```nix
services.pkgMirror.rust.indexUpstream = "https://rsproxy.cn/index";
# cratesUpstream 保持 static.crates.io，理由见下
```

> **别把 `cratesUpstream` 换成 rsproxy**：它的下载端点会 307 跳到另一台 CDN 主机
> （`lf3-static.rsproxy.cn`）。nginx 不跟随上游重定向，cargo 拿到跳转后会直接去公网 CDN，
> 局域网的包体缓存就失效了 —— 只有**直出**端点才能被缓存。索引与包体可以来自不同镜像源
> （两者都镜像 crates.io，checksum 一致，cargo 会自行校验）。

## 安全模型

- **只放行 `:8081`**：devpi 绑 `127.0.0.1`；athens 绑 `0.0.0.0` 但端口不在白名单，二者均仅本机 nginx 可达。
- **上游 TLS 校验开启**（`proxy_ssl_verify` + 系统 CA），避免包体在 NAS→上游这一段被中间人替换。
- **`/raw/` HTTP 侧只读**：写入必须经 Samba（认证用户），局域网匿名用户只能读。
- **明文 HTTP**：与知识库/Gitea 同样定位——信任边界就是 LAN/tailnet 本身，不应对公网暴露。
  若需加密，设 `services.pkgMirror.tailscaleHttpsPort = 10000` 走尾网 HTTPS。
- **内容完整性由各自客户端保证**：pip 的 hash、go 的 sumdb、cargo 的 crate 校验和、
  zig 的内容哈希都会独立验证，NAS 不是信任锚点 —— 这也是局域网明文可接受的前提。

## 冒烟清单

部署后逐项确认：

```bash
# 入口与首页（应返回 200 且含「NAS 专用包服务器」）
curl -sf http://nas.local:8081/ | grep -o 'NAS 专用包服务器'

# 各反代上游就绪
curl -sf -o /dev/null -w 'pypi  %{http_code}\n' http://nas.local:8081/pypi/root/pypi/+simple/
curl -sf -o /dev/null -w 'go    %{http_code}\n' http://nas.local:8081/go/github.com/pkg/errors/@v/list
curl -sf       http://nas.local:8081/crates/config.json      # 应含 /crates-dl/ 指向本机
curl -sf -o /dev/null -w 'npm   %{http_code}\n' http://nas.local:8081/npm/left-pad

# 缓存层生效（第二次请求应为 HIT）
curl -sI http://nas.local:8081/crates/se/rd/serde | grep -i x-cache-status
curl -sI http://nas.local:8081/crates/se/rd/serde | grep -i x-cache-status

# 后端服务
systemctl is-active nginx devpi-server athens
ss -tlnp | grep -E ':(8081|3141|3700)\b'     # 3141 应为 127.0.0.1，3700 为 0.0.0.0

# 目录与共享
ls -ld /srv/pkg/raw
testparm -s 2>/dev/null | grep -A3 '\[pkg-raw\]'
```

端到端（在另一台机器上）：

```bash
pip download six -d /tmp/x                                      # 走 devpi
GOPROXY=http://nas.local:8081/go go mod download github.com/pkg/errors
cargo add serde                                                 # 走 /crates/
npm view left-pad version                                       # 走 /npm/
```

## 已知边界与排查

### 部署前已在开发机实测通过的行为

把模块生成的那套 nginx 指令抽出来，用 nginx 1.30.5 实际起服务打到真实上游验证：

| 验证项 | 结果 |
| --- | --- |
| `/crates/config.json` 本机覆盖 | 200，返回本机 `dl` 模板（未被上游的 `static.crates.io` 覆盖） |
| `/crates/se/rd/serde` 前缀剥离 + 上游路径 | 200，返回真实索引内容 |
| 二次请求缓存 | `X-Cache-Status: HIT`，缓存落盘 |
| `/crates-dl/serde/1.0.219/download` | 200，78983 字节（真实 `.crate` 包体） |
| 不存在的 crate | 404 透传并按 `proxy_cache_valid 404 5m` 缓存 |
| `/npm/left-pad` | 200，真实 registry 元数据 |
| `/raw/` 目录索引 | 200，autoindex 正常 |
| `nginx -t` | 配置语法与语义校验通过 |

### nginx 在启动时解析上游域名

反代用的是静态地址（为了保留 URI 转义，见上文取舍），因此 `index.crates.io` 这类域名是在
**nginx 启动/重载时解析一次**。若开机瞬间 DNS 不可用，nginx 会启动失败 —— 模块对此加了
`Restart=on-failure` + `RestartSec=10`，DNS 恢复后自动上线。上游 IP 变更后用
`systemctl reload nginx` 刷新。

### 上游抖动

实测 `index.crates.io`（Fastly）偶发单次请求卡到 60s，重试即恢复；这是上游/链路问题而非配置问题。
设计上已通过两条兜底消化：`proxy_cache_use_stale`（回源失败退用陈旧缓存）与长 TTL
（已缓存的内容不再回源）。对稳定性敏感可把 `rust.indexUpstream` 换成 rsproxy。

### 覆盖范围

- **rustup 工具链**不在本服务内（走 `static.rust-lang.org`）；需要连工具链一起离线请用 `pkgs.panamax`。
- **Conan 公共包**无法在 LAN 缓存（`conan_server` 无上游代理能力，见上文）。
- **npm 的 tarball** 依赖客户端 `replace-registry-host=always`，pnpm/yarn 若不支持主机改写仍会走公网。
- **devpi 默认回源 pypi.org**，切国内镜像需一次性手动配置（见「Python」一节）。

## 可选项

### Nix 二进制缓存（默认关闭）

让局域网其他机器与 Gitea runner 复用本机构的构建产物。开启前**务必先生成签名密钥**，
否则客户端必须全局 `require-sigs = false` 才肯使用该缓存，等于关掉所有 substitution 的签名校验。

```bash
# 1. 生成密钥（在 NAS 上）
nix-store --generate-binary-cache-key nas.local-1 /tmp/nix-cache-key /tmp/nix-cache-key.pub
# 2. 私钥经 agenix 加密入库（参照 README「敏感数据」一节），公钥内容记下来
```

```nix
services.pkgMirror.nixCache = {
  enable = true;
  signKeyPath = "/run/agenix/nix-cache-sign-key";
};
```

客户端：

```nix
nix.settings = {
  substituters = [ "http://nas.local:8081/nix" ];   # 追加，不要覆盖原列表
  trusted-public-keys = [ "nas.local-1:<公钥>" ];
};
```

### 尾网 HTTPS 入口

```nix
services.pkgMirror.tailscaleHttpsPort = 10000;   # Tailscale 仅支持 443/8443/10000
```

经 `modules/services/tailscale-serve.nix` 挂到 `https://<机器名>.ts.net:10000`，仅供 tailnet 内节点使用。
