#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# Qoder-CLI-Termux — 在 Termux (Android aarch64) 上安装官方 Qoder CLI
#
# 为什么不能用官方一键脚本:
#   官方 install.sh 用 uname -s / uname -m 判定平台 → 在 Termux 上得到 linux/arm64,
#   于是下载 glibc 变体 (解释器 /lib/ld-linux-aarch64.so.1), 而 Android 上没有 glibc
#   → 直接 "No such file or directory"。
#   npm 路线同样不通: 包的 os 字段是 [darwin,linux,win32], 而 Termux 的 node
#   报告 process.platform === 'android' → EBADPLATFORM。
#
#   官方其实也发布 linux/arm64-musl 变体 (见 manifest.json), 本脚本:
#     1. 从官方 manifest 取 latest 与 linux/arm64-musl 的 url + sha256
#     2. 下载并校验 → 解压 → patchelf 只改解释器（不设 RPATH）→ 试跑验证 → 换入
#     3. 生成 wrapper (处理 LD_PRELOAD / 证书 / DNS / 自动更新) 与 qoder dispatcher
#
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/Qoder-CLI-Termux/main/install.sh)
#   bash <(curl -fsSL …/install.sh) --uninstall
# ============================================================
set -euo pipefail

# ---------- 常量 ----------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"

QODER_DIR="$HOME_DIR/.qoder"
BIN_DIR="$QODER_DIR/bin/qodercli"
REAL_BIN="$BIN_DIR/qodercli"
VERSION_FILE="$BIN_DIR/.version"
MODE_FILE="$BIN_DIR/.mode"       # native (patchelf) / proot-bind
TMP_BASE="$QODER_DIR/tmp"
WRAPPER="$HOME_DIR/.local/bin/qodercli"
DISPATCHER="$HOME_DIR/.local/bin/qoder"
OFFICIAL_ENTRY="$QODER_DIR/entry/qoder"
# 本脚本所在目录: 有本地仓库时优先使用仓库里的 dns53/ 组件
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

# 官方发布清单与 musl 变体 (glibc 变体 arch=arm64 在 Termux 上跑不起来)
MANIFEST_URL="https://qoder-ide.oss-accelerate.aliyuncs.com/qodercli/channels/manifest.json"
RELEASE_BASE="https://qoder-ide.oss-accelerate.aliyuncs.com/qodercli/releases"
PLATFORM_OS="linux"
PLATFORM_ARCH="arm64-musl"
ASSET="qodercli-linux-arm64-musl.tar.gz"

# musl 运行时: 解释器 + 库目录 (与 opencode-termux 共用同一套路径约定, 已存在则复用)
INTERP="$PREFIX/lib/ld-musl-aarch64.so.1"
LIB_DIR="$PREFIX/lib/musl"
# 运行库搜索路径: 只用于 LD_LIBRARY_PATH, 绝不能写进 ELF 的 rpath
MUSL_LIBS="$LIB_DIR:$PREFIX/lib"
# Alpine 镜像 (动态解析版本, 不硬编码 — 见下方 Alpine 源说明)
ALPINE_MIRRORS=(
    "https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable/main/aarch64"
    "https://mirrors.aliyun.com/alpine/latest-stable/main/aarch64"
    "https://mirrors.ustc.edu.cn/alpine/latest-stable/main/aarch64"
    "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/aarch64"
)


MIN_FREE_MB=600
HARD_MIN_FREE_MB=300

