# Qoder-CLI-Termux

在 Termux (Android ARM64) 上安装**官方** Qoder CLI —— 二进制零修改、不装 Ubuntu、不用 proot-distro。

> Qoder 官方其实发布了 `linux/arm64-musl` 变体，但官方一键脚本在 Termux 上会误选 **glibc** 变体，必然跑不起来。
> 本脚本从官方 manifest 手动选 musl 变体，再用 patchelf 改写解释器与 RPATH，让它跑在 Termux 上。

## 为什么官方一键脚本在 Termux 上必然失败

| 官方路线 | 结果 | 原因 |
|---|---|---|
| `curl -fsSL https://qoder.com/install \| bash` | ❌ | 脚本用 `uname -s`（Termux 返回 `Linux`）+ `uname -m`（`aarch64` → `arm64`）判定平台，选中的是 **glibc 变体**，其解释器为 `/lib/ld-linux-aarch64.so.1`，Android 上没有 glibc → `No such file or directory` |
| `npm install -g @qoder-ai/qodercli` | ❌ | 包元数据 `os: ["darwin","linux","win32"]`，而 Termux 的 node 报告 `process.platform === "android"` → `EBADPLATFORM` |

实测（`readelf` 自官方包）：

| manifest 条目 | 解释器 | NEEDED |
|---|---|---|
| `linux / arm64`（官方脚本会选它） | `/lib/ld-linux-aarch64.so.1` | `libc.so.6`、`ld-linux-aarch64.so.1`… → **glibc，跑不了** |
| `linux / arm64-musl`（本脚本选它） | `/lib/ld-musl-aarch64.so.1` | `libstdc++.so.6`、`libc.musl-aarch64.so.1` → **musl，可移植** |

注意：musl 变体是**动态链接** musl，不是静态二进制，所以还需要 musl 运行时（解释器 + C++ 库），见「工作原理」。

## 前置要求

- Termux + aarch64 (ARM64)
- **≥600MB 可用空间**（74MB 压缩包 + 171MB 二进制 ×2）
- 二选一（脚本自动检测，无需手动选择）：
  - **有 root（Magisk 已授权 Termux）**：推荐，走 dns53 转发器
  - **无 root**：自动用 dns-bootstrap 实测校验 + proot 绑定（每次调用多 100~300ms）