# ---------- 颜色 ----------
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[1;36m'; NC='\033[0m'
ok()   { echo -e "${GRN}✓${NC} $*"; }
info() { echo -e "${BLU}▸${NC} $*"; }
warn() { echo -e "${YEL}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

# root 判定: 有 root 不等于装了 Termux 的 sudo 包 (Magisk/KernelSU 只提供 su)。
# 顺序: 本身已是 root → sudo -n → su -c 'id -u' (Magisk 首次会弹授权, 故加 timeout)。
have_root() {
    [ "$(id -u 2>/dev/null)" = 0 ] && return 0
    command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && return 0
    if command -v su >/dev/null 2>&1; then
        local u
        u="$(timeout 5 su -c 'id -u' 2>/dev/null | tr -d '\r' | head -n 1 || true)"
        [ "$u" = 0 ] && return 0
    fi
    return 1
}

# ---------- 环境检查 ----------
check_environment() {
    if [ "$(uname -o 2>/dev/null || true)" != "Android" ] && [ ! -x "$PREFIX/bin/pkg" ]; then
        fail "此脚本仅支持 Termux (Android)。普通 Linux 请直接: curl -fsSL https://qoder.com/install | bash"
    fi
    [ "$(uname -m)" = "aarch64" ] || fail "仅支持 aarch64 (ARM64) 架构, 当前: $(uname -m)"
    command -v curl >/dev/null 2>&1 || { info "安装 curl…"; pkg install -y curl; }
    mkdir -p "$QODER_DIR" "$QODER_DIR/logs" "$BIN_DIR" "$TMP_BASE" "$HOME_DIR/.local/bin"

    # 注意: Termux 的 df (toybox) 不支持 -m, 且 -P 输出的是 512-blocks, 必须用 -k
    local avail
    avail=$(df -k "$HOME_DIR" 2>/dev/null | awk 'NR==2{print int($4/1024)}' || true)
    if [ -n "$avail" ] && [ "$avail" -lt "$HARD_MIN_FREE_MB" ]; then
        fail "可用空间不足 (${avail}MB)。需要 ≥${MIN_FREE_MB}MB: 74MB 压缩包 + 171MB 二进制 ×2"
    fi
    if [ -n "$avail" ] && [ "$avail" -lt "$MIN_FREE_MB" ]; then
        warn "可用空间 ${avail}MB, 建议 ≥${MIN_FREE_MB}MB (74MB 压缩包 + 171MB 二进制 ×2)"
    fi
    info "环境检查通过 (Termux aarch64, 可用空间 ${avail:-未知}MB)"
}

# ---------- 镜像源适配 ----------
# 刚装的 Termux 默认官方源, 国内经常慢/不可达。本函数对候选源逐个探测 + 测速,
# 再按"新鲜度优先、速度兜底"选一个自动切换 (幂等; 切换后 apt update 失败会回滚)。
#
# 排序规则 —— 每一条都是实测踩出来的:
#   1) 可用性: HTTP 200 **且 Release 里能解析出 Date: 字段**
#      华为云是反例: /termux/... 路径下 Release 与 Packages 都返回 200, 内容却是
#      一个 12KB 的 HTML 页面。只校验状态码的话它会被算进候选。
#   2) 绝对陈旧: Release 日期距今超过 MIRROR_MAX_AGE 的直接判废。
#      腾讯云实测停留在 4 个月前 (2831 包 vs 官方 3009 包, python 3.13 vs 3.14)。
#   3) 新鲜度优先: Release 日期落后"最新的那个候选"超过 MIRROR_FRESH_GRACE 就不要。
#      实测 2026-10-19 —— 快慢和新鲜度并不一致:
#        官方/清华      python 3.14.8   nodejs 26.4.0-1   patchelf 0.19.2
#        中科大/阿里云  python 3.14.6-1 (其余同上)
#        腾讯云         python 3.13.13  nodejs 26.3.1    patchelf 0.19.0
#      只看速度很容易切到一个包版本偏旧的源。
#   4) 落在宽限窗口内的多个候选 → 选最快的。
MIRROR_FRESH_GRACE="${MIRROR_FRESH_GRACE:-43200}"   # 12 小时
MIRROR_MAX_AGE="${MIRROR_MAX_AGE:-2592000}"         # 30 天

# $1=Release 文件路径 → 输出 Unix 时间戳; 解析不出返回非零
release_ts() {
    local d
    d=$(awk -F': ' '/^Date: /{print $2; exit}' "$1" 2>/dev/null) || d=""
    [ -n "$d" ] || return 1
    date -d "$d" +%s 2>/dev/null || return 1
}

fix_mirror() {
    local sources_file="$PREFIX/etc/apt/sources.list"
    [ -f "$sources_file" ] || { warn "未找到 apt 源文件, 跳过镜像适配"; return; }

    # 候选: "显示名 base URL" (路径各不相同, 已逐个实测 HTTP 200)
    local candidates=(
        "官方 https://packages.termux.dev/apt/termux-main"
        "清华 https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main"
        "中科大 https://mirrors.ustc.edu.cn/termux/apt/termux-main"
        "阿里云 https://mirrors.aliyun.com/termux/termux-main"
        "北大 https://mirrors.pku.edu.cn/termux/termux-main"
        "南科大 https://mirrors.sustech.edu.cn/termux/apt/termux-main"
        "南阳理工 https://mirror.nyist.edu.cn/termux/apt/termux-main"
    )

    local work entry name url code ts age t1 t2 t i cut
    work=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/mirror.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" RETURN

    local now n=0 newest=0
    local -a NAMES=() URLS=() TIMES=() STAMPS=()
    now=$(date +%s)

    for entry in "${candidates[@]}"; do
        name="${entry%% *}"
        url="${entry##* }"
        code=$(curl -s -o "$work/rel" -w '%{http_code}' \
            --connect-timeout 5 --max-time 15 "$url/dists/stable/Release" 2>/dev/null) || code=000
        if [ "$code" != "200" ]; then
            info "跳过 $name (Release HTTP $code)"
            continue
        fi
        # 关键在于必须解析得出 Date —— 挡掉返回 HTML 却给 200 的假源
        ts=$(release_ts "$work/rel") || {
            info "跳过 $name (Release 里没有 Date 字段 —— 多半是个返回网页的假源)"
            continue
        }
        age=$(( now - ts ))
        if [ "$age" -gt "$MIRROR_MAX_AGE" ]; then
            info "跳过 $name (同步于 $(( age / 86400 )) 天前, 太陈旧)"
            continue
        fi
        t1=$(curl -s -o /dev/null -w '%{time_total}' \
            --connect-timeout 5 --max-time 15 "$url/dists/stable/Release" 2>/dev/null) || t1=999
        t2=$(curl -s -o /dev/null -w '%{time_total}' \
            --connect-timeout 5 --max-time 15 "$url/dists/stable/Release" 2>/dev/null) || t2=999
        t=$(printf '%s\n%s\n' "$t1" "$t2" | sort -n | head -1)
        info "候选 $name: ${t}s, 同步于 $(( age / 3600 )) 小时前"
        [ "$ts" -gt "$newest" ] && newest=$ts
        NAMES+=("$name"); URLS+=("$url"); TIMES+=("$t"); STAMPS+=("$ts")
        n=$(( n + 1 ))
    done

    if [ "$n" -eq 0 ]; then
        warn "所有候选源都不可用, 保持当前配置 (可手动: pkg change-repo)"
        return
    fi

    # 只保留"新鲜度落在宽限窗口内"的, 再从中选最快的
    local best_name="" best_url="" best_t=999999 best_ts=0
    cut=$(( newest - MIRROR_FRESH_GRACE ))
    i=0
    while [ "$i" -lt "$n" ]; do
        if [ "${STAMPS[$i]}" -ge "$cut" ]; then
            t="${TIMES[$i]}"
            if [ -z "$best_url" ] || awk "BEGIN{exit !($t < $best_t)}"; then
                best_name="${NAMES[$i]}"; best_url="${URLS[$i]}"; best_t="$t"; best_ts="${STAMPS[$i]}"
            fi
        fi
        i=$(( i + 1 ))
    done

    if [ -z "$best_url" ]; then
        warn "候选源的同步时间都超出宽限窗口, 保持当前配置"
        return
    fi
    ok "选定源: $best_name (${best_t}s, 同步于 $(( (now - best_ts) / 3600 )) 小时前)"

    # 当前已是选定源 → 不动
    if grep -qF "$best_url" "$sources_file" 2>/dev/null; then
        ok "当前源已是选定源, 无需切换"
        return
    fi

    local backup="$sources_file.bak.$(date +%s)"
    cp "$sources_file" "$backup"
    warn "切换源: $(grep -oE 'https://[^ ]+' "$sources_file" | head -1) → $best_name"
    {
        echo "# 由 install.sh 自动切换 (选定: $best_name ${best_t}s, Release $(( (now - best_ts) / 3600 )) 小时前)"
        echo "deb $best_url stable main"
    } > "$sources_file"

    if DEBIAN_FRONTEND=noninteractive apt update -y >/dev/null 2>&1; then
        ok "apt update 成功 ($best_name), 原配置备份: $(basename "$backup")"
    else
        warn "apt update 失败, 已自动回滚到原配置"
        cp "$backup" "$sources_file"
        DEBIAN_FRONTEND=noninteractive apt update -y >/dev/null 2>&1 || true
    fi
}

upgrade_packages() {
    info "更新软件包索引并升级全部软件包…"
    info "提示: 全新 Termux 首次升级可能耗时数分钟 (下载量大), 请耐心等待, 不要打断"
    if DEBIAN_FRONTEND=noninteractive pkg upgrade -y; then
        ok "软件包已是最新"
    else
        warn "pkg upgrade 未完全成功, 请稍后重试 (pkg upgrade -y)"
    fi
}


# ---------- 依赖 ----------
install_dependencies() {
    local need=()
    command -v patchelf >/dev/null 2>&1 || need+=(patchelf)
    command -v tar >/dev/null 2>&1 || need+=(tar)
    command -v node >/dev/null 2>&1 || need+=(nodejs-lts)
    command -v sudo >/dev/null 2>&1 || need+=(sudo)
    if [ ${#need[@]} -gt 0 ]; then
        info "安装依赖: ${need[*]}"
        pkg install -y "${need[@]}" || fail "依赖安装失败, 请先手动执行 pkg update && pkg upgrade"
    else
        ok "依赖已就绪"
    fi
    if have_root; then
        # 有 root 也要 proot: dns53 挂掉时它是 DNS 的兜底 (绑 $PREFIX/etc/resolv.conf)
        command -v proot >/dev/null 2>&1 || { info "安装 proot (dns53 不可用时的 DNS 兜底)…"; pkg install -y proot; }
    else
        command -v proot >/dev/null 2>&1 || { info "未检测到 root, 安装 proot (用于绑定 resolv.conf)…"; pkg install -y proot; }
        warn "未检测到 root: 将通过 proot 绑定 resolv.conf (每次调用多 100~300ms)"
    fi
}

# ---------- musl 运行库 (Alpine) ----------
# musl 变体是动态链接: 需要 ld-musl-aarch64.so.1 + libstdc++.so.6 + libgcc_s.so.1。
# 与 opencode-termux 共用 $PREFIX/lib/musl, 已存在则跳过 (幂等)。
# ---------- Alpine 源: 动态版本 + 多镜像回退 ----------
# 不能硬编码 apk 版本号: Alpine 的 edge 是滚动分支, 旧版本会被直接轮掉
# (musl-1.2.6-r2 在 edge 已经 404 了), 所以固定用 latest-stable 分支,
# 并从 APKINDEX.tar.gz (解压出来是纯文本索引) 取当前版本号。
ALPINE_BASE=""

apk_mirror_host() { local h="${1#https://}"; printf '%s' "${h%%/*}"; }

# $1=索引保存路径; 成功后把选中的镜像放进 ALPINE_BASE
alpine_select_mirror() {
    local m
    for m in "${ALPINE_MIRRORS[@]}"; do
        if curl -fsSL --connect-timeout 8 --max-time 30 "$m/APKINDEX.tar.gz" -o "$1"; then
            ALPINE_BASE="$m"
            ok "Alpine 镜像: $(apk_mirror_host "$m")"
            return 0
        fi
        warn "镜像不可用: $(apk_mirror_host "$m")"
    done
    fail "所有 Alpine 镜像都取不到 APKINDEX (网络问题?)"
}

# $1=索引路径 $2=包名 → 当前版本号; 解析失败则输出空串。
# 关键: 不能让 set -e 因为 pipeline 非零而"静默"退出 —— 曾出现过
# "没有任何报错、脚本直接结束" 的情况 (某些 tar 不认 apk 的扩展头会报错退出)。
alpine_version() {
    local idx="$1" pkg="$2" out=""
    # 注意: awk 打完就 exit, tar 会收到 SIGPIPE(141); 在 pipefail 下整条 pipeline 非零,
    # 若写成 `out=$(...) || out=""` 会把已经取到的值清空, 且 set -e 会让脚本"静默结束"。
    # 因此一律用 `|| true`: 保留已捕获的输出, 只吃掉非零退出码。
    out=$( { tar -xzOf "$idx" APKINDEX 2>/dev/null || true; } \
        | awk -F: -v p="$pkg" '$1=="P" && $2==p {f=1; next} f && $1=="V" {print $2; exit}') || true
    # 回退: 用 gzip 先解压再喂给 tar, 绕开 tar 对 APK-TOOLS.checksum.SHA1 扩展头的处理差异
    [ -n "$out" ] || out=$( { gzip -dc "$idx" 2>/dev/null || true; } | tar -xOf - APKINDEX 2>/dev/null \
        | awk -F: -v p="$pkg" '$1=="P" && $2==p {f=1; next} f && $1=="V" {print $2; exit}') || true
    printf '%s' "$out"
}

# $1=索引路径 $2=包名 $3=输出文件
alpine_fetch_apk() {
    local idx="$1" pkg="$2" out="$3" ver="" m
    ver="$(alpine_version "$idx" "$pkg")" || true
    if [ -z "$ver" ]; then
        warn "解析 $pkg 版本号失败, 下面是 tar 的真实输出:"
        tar -xzOf "$idx" APKINDEX >/dev/null || true
        fail "无法从 APKINDEX 解析 $pkg 的版本号"
    fi
    for m in "${ALPINE_MIRRORS[@]}"; do
        if curl -fsSL --connect-timeout 10 --max-time 120 "$m/$pkg-$ver.apk" -o "$out"; then
            info "$pkg-$ver.apk ← $(apk_mirror_host "$m")"
            return 0
        fi
        warn "$pkg-$ver.apk 下载失败: $(apk_mirror_host "$m")"
    done
    fail "$pkg.apk 下载失败 (已试 ${#ALPINE_MIRRORS[@]} 个镜像)"
}

install_musl_libs() {
    if [ -x "$INTERP" ] && [ -f "$LIB_DIR/libstdc++.so.6" ] && [ -f "$LIB_DIR/libgcc_s.so.1" ]; then
        ok "musl 运行库已就绪 (ld-musl + libstdc++ + libgcc)"
        return 0
    fi

    local work idx
    work=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/musl.XXXXXX")
    idx="$work/APKINDEX.tar.gz"
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" RETURN

    if [ ! -x "$INTERP" ]; then
        info "获取 musl 动态链接器 (Alpine musl 包)…"
        alpine_select_mirror "$idx"
        alpine_fetch_apk "$idx" musl "$work/musl.apk"
        (cd "$work" && tar xzf musl.apk) || fail "musl.apk 解压失败"
        [ -f "$work/lib/ld-musl-aarch64.so.1" ] || fail "musl.apk 内容异常"
        cp "$work/lib/ld-musl-aarch64.so.1" "$PREFIX/lib/"
        chmod 755 "$PREFIX/lib/ld-musl-aarch64.so.1"
        ok "ld-musl-aarch64.so.1 已安装"
    fi

    info "获取 C++ 运行库 (Alpine libgcc + libstdc++)…"
    mkdir -p "$LIB_DIR"
    [ -s "$idx" ] || alpine_select_mirror "$idx"
    alpine_fetch_apk "$idx" libgcc "$work/libgcc.apk"
    alpine_fetch_apk "$idx" "libstdc++" "$work/libstdcxx.apk"
    (cd "$work" && tar xzf libgcc.apk && tar xzf libstdcxx.apk) || fail "C++ 库解压失败"
    cp "$work/usr/lib/libgcc_s.so.1" "$LIB_DIR/" || fail "libgcc_s.so.1 拷贝失败"
    cp "$work/usr/lib"/libstdc++.so.6* "$LIB_DIR/" 2>/dev/null || true
    [ -f "$LIB_DIR/libstdc++.so.6" ] || fail "libstdc++.so.6 拷贝失败"
    chmod 755 "$LIB_DIR/libstdc++.so.6"* "$LIB_DIR/libgcc_s.so.1"
    ok "C++ 运行库已安装到 $LIB_DIR"
}

# ---------- manifest 解析 (纯 bash, 不依赖 jq/node) ----------
manifest_json() { curl -fsSL --connect-timeout 8 --max-time 20 "$MANIFEST_URL" 2>/dev/null || true; }

manifest_latest() {
    manifest_json | tr -d '\r\n\t ' | grep -oE '"latest":"[0-9][^"]*"' | head -1 | cut -d'"' -f4 || true
}

# 必须整串匹配 "arm64-musl": 只匹配 "arm64" 会命中 glibc 变体 (官方脚本就是这样翻车的)
manifest_entry() {
    manifest_json | tr -d '\r\n\t ' | sed 's/},{/}\n{/g' \
        | grep -F "\"os\":\"$PLATFORM_OS\"" | grep -F "\"arch\":\"$PLATFORM_ARCH\"" | head -1 || true
}

entry_field() { printf '%s' "$1" | grep -oE "\"$2\":\"[^\"]+\"" | head -1 | cut -d'"' -f4 || true; }

verify_sha256() {
    local file="$1" expect="$2" got=""
    [ -n "$expect" ] || { warn "manifest 未提供 sha256, 跳过校验"; return 0; }
    if command -v sha256sum >/dev/null 2>&1; then
        got=$(sha256sum "$file" | awk '{print $1}')
    elif command -v openssl >/dev/null 2>&1; then
        got=$(openssl dgst -sha256 "$file" | awk '{print $NF}')
    else
        warn "无 sha256 校验工具, 跳过校验"
        return 0
    fi
    [ "$got" = "$expect" ]
}

# ---------- proot 绑定运行 (patch 后仍跑不起来时的兜底) ----------
# 正常路径是"只改 interpreter + LD_LIBRARY_PATH"原生直跑。只有它在某些
# 设备/内核上仍失败时, 才保留官方二进制、由 proot 把 musl loader / 运行库
# 绑到它原本要找的标准路径 —— 这条路径完全不需要 patchelf。
proot_bind_run() {
    local bin="$1"; shift
    local opts=(-b "${INTERP}:/lib/ld-musl-aarch64.so.1")
    # 注意: MUSL_LIBS 是冒号分隔的列表 ("$LIB_DIR:$PREFIX/lib"), 不能拿它拼
    # 文件路径, 必须用单个目录 LIB_DIR
    if [ -f "${LIB_DIR}/libstdc++.so.6" ]; then
        opts+=(-b "${LIB_DIR}/libstdc++.so.6:/usr/lib/libstdc++.so.6")
    fi
    if [ -f "${LIB_DIR}/libgcc_s.so.1" ]; then
        opts+=(-b "${LIB_DIR}/libgcc_s.so.1:/usr/lib/libgcc_s.so.1")
    fi
    if [ -f "${PREFIX}/etc/resolv.conf" ]; then
        opts+=(-b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf")
    fi
    # timeout 是外部命令, 调不了函数, 所以放在函数内部
    timeout 60 proot "${opts[@]}" env -u LD_PRELOAD "$bin" "$@"
}

# ---------- patchelf 补丁 ----------
# 只改 interpreter, 绝对不要 --set-rpath:
#   rpath + musl + Android 会让这个 167MB 的 Bun 二进制一跑就 SIGSEGV
#   (实测 exit 139; patchelf 0.19.2 / glibc 0.19.1 都一样, 与版本无关)。
# 运行库改由 wrapper 用 LD_LIBRARY_PATH=$MUSL_LIBS 提供。
# 每次从原始副本重打, 避免上一次的坏产物残留。
patch_and_verify() {
    local bin="$1" orig="$2" out=""
    cp -f "$orig" "$bin" || return 1
    patchelf --set-interpreter "$INTERP" "$bin" 2>/dev/null || return 1
    # 不能写成 `cmd | grep -q`: grep 匹配到就退出, 写端被 SIGPIPE 杀掉,
    # 在 pipefail 下整条管道算失败 → 误判。先捕获再匹配
    out="$(env -u LD_PRELOAD LD_LIBRARY_PATH="$MUSL_LIBS" "$bin" --version 2>&1)" || true
    printf '%s' "$out" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'
}

# ---------- 下载 → patchelf → 试跑 → 换入 ----------
# 成功返回 0 并把新二进制安装到 $REAL_BIN; 失败返回 1 且不动现有版本
install_qoder_binary() {
    local force="$1" latest cur line url sha work new

    latest="$(manifest_latest)"
    [ -n "$latest" ] || fail "无法获取最新版本号 (网络不可达?)"
    info "官方最新版: v$latest"

    cur="$(cat "$VERSION_FILE" 2>/dev/null || true)"
    # 旧版安装可能被写入了 rpath (会导致 SIGSEGV), 必须重下重打; 只检查版本号
    # 会直接跳过, 把有问题的二进制留在原地。
    if [ "$force" != "1" ] && [ -n "$cur" ] && [ "$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | tail -n1)" = "$cur" ] \
       && [ -x "$REAL_BIN" ] && patchelf --print-interpreter "$REAL_BIN" 2>/dev/null | grep -q 'ld-musl' \
       && [ -z "$(patchelf --print-rpath "$REAL_BIN" 2>/dev/null || true)" ]; then
        ok "已是最新版 v$cur 且解释器正确, 跳过下载"
        return 0
    fi

    line="$(manifest_entry)"
    url="$(entry_field "$line" url)"
    sha="$(printf '%s' "$line" | grep -oE '"sha256":"[0-9a-fA-F]{64}"' | head -1 | cut -d'"' -f4 || true)"
    if [ -z "$url" ]; then
        warn "manifest 解析失败, 回退按版本号拼 URL (不做 sha256 校验)"
        url="$RELEASE_BASE/$latest/$ASSET"
        sha=""
    fi

    work=$(mktemp -d "$TMP_BASE/qoder.XXXXXX")
    trap "rm -rf '$work'" RETURN

    info "下载 $ASSET (约 74MB, 慢网请耐心)…"
    # 不用 -s: 保留 curl 的进度条 (大文件下载时不会让人以为卡死)
    curl -fSL --progress-bar --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 600 "$url" -o "$work/$ASSET" \
        || fail "下载失败: $url"
    if ! verify_sha256 "$work/$ASSET" "$sha"; then
        rm -f "$work/$ASSET"
        fail "sha256 校验失败, 已丢弃下载 (现有版本未受影响)"
    fi
    ok "校验通过"

    tar xzf "$work/$ASSET" -C "$work" || fail "解压失败"
    new="$work/qodercli"
    [ -f "$new" ] || new="$(find "$work" -maxdepth 3 -type f -name qodercli 2>/dev/null | head -1 || true)"
    [ -n "$new" ] && [ -f "$new" ] || fail "包内未找到 qodercli 二进制"
    chmod 755 "$new"

    local mode=native
    cp "$new" "$work/qodercli.orig"   # 留一份未打补丁的

    # 只改 interpreter; 打完必须试跑 (退出码 0 也可能是坏产物)
    info "改写 ELF: 解释器 → $INTERP (不设 RPATH)"
    if patch_and_verify "$new" "$work/qodercli.orig"; then
        ok "补丁试跑通过 (patchelf $(patchelf --version 2>/dev/null | head -1))"
    else
        warn "patchelf 后的二进制跑不起来"
        info "改用 proot 绑定运行库模式 (二进制保持官方原样, 由 proot 绑 musl loader)"
        if ! command -v proot >/dev/null 2>&1; then
            info "安装 proot…"
            pkg install -y proot || true
        fi
        command -v proot >/dev/null 2>&1 \
            || fail "该模式需要 proot, 但安装失败。请手动: pkg install proot"
        chmod 755 "$work/qodercli.orig"
        trial_out="$(proot_bind_run "$work/qodercli.orig" --version 2>&1)" || true
        if printf '%s' "$trial_out" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
            new="$work/qodercli.orig"
            mode=proot-bind
            ok "proot 绑定模式验证通过"
        else
            warn "proot 绑定模式的实际输出:"
            printf '%s\n' "$trial_out" | head -5 | sed 's/^/    /'
            fail "新二进制试跑失败 (patchelf 与 proot 绑定两种模式都不行), 保留现有版本"
        fi
    fi

    mkdir -p "$BIN_DIR"
    mv -f "$new" "$REAL_BIN"
    chmod 755 "$REAL_BIN"
    printf '%s\n' "$latest" > "$VERSION_FILE"
    printf '%s\n' "$mode" > "$MODE_FILE"
    ok "Qoder CLI v$latest 已安装: $REAL_BIN (运行模式: $mode)"
}

# ---------- dns53 独立组件 ----------
# dns53 (musl 程序的 DNS 兜底) 不再内嵌在本脚本、也不再写入任何 agent 目录,
# 而是作为独立组件安装到 ~/.local/share/dns53, 源码与安装器见仓库 dns53/。
# 其他 agent 可复用同一目录, 也可直接运行:
#   bash ~/.local/share/dns53/install.sh
DNS53_DIR="${XDG_DATA_HOME:-$HOME_DIR/.local/share}/dns53"
DNS53_RAW_BASES=(
    # gh-proxy 实时转发; jsDelivr 有约 12 小时缓存, 新提交可能暂时 404
    "https://gh-proxy.com/https://raw.githubusercontent.com/xkxxs/Qoder-CLI-Termux/main/dns53"
    "https://cdn.jsdelivr.net/gh/xkxxs/Qoder-CLI-Termux@main/dns53"
    "https://raw.githubusercontent.com/xkxxs/Qoder-CLI-Termux/main/dns53"
)
DNS53_FILES=(install.sh VERSION root.sh dns53.js dns-bootstrap.js dnsq.js check_dns.sh dns53-aaaa)

# 旧版把 DNS 组件放在 ~/.qoder/bin 与 ~/.check_qoder_dns.sh, 统一迁移到独立组件
cleanup_legacy_dns() {
    rm -f "$QODER_DIR/bin/dns53.js" "$QODER_DIR/bin/qoder-dnsq.js" \
          "$QODER_DIR/bin/qoder-dns-bootstrap.js" "$QODER_DIR/dns53.log" \
          "$HOME_DIR/.check_qoder_dns.sh"
    if [ -f "$HOME_DIR/.bashrc" ]; then
        sed -i '/# >>> qoder-dns >>>/,/# <<< qoder-dns <<</d' "$HOME_DIR/.bashrc"
    fi
}

fetch_dns53_payload() {
    local dst="$1" base f all
    mkdir -p "$dst"
    for base in "${DNS53_RAW_BASES[@]}"; do
        all=1
        for f in "${DNS53_FILES[@]}"; do
            if ! curl -fsSL --connect-timeout 10 --max-time 60 "$base/$f" -o "$dst/$f"; then
                all=0
                break
            fi
        done
        if [ "$all" = "1" ]; then
            return 0
        fi
        warn "dns53 组件下载失败, 换源: $base"
    done
    return 1
}

install_dns53() {
    local src="" tmp=""
    cleanup_legacy_dns
    if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/dns53/install.sh" ]; then
        src="$SCRIPT_DIR/dns53"
        info "dns53 组件: 使用本地仓库 dns53/"
    else
        tmp="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/dns53.XXXXXX")" || tmp=""
        if [ -n "$tmp" ] && fetch_dns53_payload "$tmp"; then
            src="$tmp"
            info "dns53 组件: 已从仓库下载"
        else
            if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
            tmp=""
            if [ -f "$DNS53_DIR/install.sh" ]; then
                src="$DNS53_DIR"
                warn "dns53 组件下载失败, 沿用已安装版本"
            else
                warn "dns53 组件获取失败, 跳过 DNS 配置 (可稍后重跑本脚本)"
                return 0
            fi
        fi
    fi
    if ! bash "$src/install.sh"; then
        warn "dns53 组件安装异常 (详见上方输出)"
    fi
    if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
}


# ---------- PATH ----------
# 默认 shell 是 zsh 时不会读 ~/.bashrc, 只写 .bashrc 等于没装进 PATH。
# 按 $SHELL / 已安装的 zsh / 已有的 .zshrc 判断, 两个 rc 文件都幂等写入。
ensure_path_rc() {
    local rc
    local -a rcs=("$HOME_DIR/.bashrc")
    if [ "$(basename "${SHELL:-bash}")" = "zsh" ] \
       || [ -f "$HOME_DIR/.zshrc" ] \
       || command -v zsh >/dev/null 2>&1; then
        rcs+=("$HOME_DIR/.zshrc")
    fi
    for rc in "${rcs[@]}"; do
        [ -e "$rc" ] || : > "$rc"
        if ! grep -q '\.local/bin' "$rc" 2>/dev/null; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
            info "~/.local/bin 已加入 PATH ($rc)"
        fi
    done
}

# ---------- 启动 wrapper ----------
write_wrapper() {
    mkdir -p "$HOME_DIR/.local/bin"
    cat > "$WRAPPER" << 'WRAPPER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# Qoder CLI wrapper for Termux (由 Qoder-CLI-Termux/install.sh 生成)
#   - 清掉 LD_PRELOAD: termux-exec 的 ld-preload 是 bionic 链接,
#     musl loader 加载它会报一堆 Error relocating 并 exit 127
#   - 注入 SSL_CERT_FILE: musl 二进制不认 Android 的 CA 路径
#   - DNS: 有 root 直跑 (靠 127.0.0.1:53 转发器);
#          无 root 用 proot 绑定 $PREFIX/etc/resolv.conf
#   - 启动前自动检查最新版 (QODER_NO_AUTO_UPDATE=1 跳过)
# ============================================================
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BIN="$HOME/.qoder/bin/qodercli/qodercli"
VERSION_FILE="$HOME/.qoder/bin/qodercli/.version"
MODE_FILE="$(dirname "$BIN")/.mode"   # native (patchelf) / proot-bind
OFFICIAL_ENTRY="$HOME/.qoder/entry/qoder"
DISPATCHER="$HOME/.local/bin/qoder"
TMP_BASE="$HOME/.qoder/tmp"
# dns53 独立组件 (与 agent 目录解耦)
DNS53_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/dns53"
DNSBOOT="$DNS53_DIR/dns-bootstrap.js"
MANIFEST_URL="https://qoder-ide.oss-accelerate.aliyuncs.com/qodercli/channels/manifest.json"
RELEASE_BASE="https://qoder-ide.oss-accelerate.aliyuncs.com/qodercli/releases"
ASSET="qodercli-linux-arm64-musl.tar.gz"
INTERP="$PREFIX/lib/ld-musl-aarch64.so.1"
MUSL_LIBS="$PREFIX/lib/musl:$PREFIX/lib"

export SSL_CERT_FILE="${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"
unset LD_PRELOAD

# root 判定: uid 0 / sudo -n / su -c 任一可用即为有 root
# (Magisk/KernelSU 只装 su, 没有 Termux 的 sudo 包)
have_root() {
    [ "$(id -u 2>/dev/null)" = 0 ] && return 0
    # root.sh 已探测过并缓存 (direct|sudo|su): 避免每次启动都 su 触发授权弹窗
    if command -v dns53_have_root >/dev/null 2>&1 && dns53_have_root; then return 0; fi
    command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && return 0
    if command -v su >/dev/null 2>&1; then
        local u
        u="$(timeout 5 su -c 'id -u' 2>/dev/null | tr -d '\r' | head -n 1 || true)"
        [ "$u" = 0 ] && return 0
    fi
    return 1
}

# dns53 组件的 root 后端 (direct/sudo/su), 见 root.sh
if [ -f "$DNS53_DIR/root.sh" ]; then
    . "$DNS53_DIR/root.sh"
    dns53_load_root_mode 0
else
    # 旧安装 (dns53 还没有 root.sh): 保留原有 sudo 行为
    dns53_alive() { sudo -n pgrep -f 'dns5[3]\.js' >/dev/null 2>&1; }
    dns53_root_exec() { sudo -n "$@"; }
fi
current_version() { cat "$VERSION_FILE" 2>/dev/null || true; }

manifest_json() { curl -fsSL --connect-timeout 5 --max-time 12 "$MANIFEST_URL" 2>/dev/null || true; }
latest_version() { manifest_json | tr -d '\r\n\t ' | grep -oE '"latest":"[0-9][^"]*"' | head -1 | cut -d'"' -f4 || true; }
# 必须匹配 "arm64-musl" 整串; 只匹配 "arm64" 会拿到跑不起来的 glibc 变体
manifest_entry() {
    manifest_json | tr -d '\r\n\t ' | sed 's/},{/}\n{/g' \
        | grep -F '"os":"linux"' | grep -F '"arch":"arm64-musl"' | head -1 || true
}
entry_field() { printf '%s' "$1" | grep -oE "\"$2\":\"[^\"]+\"" | head -1 | cut -d'"' -f4 || true; }
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }

verify_sha256() {
    local file="$1" expect="$2" got=""
    [ -n "$expect" ] || return 0
    if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$file" | awk '{print $1}')
    elif command -v openssl >/dev/null 2>&1; then got=$(openssl dgst -sha256 "$file" | awk '{print $NF}')
    else return 0; fi
    [ "$got" = "$expect" ]
}

# 下载 → patchelf → 试跑 → 换入 (失败保留旧版)
do_update() {
    local force=0
    [ "${1:-}" = "--force" ] && force=1
    local latest cur line url sha work new
    latest="$(latest_version)"
    [ -n "$latest" ] || { echo "!! 无法获取最新版本号 (网络不可达?)" >&2; return 1; }
    cur="$(current_version)"
    if [ "$force" != "1" ] && [ -n "$cur" ] && version_ge "$cur" "$latest"; then
        echo "已是最新版 v$cur"
        return 0
    fi
    echo "→ 更新 v${cur:-未知} → v$latest (下载 74MB, 请耐心)…"

    line="$(manifest_entry)"
    url="$(entry_field "$line" url)"
    sha="$(printf '%s' "$line" | grep -oE '"sha256":"[0-9a-fA-F]{64}"' | head -1 | cut -d'"' -f4 || true)"
    [ -n "$url" ] || url="$RELEASE_BASE/$latest/$ASSET"

    mkdir -p "$TMP_BASE"
    work=$(mktemp -d "$TMP_BASE/qoder.XXXXXX")
    trap "rm -rf '$work'" RETURN

    if ! curl -fSL --progress-bar --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 600 "$url" -o "$work/$ASSET"; then
        echo "!! 下载失败" >&2; return 1
    fi
    if ! verify_sha256 "$work/$ASSET" "$sha"; then
        echo "!! sha256 校验失败, 放弃更新 (旧版保留)" >&2; return 1
    fi
    tar xzf "$work/$ASSET" -C "$work" || { echo "!! 解压失败" >&2; return 1; }
    new="$work/qodercli"
    [ -f "$new" ] || new="$(find "$work" -maxdepth 3 -type f -name qodercli 2>/dev/null | head -1 || true)"
    [ -n "$new" ] && [ -f "$new" ] || { echo "!! 包内未找到 qodercli" >&2; return 1; }
    chmod 755 "$new"
    patchelf --set-interpreter "$INTERP" "$new" || { echo "!! patchelf 失败" >&2; return 1; }
    # 不设 rpath: rpath + musl 在 Android 会 SIGSEGV, 运行库走 LD_LIBRARY_PATH
    if ! timeout 30 env -u LD_PRELOAD LD_LIBRARY_PATH="$MUSL_LIBS" "$new" --version 2>&1 | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
        echo "!! 新版本试跑失败, 旧版保留" >&2; return 1
    fi
    mkdir -p "$(dirname "$BIN")"
    mv -f "$new" "$BIN"
    chmod 755 "$BIN"
    printf '%s\n' "$latest" > "$VERSION_FILE"
    echo "✓ 已更新到 v$latest"
}

# 官方 dispatcher 由二进制运行时生成, 升级后会被重写 → 每次启动比对同步
sync_dispatcher() {
    [ -f "$OFFICIAL_ENTRY" ] || return 0
    if ! cmp -s "$OFFICIAL_ENTRY" "$DISPATCHER"; then
        mkdir -p "$(dirname "$DISPATCHER")"
        cp -f "$OFFICIAL_ENTRY" "$DISPATCHER"
        chmod 755 "$DISPATCHER"
    fi
}

case "${1:-}" in
    --version|-v)
        # proot-bind 模式下二进制未打补丁, 必须经 proot 绑定才能跑
        # (否则报 "No such file or directory", 其实是 interpreter 不在标准路径)
        if [ "$(cat "$MODE_FILE" 2>/dev/null || echo native)" = "proot-bind" ] \
           && command -v proot >/dev/null 2>&1; then
            exec proot -b "${INTERP}:/lib/ld-musl-aarch64.so.1" \
                -b "${PREFIX}/lib/musl/libstdc++.so.6:/usr/lib/libstdc++.so.6" \
                -b "${PREFIX}/lib/musl/libgcc_s.so.1:/usr/lib/libgcc_s.so.1" \
                env -u LD_PRELOAD LD_LIBRARY_PATH="$MUSL_LIBS" "$BIN" --version
        fi
        exec env -u LD_PRELOAD LD_LIBRARY_PATH="$MUSL_LIBS" "$BIN" --version
        ;;
    update|upgrade|-u|--update)
        shift || true
        do_update "$@"
        ;;
    uninstall|--uninstall)
        rm -f "$DISPATCHER"
        rm -f "$BIN" "$VERSION_FILE"
        if [ -f "$HOME/.bashrc" ]; then
            sed -i '/# >>> qoder-dns >>>/,/# <<< qoder-dns <<</d' "$HOME/.bashrc"
        fi
        rm -f "$WRAPPER"
        echo "✓ 已卸载 Qoder CLI (保留 ~/.qoder 配置与登录态)"
        ;;
    *)
        if [ "${QODER_NO_AUTO_UPDATE:-0}" != "1" ] && command -v curl >/dev/null 2>&1; then
            LATEST="$(latest_version)"
            CUR="$(current_version)"
            if [ -n "$LATEST" ] && { [ -z "$CUR" ] || ! version_ge "$CUR" "$LATEST"; }; then
                echo "→ 检测到新版本 v${LATEST} (当前 ${CUR:-未知}), 自动更新…"
                do_update || echo "!! 自动更新失败, 继续使用现有版本启动" >&2
            fi
        fi
        sync_dispatcher
        # proot-bind 模式: 二进制未打补丁, 靠 proot 把 musl loader 绑到标准路径
        if [ "$(cat "$MODE_FILE" 2>/dev/null || echo native)" = "proot-bind" ] \
           && command -v proot >/dev/null 2>&1; then
            BINDS=(-b "${INTERP}:/lib/ld-musl-aarch64.so.1")
            [ -f "${PREFIX}/lib/musl/libstdc++.so.6" ] \
                && BINDS+=(-b "${PREFIX}/lib/musl/libstdc++.so.6:/usr/lib/libstdc++.so.6")
            [ -f "${PREFIX}/lib/musl/libgcc_s.so.1" ] \
                && BINDS+=(-b "${PREFIX}/lib/musl/libgcc_s.so.1:/usr/lib/libgcc_s.so.1")
            [ -f "$PREFIX/etc/resolv.conf" ] \
                && BINDS+=(-b "$PREFIX/etc/resolv.conf:/etc/resolv.conf")
            exec proot "${BINDS[@]}" env -u LD_PRELOAD LD_LIBRARY_PATH="$MUSL_LIBS" "$BIN" "$@"
        fi
        # exec 不能调函数, 三个分支内联
        # root 分支: dns53 常驻在 127.0.0.1:53。用心跳判断它是否真的在跑 ——
        # 只看 root 存在会误判: 有 root 但 dns53 挂了时原生直跑 = DNS 全挂。
        if have_root; then
            if ! dns53_alive && [ -f "$DNS53_DIR/dns53.js" ]; then
                mkdir -p "$DNS53_DIR/logs"
                dns53_root_exec nohup node "$DNS53_DIR/dns53.js" >> "$DNS53_DIR/logs/dns53.log" 2>&1 &
                sleep 1
            fi
            if dns53_alive; then
                exec env -u LD_PRELOAD LD_LIBRARY_PATH="$MUSL_LIBS" "$BIN" "$@"
            fi
            # dns53 仍未起来: 127.0.0.1:53 无人监听, 改用 proot 绑 resolv.conf
            if command -v proot >/dev/null 2>&1; then
                if [ -f "$DNS53_DIR/dns-bootstrap.js" ]; then
                    node "$DNS53_DIR/dns-bootstrap.js" >/dev/null 2>&1 || true
                fi
                if [ -f "$PREFIX/etc/resolv.conf" ]; then
                    exec proot -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" env -u LD_PRELOAD LD_LIBRARY_PATH="$MUSL_LIBS" "$BIN" "$@"
                fi
                # 极少数情况: bootstrap 没能写出 resolv.conf —— 仍走 proot, 不原生直跑
                exec proot env -u LD_PRELOAD LD_LIBRARY_PATH="$MUSL_LIBS" "$BIN" "$@"
            fi
            # proot 不可用: 原生直跑是唯一选择
            exec env -u LD_PRELOAD LD_LIBRARY_PATH="$MUSL_LIBS" "$BIN" "$@"
        elif command -v proot >/dev/null 2>&1; then
            if [ ! -f "$PREFIX/etc/resolv.conf" ] && [ -f "$DNSBOOT" ]; then
                node "$DNSBOOT" >/dev/null 2>&1 || true
            fi
            if [ -f "$PREFIX/etc/resolv.conf" ]; then
                exec proot -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" env -u LD_PRELOAD LD_LIBRARY_PATH="$MUSL_LIBS" "$BIN" "$@"
            fi
            exec env -u LD_PRELOAD LD_LIBRARY_PATH="$MUSL_LIBS" "$BIN" "$@"
        else
            exec env -u LD_PRELOAD LD_LIBRARY_PATH="$MUSL_LIBS" "$BIN" "$@"
        fi
        ;;
esac
WRAPPER_EOF
    chmod 755 "$WRAPPER"

    ensure_path_rc
    ok "启动 wrapper 已生成: $WRAPPER"
}

# ---------- qoder dispatcher ----------
# 官方二进制名是 qodercli; `qoder` 是官方 dispatcher (二进制首次运行时生成
# 到 ~/.qoder/entry/qoder), 负责把 qoder ... 路由到 CLI 或 IDE。
# 缺失时 (首次安装还没跑过) 写一个最小回退版。
sync_dispatcher() {
    if [ -f "$OFFICIAL_ENTRY" ]; then
        cp -f "$OFFICIAL_ENTRY" "$DISPATCHER"
        chmod 755 "$DISPATCHER"
        ok "qoder dispatcher 已同步: $DISPATCHER"
        return 0
    fi
    cat > "$DISPATCHER" << 'DISP_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# qoder — 最小 dispatcher (官方 ~/.qoder/entry/qoder 缺失时的回退)
# Termux 上没有 Qoder IDE, 因此除 IDE 子命令外一律转给 qodercli
set -euo pipefail
case "${1:-}" in
    ide|chat|serve-web|tunnel)
        echo "Termux 上不可用 Qoder IDE 子命令: $1" >&2
        exit 127
        ;;
esac
exec "$HOME/.local/bin/qodercli" "$@"
DISP_EOF
    chmod 755 "$DISPATCHER"
    warn "官方 dispatcher 尚未生成, 已写入最小回退版 (下次启动 wrapper 会自动替换)"
}