## 一行命令安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/Qoder-CLI-Termux/main/install.sh)
```

重跑即更新（幂等）；加 `--uninstall` 卸载。

## 脚本做了什么

| 步骤 | 说明 |
|---|---|
| 环境检查 | 仅支持 Termux + aarch64；预检磁盘空间 |
| 依赖 | `patchelf`、`tar`、`nodejs-lts`（DNS 转发器需要）、`sudo`；无 root 时补 `proot` |
| musl 运行库 | 从 Alpine 取 `musl` / `libgcc` / `libstdc++` 三个 apk，装到 `$PREFIX/lib/ld-musl-aarch64.so.1` 与 `$PREFIX/lib/musl/`。**已存在则跳过**（与 opencode-termux 共用同一套路径） |
| DNS 修复 | 见下方「DNS」 |
| 安装 Qoder CLI | 读官方 manifest → 取 `linux/arm64-musl` 的 url + sha256 → 下载校验 → 解压 → patchelf ×2 → **试跑验证通过才换入** |
| 生成 wrapper | `~/.local/bin/qodercli`：清 `LD_PRELOAD`、注入证书、处理 DNS/proot、启动前自动检查更新 |
| 生成 dispatcher | 复制官方 `~/.qoder/entry/qoder` → `~/.local/bin/qoder` |
| 验证 | `qodercli --version` |

## 使用

```bash
qoder                      # 启动交互界面（内部执行 /login 登录）
qodercli                   # 同上，官方二进制原名
qoder -p "1+1=?"           # 非交互单次提问
qoder update               # 手动更新（启动本来就会自动检查）
QODER_NO_AUTO_UPDATE=1 qoder   # 临时跳过启动前更新检查
bash ~/.check_qoder_dns.sh     # DNS 一键诊断
bash <(curl -fsSL …/install.sh) --uninstall   # 卸载
```

> **自动更新**：每次执行 `qoder` / `qodercli` 会拉一次官方 manifest（5s 连接 / 12s 总超时，失败静默跳过），
> 与本地 `~/.qoder/bin/qodercli/.version` 用 `sort -V` 比较；有新版则下载 → patchelf → 试跑 → 换入，
> **试跑失败会保留旧版**。因为要下 74MB，更新期间会明显等待，可用 `QODER_NO_AUTO_UPDATE=1` 跳过。

## 工作原理

1. 读 `https://qoder-ide.oss-accelerate.aliyuncs.com/qodercli/channels/manifest.json`，取 `latest` 与 `os=linux, arch=arm64-musl` 条目的 `url` / `sha256`（纯 bash 解析，不依赖 jq/node）。
2. 下载（74MB）→ sha256 校验 → 解压出 `qodercli`（171MB）。
3. `patchelf --set-interpreter $PREFIX/lib/ld-musl-aarch64.so.1` —— 原来的 `/lib/ld-musl-aarch64.so.1` 在 Android 上不存在。
4. `patchelf --force-rpath --set-rpath "$PREFIX/lib/musl:$PREFIX/lib"` —— musl 的 loader **一定支持 `DT_RPATH`**，而 `DT_RUNPATH` 的支持取决于 musl 版本，所以强制 RPATH。`$PREFIX/lib` 也要带上，因为 `libc.musl-aarch64.so.1` 在那里。
5. 试跑 `qodercli --version`，输出匹配版本号才 `mv` 换入（同一分区内是原子 rename，不会留下半截文件）。
6. wrapper 做三件事：
   - **`unset LD_PRELOAD`**：termux-exec 注入的 `libtermux-exec-ld-preload.so` 是 bionic 链接的，musl loader 加载它会报一堆 `Error relocating __register_atfork …` 并 `exit 127`。这是本方案最容易踩的坑。
   - `export SSL_CERT_FILE`：musl 二进制不认 Android 的 CA 路径。
   - 有 root 直跑；无 root 用 `proot -b $PREFIX/etc/resolv.conf:/etc/resolv.conf`。
7. `qoder` 是官方的 "Qoder Command Dispatcher"（不是二进制本体），它按 `type -P qodercli` → `~/.local/bin/qodercli` → `~/.qoder/bin/qodercli/qodercli` 顺序查找 CLI。该脚本由二进制首次运行时生成到 `~/.qoder/entry/qoder`，本脚本把它同步到 PATH，并在每次启动时比对（升级后官方会重写它）。

## DNS

Android 没有 `/etc/resolv.conf`，musl 解析器会回退到 `127.0.0.1:53`，而手机上默认没人监听该端口 → 每次网络请求**卡满 5 秒**才失败。

- **有 root**：转发器监听 `127.0.0.1:53`，自动探测手机当前 DNS（运营商下发）优先转发，公共 DNS 兜底，坏应答自动降级，默认屏蔽 AAAA 规避 IPv6 黑洞，全部 UDP 上游被封时回退系统 netd 解析。
- **无 root**：绑不了 53 端口，改用 `dns-bootstrap.js` 实测候选 DNS 的应答质量（SERVFAIL / 空应答 / 只回 CNAME 全部判废），只把可用的写进 `$PREFIX/etc/resolv.conf`，再由 wrapper 用 proot 绑定给 musl 读取。

**与其他项目共存**（重要）：