# ---------- 验证 ----------
verify() {
    local out mode=""
    mode="$(cat "$MODE_FILE" 2>/dev/null || echo native)"
    if [ "$mode" = "proot-bind" ] && command -v proot >/dev/null 2>&1; then
        # 未打补丁的二进制不能原生跑, 必须经 proot 绑定
        out=$(proot_bind_run "$REAL_BIN" --version 2>&1 || true)
    else
        out=$(timeout 60 env -u LD_PRELOAD LD_LIBRARY_PATH="$MUSL_LIBS" "$REAL_BIN" --version 2>&1 || true)
    fi
    if printf '%s' "$out" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
        ok "安装成功: qodercli $(printf '%s' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    else
        printf '%s\n' "$out" | head -20 >&2
        fail "验证失败: $REAL_BIN 无法运行"
    fi
}

# ---------- 卸载 ----------
uninstall() {
    warn "将卸载 Qoder CLI (保留 ~/.qoder 配置与登录态)…"
    rm -f "$WRAPPER" "$DISPATCHER"
    rm -rf "$BIN_DIR"
    cleanup_legacy_dns
    ok "已卸载。如需删除配置与登录态: rm -rf ~/.qoder"
    warn "dns53 独立组件已保留 — codex/opencode 等其他 musl 程序可能依赖它"
    warn "如需一并移除: bash ~/.local/share/dns53/install.sh --uninstall"
    exit 0
}

# ---------- 配置指引 ----------
show_guide() {
    echo
    echo "=============================================================="
    echo "  安装完成! 下一步: 登录"
    echo "=============================================================="
    echo
    echo "  qoder            # 启动 (交互界面内执行 /login 登录)"
    echo "  qodercli         # 同上, 官方二进制原名"
    echo "  qoder -p \"...\"   # 非交互单次提问"
    echo
    echo "  其他:"
    echo "    qoder update             手动更新 (启动时会自动检查更新)"
    echo "    QODER_NO_AUTO_UPDATE=1 qoder   临时跳过自动更新检查"
    echo "    bash ~/.local/share/dns53/check_dns.sh    DNS 一键诊断"
    echo "    重跑本脚本 --uninstall        卸载"
    echo
    echo "  注意: 本脚本只负责安装, 模型/账号配置请参考官方文档:"
    echo "    https://docs.qoder.com"
    echo "=============================================================="
    echo
}

# ---------- 主流程 ----------
case "${1:-}" in
    --uninstall) uninstall ;;
esac

info "Qoder-CLI-Termux 安装脚本 — 仅支持 Termux aarch64"
check_environment
fix_mirror
upgrade_packages
install_dependencies
install_musl_libs
install_dns53
install_qoder_binary 0
write_wrapper
verify
sync_dispatcher
show_guide