- 转发器文件仍叫 `dns53.js`，这样 codex-termux / opencode-termux 的 `pgrep -f "dns5[3].js"` 也能识别到它，不会重复拉起第二个实例抢 53 端口。
- 本脚本把它放在 `~/.qoder/bin/dns53.js`，**不会覆盖**其他项目装在 `~/.local/bin/dns53.js` 的版本；若那份已存在则直接复用。
- 若 `127.0.0.1:53` 已有服务在跑（`ss`/`lsof`/真实发包三重探测），整段 DNS 安装直接跳过。
- 卸载只按 `# >>> qoder-dns >>>` / `# <<< qoder-dns <<<` marker 整段删除 bashrc 块，不会误删其他项目写的行。

日志：`~/.qoder/dns53.log`；诊断：`bash ~/.check_qoder_dns.sh`。

## 常见问题

| 症状 | 原因 | 解决 |
|---|---|---|
| `Error relocating … __register_atfork: symbol not found` + `exit 127` | termux-exec 的 `LD_PRELOAD` 被 musl loader 加载 | wrapper 已 `unset LD_PRELOAD`；若你绕过 wrapper 直接跑二进制，需自行 `env -u LD_PRELOAD` |
| 每次请求恰好卡 5 秒 | DNS 链没通 | 跑 `bash ~/.check_qoder_dns.sh`；重开终端让转发器拉起 |
| `No command qoder found` | `~/.local/bin` 不在 PATH | 脚本已写入 `~/.bashrc`，重开终端或 `export PATH="$HOME/.local/bin:$PATH"` |
| `qodercli` 能用但 `qoder` 不行 | 官方 dispatcher 还没生成 | 跑一次 `qodercli --version` 后重跑本脚本同步 |
| `ide` / `chat` / `serve-web` 不可用 | Termux 上没有 Qoder IDE | 预期行为，回退 dispatcher 会明确报错 |
| 更新很慢 | 每次更新要下 74MB | 用 `QODER_NO_AUTO_UPDATE=1` 跳过自动检查，需要时再手动 `qoder update` |
| 磁盘空间不足 | 需要峰值约 420MB（包 + 解压 + patchelf 临时 + 目标） | 清理后重试 |
| 无 root 时明显变慢 | proot 每次调用多 100~300ms | 改用有 root 方案 |

已知取舍：`unset LD_PRELOAD` 后 qodercli 派生的子进程也没有 termux-exec，执行 `#!/bin/sh` 这类**绝对路径 shebang** 的脚本可能失败；用 `#!/data/data/com.termux/files/usr/bin/bash` 不受影响。

## 安装落点

| 路径 | 说明 |
|---|---|
| `~/.qoder/bin/qodercli/qodercli` | 官方 musl 二进制（171MB，已 patchelf） |
| `~/.qoder/bin/qodercli/.version` | 已安装版本号 |
| `~/.local/bin/qodercli` | 启动 wrapper |
| `~/.local/bin/qoder` | 官方 dispatcher（从 `~/.qoder/entry/qoder` 同步） |
| `~/.qoder/bin/dns53.js`、`qoder-dnsq.js`、`qoder-dns-bootstrap.js` | DNS 组件 |
| `~/.check_qoder_dns.sh` | DNS 诊断脚本 |
| `~/.qoder/dns53.log` | 转发器日志 |
| `$PREFIX/lib/ld-musl-aarch64.so.1`、`$PREFIX/lib/musl/` | musl 运行时（与其他项目共用） |

卸载**保留** `~/.qoder` 下的配置与登录态；如需彻底删除：`rm -rf ~/.qoder`。

## 与 opencode-termux / codex-termux 的关系

这三个项目解决的是同一类问题（在 Termux 上跑官方 musl CLI），共用以下约定，装任意组合都不会冲突：

- musl 运行时路径：`$PREFIX/lib/ld-musl-aarch64.so.1` + `$PREFIX/lib/musl/{libstdc++.so.6,libgcc_s.so.1}`
- DNS 转发器：都叫 `dns53.js`，靠 `pgrep` 互认，避免重复占用 53 端口
- 本脚本的 patchelf 步骤用 `--force-rpath`（其他项目用的是 `--set-rpath`），因为 musl 对 `DT_RPATH` 的支持是确定的

## 许可证

MIT
