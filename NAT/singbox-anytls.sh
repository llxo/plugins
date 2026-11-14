#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# 配置、元数据、私钥和临时文件默认仅 root 可读写。
umask 077

# ============================================================
# singbox-anytls.sh — 纯 AnyTLS 一键部署脚本
# 协议: AnyTLS (TLS 自签证书)
# 核心: sing-box (始终最新稳定版)
# 用法: 交互菜单 或 ./singbox-anytls.sh -auto [port] [sni] [password]
# ============================================================

export SCRIPT_VERSION="1"
export DEFAULT_SNI="www.amd.com"

SELF_SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SELF_SCRIPT_PATH")"

# --- 路径定义 ---
export SINGBOX_DIR="/usr/local/etc/sing-box"
export SINGBOX_BIN="/usr/local/bin/sing-box"
export CONFIG_FILE="${SINGBOX_DIR}/config.json"
export METADATA_FILE="${SINGBOX_DIR}/metadata.json"
export LOG_FILE="/var/log/sing-box.log"
export RUNTIME_DIR="/run/singbox-anytls"
export PID_FILE="${RUNTIME_DIR}/sing-box.pid"

# ============================================================
# 核心工具函数
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 打印消息函数
_info()    { echo -e "${CYAN}[信息] $1${NC}" >&2; }
_success() { echo -e "${GREEN}[成功] $1${NC}" >&2; }
_warn()    { echo -e "${YELLOW}[注意] $1${NC}" >&2; }
_error()   { echo -e "${RED}[错误] $1${NC}" >&2; }

# 检查 root 权限
_check_root() {
    if [[ $EUID -ne 0 ]]; then
        _error "此脚本必须以 root 权限运行。"
        exit 1
    fi
}

# URL 编解码
_url_decode() {
    local data="${1//+/ }"
    printf '%b' "${data//%/\\x}"
}
_url_encode() {
    printf '%s' "$1" | jq -sRr @uri
}

# 随机高位端口生成 (10000 - 65535)
_get_random_port() {
    local rand_val
    if command -v od &>/dev/null && [ -c /dev/urandom ]; then
        rand_val=$(od -An -tu2 -N2 /dev/urandom 2>/dev/null | tr -d ' ')
    fi
    if [[ ! "$rand_val" =~ ^[0-9]+$ ]]; then
        rand_val=$RANDOM
    fi
    echo $(( (rand_val % 55536) + 10000 ))
}

# 随机 UUID 生成
_generate_uuid() {
    if [ -x "$SINGBOX_BIN" ]; then
        local u
        u=$("$SINGBOX_BIN" generate uuid 2>/dev/null)
        if [ -n "$u" ]; then echo "$u"; return 0; fi
    fi
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid && return 0
    fi
    if command -v openssl &>/dev/null; then
        local h
        h=$(openssl rand -hex 16 2>/dev/null)
        if [ -n "$h" ]; then
            printf '%s-%s-%s-%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
            return 0
        fi
    fi
    _error "无法生成安全随机 UUID（缺少可用随机源）"
    return 1
}

# 容器环境检测
_is_container_environment() {
    [ -e /run/.containerenv ] || [ -e /.dockerenv ] || [ -s /run/systemd/container ] && return 0
    if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container --quiet 2>/dev/null; then
        return 0
    fi
    grep -qaE 'container=|lxc|libpod|podman|docker' /proc/1/environ /proc/1/cgroup 2>/dev/null
}

_is_podman_environment() {
    [ -f /run/.containerenv ] && return 0
    grep -qaE 'libpod|podman' /proc/1/cgroup /proc/1/environ 2>/dev/null
}

# 公网 IP 获取 (带全局缓存)
server_ip=""
_get_public_ip() {
    [ -n "$server_ip" ] && [ "$server_ip" != "null" ] && { echo "$server_ip"; return; }
    local ip
    ip=$(timeout 5 curl -fsS4 --max-time 2 https://icanhazip.com 2>/dev/null || timeout 5 curl -fsS4 --max-time 2 https://ipinfo.io/ip 2>/dev/null)
    [ -z "$ip" ] && ip=$(timeout 5 curl -fsS6 --max-time 2 https://icanhazip.com 2>/dev/null || timeout 5 curl -fsS6 --max-time 2 https://ipinfo.io/ip 2>/dev/null)
    server_ip="$ip"
    echo "$ip"
}

# 初始化公网 IP
_init_server_ip() {
    _info "正在获取服务器公网 IP..."
    server_ip=$(_get_public_ip)
    if [ -z "$server_ip" ] || [ "$server_ip" == "null" ]; then
        server_ip=""
        _warn "自动获取服务器公网 IP 失败"
    else
        _success "当前服务器公网 IP: ${server_ip}"
    fi
}

# ============================================================
# 系统环境检测
# ============================================================

_detect_init_system() {
    if [ -f /sbin/openrc-run ] || command -v rc-service &>/dev/null; then
        export INIT_SYSTEM="openrc"
        export SERVICE_FILE="/etc/init.d/sing-box"
    elif command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        export INIT_SYSTEM="systemd"
        export SERVICE_FILE="/etc/systemd/system/sing-box.service"
    else
        export INIT_SYSTEM="direct"
        export SERVICE_FILE=""
    fi
}

# 端口占用检查
_check_port_occupied() {
    local port=$1
    local proto=${2:-tcp}
    if [[ "$proto" == "tcp" ]]; then
        if command -v ss &>/dev/null; then
            ss -lnpt | grep -qE ":${port}([[:space:]]|$|%)" && return 0
        else
            netstat -lnpt | grep -qE ":${port}([[:space:]]|$)" && return 0
        fi
    else
        if command -v ss &>/dev/null; then
            ss -lnpu | grep -qE ":${port}([[:space:]]|$|%)" && return 0
        else
            netstat -lnpu | grep -qE ":${port}([[:space:]]|$)" && return 0
        fi
    fi
    return 1
}

# 检查端口是否在 config.json 中已使用
_check_port_in_config() {
    local port="$1"
    [ -s "$CONFIG_FILE" ] || return 1
    jq -e --argjson port "$port" '.inbounds[]? | select((.listen_port | tonumber?) == $port)' "$CONFIG_FILE" >/dev/null 2>&1
}

# 综合端口冲突检测
_check_port_conflict() {
    local port="$1" silent="${2:-false}"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        [ "$silent" != "true" ] && _error "端口 ${port} 无效，应为 1-65535。"
        return 0
    fi
    if _check_port_in_config "$port"; then
        [ "$silent" != "true" ] && _error "端口 ${port} 已在 config.json 中使用。"
        return 0
    fi
    if _check_port_occupied "$port" "tcp"; then
        [ "$silent" != "true" ] && _error "TCP 端口 ${port} 已被系统占用。"
        return 0
    fi
    return 1
}

# PID 管理
_is_pid_running_cmd() {
    local pid="$1"
    local pattern="$2"
    [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    if [ -r "/proc/${pid}/cmdline" ]; then
        tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -Fq "$pattern"
    else
        ps -p "$pid" -o args= 2>/dev/null | grep -Fq "$pattern"
    fi
}

_is_pid_file_running_cmd() {
    local pid_file="$1"
    local pattern="$2"
    local pid
    [ -s "$pid_file" ] || return 1
    pid=$(cat "$pid_file" 2>/dev/null)
    _is_pid_running_cmd "$pid" "$pattern"
}

_prepare_runtime_pid() {
    mkdir -p "$RUNTIME_DIR" || return 1
    chmod 700 "$RUNTIME_DIR" 2>/dev/null || return 1
    if _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN"; then
        return 0
    fi
    rm -f -- "$PID_FILE"
}

# ============================================================
# 智能包管理
# ============================================================

_pkg_install() {
    local pkgs="$*"
    [ -z "$pkgs" ] && return 0
    if command -v apk &>/dev/null; then
        apk add --no-cache $pkgs >/dev/null 2>&1
    elif command -v apt-get &>/dev/null; then
        if [ ! -d "/var/lib/apt/lists" ] || [ "$(ls -A /var/lib/apt/lists/ 2>/dev/null | wc -l)" -le 1 ]; then
            apt-get update -qq >/dev/null 2>&1
        fi
        if _is_podman_environment; then
            local pkg
            for pkg in $pkgs; do
                if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
                    continue
                fi
                if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                    -o Dpkg::Use-Pty=0 -o Acquire::Languages=none "$pkg" >/dev/null 2>&1; then
                    apt-get update -qq -o Acquire::Languages=none >/dev/null 2>&1 || return 1
                    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                        -o Dpkg::Use-Pty=0 -o Acquire::Languages=none "$pkg" >/dev/null 2>&1 || return 1
                fi
            done
        else
            DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1 || {
                apt-get update -qq >/dev/null 2>&1
                DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1
            }
        fi
    elif command -v yum &>/dev/null; then yum install -y $pkgs >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then dnf install -y $pkgs >/dev/null 2>&1
    else
        return 1
    fi
}

# ============================================================
# 依赖安装
# ============================================================

_install_dependencies() {
    local core_pkgs="bash curl jq openssl wget tar ca-certificates"
    _info "正在安装核心依赖..."
    _pkg_install $core_pkgs

    # 关键依赖验证
    local missing=""
    for cmd in bash jq curl wget openssl tar; do
        if ! command -v "$cmd" &>/dev/null; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        _error "以下关键依赖安装失败:${missing}"
        _error "请使用系统包管理器手动安装"
        exit 1
    fi
    mkdir -p "$SINGBOX_DIR"
}

# ============================================================
# 内存限额计算
# ============================================================

_get_mem_limit() {
    local total_mem_mb=0 cgroup_limit="" candidate_mb=0
    local limit limit_file

    total_mem_mb=$(awk '/^MemTotal:/{print int($2 / 1024); exit}' /proc/meminfo 2>/dev/null)
    [[ "$total_mem_mb" =~ ^[0-9]+$ ]] || total_mem_mb=0

    if [ -r /sys/fs/cgroup/memory.max ]; then
        for limit_file in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.high; do
            [ -r "$limit_file" ] || continue
            cgroup_limit=$(cat "$limit_file" 2>/dev/null)
            if [[ "$cgroup_limit" =~ ^[0-9]+$ ]] && [ "$cgroup_limit" -lt 9223372036854771712 ] 2>/dev/null; then
                candidate_mb=$((cgroup_limit / 1024 / 1024))
                if [ "$candidate_mb" -gt 0 ] && { [ "$total_mem_mb" -eq 0 ] || [ "$candidate_mb" -lt "$total_mem_mb" ]; }; then
                    total_mem_mb=$candidate_mb
                fi
            fi
        done
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        cgroup_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
        if [[ "$cgroup_limit" =~ ^[0-9]+$ ]] && [ "$cgroup_limit" -lt 9223372036854771712 ] 2>/dev/null; then
            candidate_mb=$((cgroup_limit / 1024 / 1024))
            if [ "$candidate_mb" -gt 0 ] && { [ "$total_mem_mb" -eq 0 ] || [ "$candidate_mb" -lt "$total_mem_mb" ]; }; then
                total_mem_mb=$candidate_mb
            fi
        fi
    fi

    [ "$total_mem_mb" -gt 0 ] || return 1

    if [ "$total_mem_mb" -le 128 ]; then
        limit=$((total_mem_mb * 5 / 16))
    elif [ "$total_mem_mb" -le 256 ]; then
        limit=$((total_mem_mb * 50 / 100))
    elif [ "$total_mem_mb" -le 512 ]; then
        limit=$((total_mem_mb * 65 / 100))
    else
        limit=$((total_mem_mb * 80 / 100))
    fi

    [ "$limit" -lt 32 ] && limit=32
    echo "$limit"
}

# ============================================================
# 原子 JSON 修改
# ============================================================

_atomic_modify_json() {
    local file="$1" filter="$2"
    shift 2
    [ ! -f "$file" ] && return 1
    local tmp
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    if jq "$@" "$filter" "$file" > "$tmp" && jq empty "$tmp" >/dev/null 2>&1; then
        chmod 600 "$tmp" 2>/dev/null || true
        if ! mv -f "$tmp" "$file"; then
            _error "替换 JSON 失败: $file"
            rm -f "$tmp"
            return 1
        fi
    else
        _error "修改 JSON 失败: $file"
        rm -f "$tmp"
        return 1
    fi
}

# ============================================================
# 自签名证书生成
# ============================================================

_generate_self_signed_cert() {
    local domain="$1"
    local cert_path="$2"
    local key_path="$3"
    local days="${4:-3650}"

    _info "正在为 ${domain} 生成自签名证书 (有效期 ${days} 天)..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key_path" -out "$cert_path" -days "$days" \
        -subj "/CN=${domain}" 2>/dev/null || {
        _error "证书生成失败"
        return 1
    }
    chmod 600 "$key_path" "$cert_path" 2>/dev/null || true
    _success "自签名证书生成完成"
}

# sing-box 格式证书公钥 SPKI SHA-256 (Base64)
_cert_spki_sha256_b64() {
    local cert_path="$1"
    [ -f "$cert_path" ] || return 1
    openssl x509 -in "$cert_path" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform der 2>/dev/null \
        | openssl dgst -sha256 -binary 2>/dev/null \
        | openssl enc -base64 -A 2>/dev/null
}

# Honk 格式证书 DER SHA-256 (Hex)
_cert_der_sha256_hex() {
    local cert_path="$1"
    [ -f "$cert_path" ] || return 1
    if command -v sha256sum &>/dev/null; then
        openssl x509 -in "$cert_path" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
    else
        openssl x509 -in "$cert_path" -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null | awk '{print tolower($NF)}'
    fi
}

# 统一输出 3 行格式:
# 第1行: &insecure=1 链接
# 第2行: sing-box SPKI SHA-256 Base64 (直接输出)
# 第3行: Honk pinSHA256 链接
_print_node_share_lines() {
    local password="$1" link_ip="$2" port="$3" server_name="$4" name="$5" cert_path="$6" indent="${7:-}"
    local encoded_name encoded_pw encoded_sni
    encoded_name=$(_url_encode "$name")
    encoded_pw=$(_url_encode "$password")
    encoded_sni=$(_url_encode "$server_name")
    local link_insecure="anytls://${encoded_pw}@${link_ip}:${port}?security=tls&sni=${encoded_sni}&insecure=1&type=tcp#${encoded_name}"
    local spki_b64 honk_hex
    spki_b64=$(_cert_spki_sha256_b64 "$cert_path")
    honk_hex=$(_cert_der_sha256_hex "$cert_path")

    echo -e "${indent}${YELLOW}${link_insecure}${NC}"
    echo -e "${indent}${CYAN}${spki_b64:-获取失败}${NC}"
    if [ -n "$honk_hex" ]; then
        local link_honk="anytls://${encoded_pw}@${link_ip}:${port}?sni=${encoded_sni}&pinSHA256=${honk_hex}#${encoded_name}"
        echo -e "${indent}${YELLOW}${link_honk}${NC}"
    else
        echo -e "${indent}${YELLOW}Honk 链接生成失败（缺少证书）${NC}"
    fi
}

# ============================================================
# sing-box 核心安装
# ============================================================

_install_sing_box() {
    local api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    _info "正在安装最新稳定版 sing-box..."

    local arch=$(uname -m)
    local arch_tag
    case $arch in
        x86_64|amd64) arch_tag='amd64' ;;
        aarch64|arm64) arch_tag='arm64' ;;
        armv7l) arch_tag='armv7' ;;
        *) _error "不支持的架构：$arch"; return 1 ;;
    esac

    # 检测 C 库类型
    local libc_suffix=""
    if ldd --version 2>&1 | grep -qi musl || [ -f /etc/alpine-release ]; then
        _info "检测到 musl libc，将下载 musl 版本..."
        libc_suffix="-musl"
    fi

    local search_pattern="linux-${arch_tag}${libc_suffix}.tar.gz"
    local asset_info release_tag release_draft release_prerelease
    local asset_count asset_name download_url asset_digest release_version expected_asset_name

    if ! asset_info=$(curl -fsSL --retry 3 --connect-timeout 10 "$api_url" | jq -r --arg pattern "$search_pattern" '
        [.assets[] | select(.name | endswith($pattern))] as $matches
        | [(.tag_name // ""),
           (if (.draft | type) == "boolean" then .draft else true end),
           (if (.prerelease | type) == "boolean" then .prerelease else true end),
           ($matches | length), ($matches[0].name // ""),
           ($matches[0].browser_download_url // ""), ($matches[0].digest // "")]
        | @tsv
    '); then
        _error "无法读取 sing-box 官方发布信息。"
        return 1
    fi

    IFS=$'\t' read -r release_tag release_draft release_prerelease asset_count asset_name download_url asset_digest <<< "$asset_info"

    if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || [ "$release_draft" != "false" ] || [ "$release_prerelease" != "false" ]; then
        _error "sing-box 官方发布元数据无效或不是稳定版，已拒绝安装。"
        return 1
    fi
    release_version="${release_tag#v}"

    if [ "$asset_count" != "1" ]; then
        _error "sing-box 官方发布中目标资产数量异常 (${asset_count:-无法解析})，已拒绝安装。"
        return 1
    fi

    expected_asset_name="sing-box-${release_version}-linux-${arch_tag}${libc_suffix}.tar.gz"
    if [ "$asset_name" != "$expected_asset_name" ] || [ -z "$download_url" ] \
        || [[ "$download_url" != "https://github.com/SagerNet/sing-box/releases/download/${release_tag}/${expected_asset_name}" ]]; then
        _error "无法获取可信的 sing-box 下载链接。"
        return 1
    fi

    if [[ ! "$asset_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        _error "sing-box 官方资产缺少有效的 API SHA-256 摘要，已拒绝安装。"
        return 1
    fi

    # 下载并校验
    local temp_dir="" staged_bin="" backup_bin=""
    mkdir -p /var/tmp || { _error "创建临时目录失败。"; return 1; }

    # 清理旧安装残留 (包括被 OOM SIGKILL 导致进程非正常死亡遗留的目录)
    local stale_dir stale_pid
    for stale_dir in /var/tmp/.singbox-anytls-install.*; do
        [ -d "$stale_dir" ] || continue
        stale_pid=""
        [ -s "${stale_dir}/.active" ] && stale_pid=$(cat "${stale_dir}/.active" 2>/dev/null)
        if [ -n "$stale_pid" ] && kill -0 "$stale_pid" 2>/dev/null; then
            continue
        fi
        rm -rf -- "$stale_dir"
    done

    # 清理目标目录下的旧暂存与回滚残留
    local stale_bin
    for stale_bin in "$(dirname "$SINGBOX_BIN")"/.sing-box.new.* "$(dirname "$SINGBOX_BIN")"/.sing-box.rollback.*; do
        [ -f "$stale_bin" ] || continue
        rm -f -- "$stale_bin"
    done

    temp_dir=$(mktemp -d /var/tmp/.singbox-anytls-install.XXXXXX) || { _error "创建临时目录失败。"; return 1; }
    printf '%s\n' "$$" > "${temp_dir}/.active"
    local digest_file="${temp_dir}/.archive.sha256"

    # 设置局部退出陷阱，防止异常中断留下临时文件
    _cleanup_install_temp() {
        [ -n "$temp_dir" ] && rm -rf "$temp_dir"
        [ -n "$staged_bin" ] && rm -f "$staged_bin"
        [ -n "$backup_bin" ] && rm -f "$backup_bin"
        trap - EXIT INT TERM
    }
    trap _cleanup_install_temp EXIT INT TERM

    _info "正在下载并校验 sing-box 安装包..."
    if command -v sha256sum &>/dev/null; then
        wget -qO- "$download_url" | tee >(sha256sum > "$digest_file") | tar -xzf - -C "$temp_dir"
    else
        wget -qO- "$download_url" | tee >(openssl dgst -sha256 > "$digest_file") | tar -xzf - -C "$temp_dir"
    fi
    local -a stream_status=("${PIPESTATUS[@]}")
    if [ "${stream_status[0]:-1}" -ne 0 ] || [ "${stream_status[2]:-1}" -ne 0 ]; then
        _error "sing-box 安装包下载失败。"
        _cleanup_install_temp
        return 1
    fi

    # 等待摘要文件写入
    local digest_wait=0
    while [ ! -s "$digest_file" ] && [ "$digest_wait" -lt 50 ]; do
        sleep 0.1
        digest_wait=$((digest_wait + 1))
    done

    local expected="${asset_digest#sha256:}" actual
    if command -v sha256sum &>/dev/null; then
        actual=$(awk '{print $1}' "$digest_file" 2>/dev/null)
    else
        actual=$(awk '{print $NF}' "$digest_file" 2>/dev/null)
    fi
    if [ -z "$expected" ] || [ -z "$actual" ] || [ "${expected,,}" != "${actual,,}" ]; then
        _error "sing-box 安装包 SHA-256 校验失败，已拒绝安装。"
        _cleanup_install_temp
        return 1
    fi

    local extracted_bin
    extracted_bin=$(find "$temp_dir" -name sing-box -type f 2>/dev/null | head -n 1)
    if [ -z "$extracted_bin" ]; then
        _error "解压后未找到 sing-box 二进制文件。"
        _cleanup_install_temp
        return 1
    fi
    chmod 755 "$extracted_bin" || { _cleanup_install_temp; return 1; }
    if ! "$extracted_bin" version >/dev/null 2>&1; then
        _error "下载的 sing-box 核心无法执行，已拒绝安装。"
        _cleanup_install_temp
        return 1
    fi

    local extracted_version
    extracted_version=$("$extracted_bin" version 2>/dev/null | sed -n 's/^sing-box version \([^[:space:]]*\).*/\1/p' | head -n 1)
    if [ "$extracted_version" != "$release_version" ]; then
        _error "下载核心版本与官方发布不匹配：期望 v${release_version}，实际 v${extracted_version:-未知}。"
        _cleanup_install_temp
        return 1
    fi

    # 如果已有配置，用新核心校验
    if [ -s "$CONFIG_FILE" ]; then
        if ! "$extracted_bin" check -c "$CONFIG_FILE" 2>&1; then
            _error "新核心无法加载当前 config.json，已取消更新。"
            _cleanup_install_temp
            return 1
        fi
    fi

    # 安装到目标路径
    mkdir -p "$(dirname "$SINGBOX_BIN")" || { _cleanup_install_temp; return 1; }
    staged_bin=$(mktemp "$(dirname "$SINGBOX_BIN")/.sing-box.new.XXXXXX") || { _cleanup_install_temp; return 1; }
    rm -f -- "$staged_bin"
    if ! mv -f -- "$extracted_bin" "$staged_bin"; then
        _cleanup_install_temp
        return 1
    fi
    chmod 755 "$staged_bin" || { _cleanup_install_temp; return 1; }

    if [ -f "$SINGBOX_BIN" ]; then
        backup_bin="$(dirname "$SINGBOX_BIN")/.sing-box.rollback.$$"
        cp -p "$SINGBOX_BIN" "$backup_bin" 2>/dev/null || true
    fi

    if ! mv -f "$staged_bin" "$SINGBOX_BIN"; then
        _cleanup_install_temp
        return 1
    fi

    # 安装成功，清理临时文件与备份
    rm -rf "$temp_dir"
    [ -n "$backup_bin" ] && rm -f "$backup_bin"
    trap - EXIT INT TERM
    sync 2>/dev/null || true
    _success "sing-box v${release_version} 安装成功"
}

# ============================================================
# 服务管理
# ============================================================

_create_service_file() {
    [ -z "$INIT_SYSTEM" ] && _detect_init_system
    local mem_limit=""
    mem_limit=$(_get_mem_limit 2>/dev/null || true)
    touch "$LOG_FILE" 2>/dev/null || true

    local systemd_env_line="" openrc_env_line=""
    if [ -n "$mem_limit" ]; then
        systemd_env_line="Environment=GOMEMLIMIT=${mem_limit}MiB"
        openrc_env_line="export GOMEMLIMIT=\"${mem_limit}MiB\""
    fi

    case "$INIT_SYSTEM" in
        systemd)
            cat > "$SERVICE_FILE" << SYSTEMD_EOF
[Unit]
Description=sing-box service (AnyTLS)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
${systemd_env_line}
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF
            systemctl daemon-reload
            systemctl enable sing-box >/dev/null 2>&1 || true
            ;;
        openrc)
            cat > "$SERVICE_FILE" << OPENRC_EOF
#!/sbin/openrc-run

description="sing-box service (AnyTLS)"
${openrc_env_line}
command="/usr/local/bin/sing-box"
command_args="run -c /usr/local/etc/sing-box/config.json"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0

pidfile="${PID_FILE}"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

start_pre() {
    checkpath -d -m 0700 "${RUNTIME_DIR}"
}

depend() {
    need net
    after firewall
}
OPENRC_EOF
            chmod 755 "$SERVICE_FILE"
            rc-update add sing-box default >/dev/null 2>&1 || true
            ;;
    esac
}

_manage_service() {
    local action="$1"
    [ -z "$INIT_SYSTEM" ] && _detect_init_system

    if [[ "$action" == "restart" || "$action" == "start" ]]; then
        [ -s "$CONFIG_FILE" ] || { _error "配置文件不存在: $CONFIG_FILE"; return 1; }
        [ -x "$SINGBOX_BIN" ] || { _error "sing-box 核心不可执行: $SINGBOX_BIN"; return 1; }
        # 预检
        if ! "$SINGBOX_BIN" check -c "$CONFIG_FILE" 2>&1; then
            _error "配置文件校验失败，拒绝启动。"
            return 1
        fi
    fi

    [ "$action" == "status" ] || _info "正在使用 ${INIT_SYSTEM} 执行: $action..."
    case "$INIT_SYSTEM" in
        systemd)
            if [ "$action" == "status" ]; then systemctl status sing-box --no-pager -l; return; fi
            if [ "$action" == "start" ] || [ "$action" == "restart" ]; then
                systemctl reset-failed sing-box >/dev/null 2>&1 || true
            fi
            systemctl "$action" sing-box
            ;;
        openrc)
            if [ "$action" == "status" ]; then rc-service sing-box status; return; fi
            rc-service sing-box "$action"
            ;;
        direct)
            if ! _prepare_runtime_pid; then
                _error "无法准备运行目录: ${RUNTIME_DIR}"
                return 1
            fi
            case "$action" in
                start)
                    if _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN"; then
                        _success "sing-box 已在运行。"
                        return 0
                    fi
                    rm -f "$PID_FILE"
                    local direct_mem_limit=""
                    direct_mem_limit=$(_get_mem_limit 2>/dev/null || true)
                    if [ -n "$direct_mem_limit" ]; then
                        nohup env GOMEMLIMIT="${direct_mem_limit}MiB" \
                            "$SINGBOX_BIN" run -c "$CONFIG_FILE" \
                            >> "$LOG_FILE" 2>&1 &
                    else
                        nohup "$SINGBOX_BIN" run -c "$CONFIG_FILE" \
                            >> "$LOG_FILE" 2>&1 &
                    fi
                    echo $! > "$PID_FILE"
                    chmod 600 "$PID_FILE" 2>/dev/null || true
                    sleep 1
                    if ! _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN"; then
                        _error "sing-box 启动后立即退出，请检查日志: $LOG_FILE"
                        rm -f "$PID_FILE"
                        return 1
                    fi
                    _success "sing-box 已启动 (direct 模式)。"
                    ;;
                stop)
                    if [ -s "$PID_FILE" ]; then
                        local pid
                        pid=$(cat "$PID_FILE" 2>/dev/null)
                        if _is_pid_running_cmd "$pid" "$SINGBOX_BIN"; then
                            kill "$pid" 2>/dev/null
                        fi
                    fi
                    rm -f "$PID_FILE"
                    _success "sing-box 已停止。"
                    ;;
                restart)
                    _manage_service stop
                    sleep 1
                    _manage_service start
                    ;;
                status)
                    if _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN"; then
                        _success "sing-box 运行中 (PID: $(cat "$PID_FILE"))"
                    else
                        rm -f "$PID_FILE"
                        _warn "sing-box 未运行。"
                        return 1
                    fi
                    ;;
                *) _error "不支持的操作: $action"; return 1 ;;
            esac
            ;;
        *) _error "不支持的服务管理系统" ;;
    esac

    # 启动与重启的延迟健康状态校验（杜绝假成功）
    if [[ "$action" == "start" || "$action" == "restart" ]]; then
        sleep 1
        local service_alive=false
        case "$INIT_SYSTEM" in
            systemd)
                systemctl is-active sing-box >/dev/null 2>&1 && service_alive=true
                ;;
            openrc)
                rc-service sing-box status >/dev/null 2>&1 && service_alive=true
                ;;
            direct)
                _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN" && service_alive=true
                ;;
        esac
        if [ "$service_alive" != "true" ]; then
            _error "sing-box 服务启动失败（进程秒退或被内核杀死 Killed）！"
            if [ -s "$LOG_FILE" ]; then
                _error "--- 日志末尾 20 行 ---"
                tail -n 20 "$LOG_FILE" >&2
                _error "----------------------"
            fi
            return 1
        fi
    fi
}

# ============================================================
# 初始化配置文件
# ============================================================

_init_config() {
    if [ -s "$CONFIG_FILE" ]; then
        return 0
    fi
    mkdir -p "$SINGBOX_DIR"

    # 精简 NTP：固定写入 time.apple.com / 1min
    cat > "$CONFIG_FILE" << 'CONFIG_EOF'
{
    "log": {
        "level": "info",
        "timestamp": true
    },
    "ntp": {
        "enabled": true,
        "server": "time.apple.com",
        "server_port": 123,
        "interval": "1m",
        "write_to_system": false
    },
    "inbounds": [],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct-out"
        }
    ],
    "route": {
        "rules": [],
        "final": "direct-out"
    }
}
CONFIG_EOF
    chmod 600 "$CONFIG_FILE"

    # 初始化 metadata
    if [ ! -s "$METADATA_FILE" ]; then
        echo '{}' > "$METADATA_FILE"
        chmod 600 "$METADATA_FILE"
    fi
    _success "配置文件初始化完成"
}

# ============================================================
# 创建 AnyTLS 节点
# ============================================================

_create_anytls_node() {
    local node_ip="$1"
    local port="$2"
    local server_name="$3"
    local password="$4"
    local name="$5"

    local tag="anytls-in-${port}"

    # 自动生成自签名证书
    local cert_path="${SINGBOX_DIR}/${tag}.pem"
    local key_path="${SINGBOX_DIR}/${tag}.key"
    _generate_self_signed_cert "$server_name" "$cert_path" "$key_path" || return 1

    # IPv6 处理
    local link_ip="$node_ip"
    [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"

    # 生成 Inbound 配置
    # padding_scheme 设为空数组以启用 sing-box 内置的标准填充方案
    local inbound_json
    inbound_json=$(jq -n \
        --arg t "$tag" \
        --arg p "$port" \
        --arg pw "$password" \
        --arg cp "$cert_path" \
        --arg kp "$key_path" \
        '{
            "type": "anytls",
            "tag": $t,
            "listen": "::",
            "listen_port": ($p|tonumber),
            "users": [{"name": "default", "password": $pw}],
            "padding_scheme": [],
            "tls": {
                "enabled": true,
                "certificate_path": $cp,
                "key_path": $kp
            }
        }')

    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json] | .inbounds |= unique_by(.tag)" || return 1

    # 保存元数据
    local meta_json
    meta_json=$(jq -n --arg n "$name" --arg sn "$server_name" --arg p "$password" \
        '{name:$n, server_name:$sn, password:$p}')
    _atomic_modify_json "$METADATA_FILE" '. + {($tag): $meta}' --arg tag "$tag" --argjson meta "$meta_json" || return 1

    # 重启服务并进行健康检查
    if ! _manage_service restart; then
        _error "服务重启失败，正在回滚配置..."
        _atomic_modify_json "$CONFIG_FILE" 'del(.inbounds[] | select(.tag == $tag))' --arg tag "$tag"
        _atomic_modify_json "$METADATA_FILE" 'del(.[$tag])' --arg tag "$tag"
        rm -f "$cert_path" "$key_path"
        _manage_service restart >/dev/null 2>&1 || true
        return 1
    fi

    # 二次验证：端口是否真正处于监听状态（坚决杜绝假成功）
    sleep 1
    if ! _check_port_occupied "$port" "tcp"; then
        _error "服务虽已尝试启动，但端口 ${port} 未处于监听状态（进程可能崩溃或被杀），正在回滚..."
        if [ -s "$LOG_FILE" ]; then
            _error "--- 日志末尾 20 行 ---"
            tail -n 20 "$LOG_FILE" >&2
            _error "----------------------"
        fi
        _atomic_modify_json "$CONFIG_FILE" 'del(.inbounds[] | select(.tag == $tag))' --arg tag "$tag"
        _atomic_modify_json "$METADATA_FILE" 'del(.[$tag])' --arg tag "$tag"
        rm -f "$cert_path" "$key_path"
        _manage_service restart >/dev/null 2>&1 || true
        return 1
    fi

    echo ""
    _success "AnyTLS 节点 [${name}] 创建成功!"
    echo "==========================================="
    echo -e "  节点名称: ${GREEN}${name}${NC}"
    echo -e "  监听端口: ${CYAN}${port}${NC}"
    echo -e "  SNI:      ${CYAN}${server_name}${NC}"
    echo -e "  密码:     ${CYAN}${password}${NC}"
    echo -e "  服务器IP: ${CYAN}${node_ip}${NC}"
    echo "==========================================="
    echo ""
    echo -e "${GREEN}分享链接:${NC}"
    _print_node_share_lines "$password" "$link_ip" "$port" "$server_name" "$name" "$cert_path"
    echo ""
}

_create_ss2022_node() {
    local node_ip="$1" port="$2" password="$3" name="$4"
    local tag="ss-in-${port}"
    local method="2022-blake3-aes-256-gcm"

    # IPv6 处理
    local link_ip="$node_ip"
    [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"

    local inbound_json
    inbound_json=$(jq -n \
        --arg t "$tag" \
        --arg p "$port" \
        --arg m "$method" \
        --arg pw "$password" \
        '{
            "type": "shadowsocks",
            "tag": $t,
            "listen": "::",
            "listen_port": ($p|tonumber),
            "method": $m,
            "password": $pw
        }')

    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json] | .inbounds |= unique_by(.tag)" || return 1

    local meta_json
    meta_json=$(jq -n --arg n "$name" --arg m "$method" --arg pw "$password" \
        '{name:$n, protocol:"shadowsocks", method:$m, password:$pw}')
    _atomic_modify_json "$METADATA_FILE" '. + {($tag): $meta}' --arg tag "$tag" --argjson meta "$meta_json" || return 1

    if ! _manage_service restart; then
        _error "服务重启失败，正在回滚配置..."
        _atomic_modify_json "$CONFIG_FILE" 'del(.inbounds[] | select(.tag == $tag))' --arg tag "$tag"
        _atomic_modify_json "$METADATA_FILE" 'del(.[$tag])' --arg tag "$tag"
        _manage_service restart >/dev/null 2>&1 || true
        return 1
    fi

    sleep 1
    if ! _check_port_occupied "$port" "tcp"; then
        _error "服务虽已尝试启动，但端口 ${port} 未处于监听状态（进程可能崩溃或被杀），正在回滚..."
        if [ -s "$LOG_FILE" ]; then
            _error "--- 日志末尾 20 行 ---"
            tail -n 20 "$LOG_FILE" >&2
            _error "----------------------"
        fi
        _atomic_modify_json "$CONFIG_FILE" 'del(.inbounds[] | select(.tag == $tag))' --arg tag "$tag"
        _atomic_modify_json "$METADATA_FILE" 'del(.[$tag])' --arg tag "$tag"
        _manage_service restart >/dev/null 2>&1 || true
        return 1
    fi

    local ss_link="ss://${method}:$(_url_encode "$password")@${link_ip}:${port}#$(_url_encode "$name")"

    echo ""
    _success "SS2022 节点 [${name}] 创建成功!"
    echo "==========================================="
    echo -e "  节点名称: ${GREEN}${name}${NC}"
    echo -e "  协议加密: ${CYAN}${method}${NC}"
    echo -e "  监听端口: ${CYAN}${port}${NC}"
    echo -e "  密钥:     ${CYAN}${password}${NC}"
    echo -e "  服务器IP: ${CYAN}${node_ip}${NC}"
    echo "==========================================="
    echo ""
    echo -e "${GREEN}分享链接:${NC}"
    echo -e "${YELLOW}${ss_link}${NC}"
    echo ""
}

# ============================================================
# 交互式创建
# ============================================================

_add_anytls() {
    [ -z "$server_ip" ] && _init_server_ip
    local node_ip=""

    _info "--- 创建 AnyTLS 节点 ---"

    # 输入 IP
    if [ -n "$server_ip" ]; then
        read -p "请输入服务器IP地址 (默认: ${server_ip}): " custom_ip
        node_ip=${custom_ip:-$server_ip}
    else
        while [ -z "$node_ip" ]; do
            read -p "无法自动获取公网 IP，请手动输入服务器IP或域名: " node_ip
        done
    fi

    # 输入端口
    local port=""
    while true; do
        read -p "请输入监听端口 (回车随机生成): " port
        if [ -z "$port" ]; then
            port=$(_get_random_port)
            _info "已生成随机端口: ${port}"
        fi
        if _check_port_conflict "$port"; then
            continue
        fi
        break
    done

    # 输入 SNI
    read -p "请输入伪装域名/SNI (默认: ${DEFAULT_SNI}): " sni
    sni=${sni:-"$DEFAULT_SNI"}

    # 输入密码
    read -p "请输入密码/UUID (回车随机生成): " input_pw
    local password="$input_pw"
    if [ -z "$password" ]; then
        password=$(_generate_uuid) || return 1
    fi

    # 输入节点名称
    local default_name="AnyTLS-${port}"
    read -p "请输入节点名称 (默认: ${default_name}): " custom_name
    local name=${custom_name:-$default_name}

    _create_anytls_node "$node_ip" "$port" "$sni" "$password" "$name"
}

# ============================================================
# 查看节点
# ============================================================

_view_nodes() {
    local filter="${1:-}"
    _info "--- 节点列表 ---"

    if [ ! -s "$METADATA_FILE" ] || [ "$(jq 'length' "$METADATA_FILE" 2>/dev/null)" == "0" ]; then
        _warn "暂无节点。"
        return
    fi

    [ -z "$server_ip" ] && server_ip=$(_get_public_ip)
    local link_ip="${server_ip:-<SERVER_IP>}"
    [ -z "$server_ip" ] && _warn "未能获取公网 IP，链接中已使用 <SERVER_IP> 占位。"
    [[ "$link_ip" == *":"* ]] && link_ip="[${link_ip}]"

    local idx=0 matched=0
    echo ""
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        idx=$((idx + 1))
        local tag name password port proto
        tag=$(printf '%s' "$entry" | jq -r '.key')
        name=$(printf '%s' "$entry" | jq -r '.value.name // "未命名"')
        proto=$(printf '%s' "$entry" | jq -r '.value.protocol // "anytls"')
        password=$(printf '%s' "$entry" | jq -r '.value.password // ""')

        if [[ "$tag" == ss-in-* ]] || [ "$proto" == "shadowsocks" ]; then
            port="${tag#ss-in-}"
            if [ -n "$filter" ] && [ "$filter" != "$idx" ] && [ "$filter" != "$port" ] && [ "$filter" != "$name" ] && [ "$filter" != "$tag" ]; then
                continue
            fi
            matched=$((matched + 1))
            local method
            method=$(printf '%s' "$entry" | jq -r '.value.method // "2022-blake3-aes-256-gcm"')
            if [ -z "$password" ] && [ -s "$CONFIG_FILE" ]; then
                password=$(jq -r --arg tag "$tag" '.inbounds[]? | select(.tag == $tag) | .password // ""' "$CONFIG_FILE" 2>/dev/null)
            fi
            local ss_link="ss://${method}:$(_url_encode "$password")@${link_ip}:${port}#$(_url_encode "$name")"
            echo -e "  ${GREEN}[${idx}]${NC} ${name} ${CYAN}[SS2022]${NC}"
            echo -e "      端口: ${CYAN}${port}${NC}  加密: ${CYAN}${method}${NC}"
            echo -e "      密钥: ${CYAN}${password}${NC}"
            echo -e "      ${YELLOW}${ss_link}${NC}"
            echo ""
            continue
        fi

        local sn cert_path
        sn=$(printf '%s' "$entry" | jq -r '.value.server_name // "未知"')
        port="${tag#anytls-in-}"
        if [ -n "$filter" ] && [ "$filter" != "$idx" ] && [ "$filter" != "$port" ] && [ "$filter" != "$name" ] && [ "$filter" != "$tag" ]; then
            continue
        fi
        matched=$((matched + 1))

        # 如果 metadata 中没有 password，从 config.json 读取
        if [ -z "$password" ] && [ -s "$CONFIG_FILE" ]; then
            password=$(jq -r --arg tag "$tag" '.inbounds[]? | select(.tag == $tag) | .users[0].password // ""' "$CONFIG_FILE" 2>/dev/null)
        fi

        cert_path="${SINGBOX_DIR}/${tag}.pem"

        local relay_info=""
        local relay_enabled
        relay_enabled=$(printf '%s' "$entry" | jq -r '.value.relay.enabled // false')
        if [ "$relay_enabled" == "true" ]; then
            local r_name r_server r_port
            r_name=$(printf '%s' "$entry" | jq -r '.value.relay.name // "SS"')
            r_server=$(printf '%s' "$entry" | jq -r '.value.relay.server // ""')
            r_port=$(printf '%s' "$entry" | jq -r '.value.relay.port // ""')
            relay_info="${GREEN}落地中转 -> [${r_name}] (${r_server}:${r_port})${NC}"
        else
            relay_info="${CYAN}默认直连 (direct)${NC}"
        fi

        echo -e "  ${GREEN}[${idx}]${NC} ${name}"
        echo -e "      端口: ${CYAN}${port}${NC}  SNI: ${CYAN}${sn}${NC}"
        echo -e "      出站: ${relay_info}"
        echo -e "      密码: ${CYAN}${password}${NC}"
        _print_node_share_lines "$password" "$link_ip" "$port" "$sn" "$name" "$cert_path" "      "
        echo ""
    done < <(jq -c 'to_entries[]' "$METADATA_FILE" 2>/dev/null)

    if [ "$idx" -eq 0 ]; then
        _warn "暂无节点。"
    elif [ -n "$filter" ] && [ "$matched" -eq 0 ]; then
        _warn "未找到匹配 '${filter}' 的节点。"
    fi
}

# ============================================================
# 删除节点
# ============================================================

_delete_node() {
    _info "--- 删除节点 ---"

    if [ ! -s "$METADATA_FILE" ] || [ "$(jq 'length' "$METADATA_FILE" 2>/dev/null)" == "0" ]; then
        _warn "暂无可删除的节点。"
        return
    fi

    # 列出节点
    local -a tags=()
    local -a names=()
    local idx=0
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        idx=$((idx + 1))
        local tag name port
        tag=$(printf '%s' "$entry" | jq -r '.key')
        name=$(printf '%s' "$entry" | jq -r '.value.name // "未命名"')
        port="${tag#*-in-}"
        tags+=("$tag")
        names+=("$name")
        echo -e "  ${GREEN}[${idx}]${NC} ${name} (端口: ${port})"
    done < <(jq -c 'to_entries[]' "$METADATA_FILE" 2>/dev/null)

    if [ "$idx" -eq 0 ]; then
        _warn "暂无可删除的节点。"
        return
    fi

    echo "  [0] 返回"
    read -p "请选择要删除的节点 [0-${idx}]: " choice

    if [ "$choice" == "0" ] || [ -z "$choice" ]; then
        return
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$idx" ]; then
        _error "无效选择"
        return 1
    fi

    local target_tag="${tags[$((choice-1))]}"
    local target_name="${names[$((choice-1))]}"
    local target_port="${target_tag#*-in-}"

    read -p "确认删除节点 [${target_name}] (端口: ${target_port})? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        _info "已取消。"
        return
    fi

    # 删除 inbound，以及关联的中转 outbound 和路由规则
    local relay_out_tag="relay-out-${target_port}"
    _atomic_modify_json "$CONFIG_FILE" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) |
        .outbounds = ((.outbounds // []) | map(select(.tag != $out_tag))) |
        if .route and .route.rules then
            .route.rules = (.route.rules | map(select((.inbound // []) | index($tag) | not)))
        else . end
    ' --arg tag "$target_tag" --arg out_tag "$relay_out_tag" || return 1

    # 删除 metadata
    _atomic_modify_json "$METADATA_FILE" 'del(.[$tag])' --arg tag "$target_tag" || return 1

    # 删除证书文件 (AnyTLS)
    if [[ "$target_tag" == anytls-in-* ]]; then
        rm -f "${SINGBOX_DIR}/${target_tag}.pem" "${SINGBOX_DIR}/${target_tag}.key"
    fi

    # 重启服务
    _manage_service restart
    _success "节点 [${target_name}] 已删除。"
}

# ============================================================
# 修改节点
# ============================================================

_modify_node() {
    _info "--- 修改 AnyTLS 节点 ---"

    if [ ! -s "$METADATA_FILE" ] || [ "$(jq 'length' "$METADATA_FILE" 2>/dev/null)" == "0" ]; then
        _warn "暂无可修改的节点。"
        return
    fi

    # 列出节点
    local -a tags=()
    local -a names=()
    local idx=0
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        idx=$((idx + 1))
        local tag name port
        tag=$(printf '%s' "$entry" | jq -r '.key')
        name=$(printf '%s' "$entry" | jq -r '.value.name // "未命名"')
        port="${tag#anytls-in-}"
        tags+=("$tag")
        names+=("$name")
        echo -e "  ${GREEN}[${idx}]${NC} ${name} (端口: ${port})"
    done < <(jq -c 'to_entries[] | select(.key | startswith("anytls-in-"))' "$METADATA_FILE" 2>/dev/null)

    if [ "$idx" -eq 0 ]; then
        _warn "暂无可修改的节点。"
        return
    fi

    echo "  [0] 返回"
    read -p "请选择要修改的节点 [0-${idx}]: " choice

    if [ "$choice" == "0" ] || [ -z "$choice" ]; then
        return
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$idx" ]; then
        _error "无效选择"
        return 1
    fi

    local target_tag="${tags[$((choice-1))]}"
    local target_name="${names[$((choice-1))]}"
    local old_port="${target_tag#anytls-in-}"

    echo ""
    echo "修改选项:"
    echo "  1) 修改端口"
    echo "  2) 修改密码"
    echo "  3) 修改 SNI"
    echo "  4) 修改节点名称"
    echo "  0) 返回"
    read -p "请选择 [0-4]: " mod_choice

    case "$mod_choice" in
        1)
            local new_port
            while true; do
                read -p "请输入新端口 (当前: ${old_port}): " new_port
                [ -z "$new_port" ] && { _warn "已取消"; return; }
                if [ "$new_port" == "$old_port" ]; then
                    _warn "端口未变化"
                    return
                fi
                if _check_port_conflict "$new_port"; then
                    continue
                fi
                break
            done

            local new_tag="anytls-in-${new_port}"
            local old_cert="${SINGBOX_DIR}/${target_tag}.pem"
            local old_key="${SINGBOX_DIR}/${target_tag}.key"
            local new_cert="${SINGBOX_DIR}/${new_tag}.pem"
            local new_key="${SINGBOX_DIR}/${new_tag}.key"

            local old_relay_out="relay-out-${old_port}"
            local new_relay_out="relay-out-${new_port}"

            # 更新 config.json: 修改 tag、端口、证书路径及中转出站/路由规则
            _atomic_modify_json "$CONFIG_FILE" '
                .inbounds |= map(
                    if .tag == $old_tag then
                        .tag = $new_tag |
                        .listen_port = ($new_port | tonumber) |
                        .tls.certificate_path = $new_cert |
                        .tls.key_path = $new_key
                    else . end
                ) |
                .outbounds |= map(
                    if .tag == $old_out then
                        .tag = $new_out
                    else . end
                ) |
                if .route and .route.rules then
                    .route.rules |= map(
                        if (.inbound // []) | index($old_tag) then
                            .inbound = [.inbound[] | if . == $old_tag then $new_tag else . end] |
                            .outbound = (if .outbound == $old_out then $new_out else .outbound end)
                        else . end
                    )
                else . end
            ' --arg old_tag "$target_tag" --arg new_tag "$new_tag" \
              --arg old_out "$old_relay_out" --arg new_out "$new_relay_out" \
              --arg new_port "$new_port" --arg new_cert "$new_cert" --arg new_key "$new_key" || return 1

            # 更新 metadata
            local meta_val
            meta_val=$(jq --arg tag "$target_tag" '.[$tag]' "$METADATA_FILE")
            _atomic_modify_json "$METADATA_FILE" 'del(.[$old]) | . + {($new): $val}' \
                --arg old "$target_tag" --arg new "$new_tag" --argjson val "$meta_val" || return 1

            # 重命名证书文件
            [ -f "$old_cert" ] && mv -f "$old_cert" "$new_cert"
            [ -f "$old_key" ] && mv -f "$old_key" "$new_key"

            _manage_service restart
            _success "端口已修改: ${old_port} → ${new_port}"
            ;;
        2)
            read -p "请输入新密码 (回车随机生成): " new_pw
            if [ -z "$new_pw" ]; then
                new_pw=$(_generate_uuid) || return 1
            fi

            _atomic_modify_json "$CONFIG_FILE" '
                .inbounds |= map(
                    if .tag == $tag then .users[0].password = $pw else . end
                )
            ' --arg tag "$target_tag" --arg pw "$new_pw" || return 1

            _atomic_modify_json "$METADATA_FILE" '.[$tag].password = $pw' \
                --arg tag "$target_tag" --arg pw "$new_pw" || return 1

            _manage_service restart
            _success "密码已修改"
            ;;
        3)
            local old_sn
            old_sn=$(jq -r --arg tag "$target_tag" '.[$tag].server_name // "unknown"' "$METADATA_FILE")
            read -p "请输入新 SNI (当前: ${old_sn}): " new_sn
            [ -z "$new_sn" ] && { _warn "已取消"; return; }

            # 重新生成证书
            local cert_path="${SINGBOX_DIR}/${target_tag}.pem"
            local key_path="${SINGBOX_DIR}/${target_tag}.key"
            _generate_self_signed_cert "$new_sn" "$cert_path" "$key_path" || return 1

            _atomic_modify_json "$METADATA_FILE" '.[$tag].server_name = $sn' \
                --arg tag "$target_tag" --arg sn "$new_sn" || return 1

            _manage_service restart
            _success "SNI 已修改: ${old_sn} → ${new_sn}"
            ;;
        4)
            read -p "请输入新节点名称 (当前: ${target_name}): " new_name
            [ -z "$new_name" ] && { _warn "已取消"; return; }

            _atomic_modify_json "$METADATA_FILE" '.[$tag].name = $name' \
                --arg tag "$target_tag" --arg name "$new_name" || return 1

            _success "节点名称已修改: ${target_name} → ${new_name}"
            ;;
        0) return ;;
        *) _error "无效选择" ;;
    esac
}

# ============================================================
# 服务管理菜单
# ============================================================

_show_logs() {
    local lines="${1:-30}"
    local follow="${2:-false}"
    [ -z "$INIT_SYSTEM" ] && _detect_init_system

    if [ -f "$LOG_FILE" ]; then
        if [ "$follow" == "true" ]; then
            tail -n "$lines" -f "$LOG_FILE"
        else
            tail -n "$lines" "$LOG_FILE"
        fi
    elif [ "$INIT_SYSTEM" == "systemd" ]; then
        if [ "$follow" == "true" ]; then
            journalctl -u sing-box -n "$lines" -f
        else
            journalctl -u sing-box --no-pager -n "$lines"
        fi
    else
        _warn "未找到日志文件"
    fi
}

_fix_config() {
    _info "--- 修复配置与服务 (fix) ---"
    _detect_init_system
    _setup_sb_alias
    mkdir -p "$SINGBOX_DIR"

    if [ ! -x "$SINGBOX_BIN" ]; then
        _error "sing-box 核心未安装或不可执行: $SINGBOX_BIN"
        return 1
    fi

    # 1. 检查并修复 config.json
    if [ ! -s "$CONFIG_FILE" ] || ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        if [ -f "$CONFIG_FILE" ]; then
            local bak="${CONFIG_FILE}.bak.$(date +%s)"
            cp -p "$CONFIG_FILE" "$bak" 2>/dev/null || true
            rm -f "$CONFIG_FILE"
            _warn "检测到损坏的 config.json，已备份至 ${bak} 并重新初始化。"
        fi
        _init_config
    fi
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true

    # 2. 检查并修复 metadata.json
    if [ ! -s "$METADATA_FILE" ] || ! jq empty "$METADATA_FILE" >/dev/null 2>&1; then
        if [ -f "$METADATA_FILE" ]; then
            local mbak="${METADATA_FILE}.bak.$(date +%s)"
            cp -p "$METADATA_FILE" "$mbak" 2>/dev/null || true
            _warn "检测到损坏的 metadata.json，已备份至 ${mbak} 并重建。"
        fi
        echo '{}' > "$METADATA_FILE"
    fi
    chmod 600 "$METADATA_FILE" 2>/dev/null || true

    # 3. 补全缺失的自签名证书，并同步 metadata.json 中缺失的节点
    local inbound tag itype port pw cert_path key_path sni
    while IFS= read -r inbound; do
        [ -n "$inbound" ] || continue
        tag=$(printf '%s' "$inbound" | jq -r '.tag // empty')
        itype=$(printf '%s' "$inbound" | jq -r '.type // empty')
        port=$(printf '%s' "$inbound" | jq -r '.listen_port // empty')
        [ -n "$tag" ] || continue

        if [ "$itype" == "anytls" ]; then
            cert_path=$(printf '%s' "$inbound" | jq -r '.tls.certificate_path // empty')
            key_path=$(printf '%s' "$inbound" | jq -r '.tls.key_path // empty')
            [ -z "$cert_path" ] && cert_path="${SINGBOX_DIR}/${tag}.pem"
            [ -z "$key_path" ] && key_path="${SINGBOX_DIR}/${tag}.key"
            sni=$(jq -r --arg tag "$tag" '.[$tag].server_name // empty' "$METADATA_FILE" 2>/dev/null)
            [ -z "$sni" ] && sni="$DEFAULT_SNI"

            if [ ! -s "$cert_path" ] || [ ! -s "$key_path" ]; then
                _warn "节点 [${tag}] 证书缺失，正在重新生成..."
                _generate_self_signed_cert "$sni" "$cert_path" "$key_path" || return 1
            fi
            chmod 600 "$cert_path" "$key_path" 2>/dev/null || true

            if ! jq -e --arg tag "$tag" 'has($tag)' "$METADATA_FILE" >/dev/null 2>&1; then
                pw=$(printf '%s' "$inbound" | jq -r '.users[0].password // ""')
                _atomic_modify_json "$METADATA_FILE" \
                    '. + {($tag): {name: $name, server_name: $sni, password: $pw}}' \
                    --arg tag "$tag" --arg name "AnyTLS-${port:-$tag}" --arg sni "$sni" --arg pw "$pw" || return 1
                _info "已补全 metadata.json 条目: ${tag}"
            fi
        elif [ "$itype" == "shadowsocks" ]; then
            if ! jq -e --arg tag "$tag" 'has($tag)' "$METADATA_FILE" >/dev/null 2>&1; then
                local method
                method=$(printf '%s' "$inbound" | jq -r '.method // "2022-blake3-aes-256-gcm"')
                pw=$(printf '%s' "$inbound" | jq -r '.password // ""')
                _atomic_modify_json "$METADATA_FILE" \
                    '. + {($tag): {name: $name, protocol: "shadowsocks", method: $m, password: $pw}}' \
                    --arg tag "$tag" --arg name "SS2022-${port:-$tag}" --arg m "$method" --arg pw "$pw" || return 1
                _info "已补全 metadata.json 条目: ${tag}"
            fi
        fi
    done < <(jq -c '.inbounds[]?' "$CONFIG_FILE" 2>/dev/null)

    # 4. 清理 metadata.json 中已不存在的孤立 tag，以及孤立的 relay-out-* 与路由规则
    _atomic_modify_json "$METADATA_FILE" '
        with_entries(select(.key as $k | ($tags | index($k)) != null))
    ' --argjson tags "$(jq -c '[.inbounds[]?.tag // empty]' "$CONFIG_FILE")" || return 1

    _atomic_modify_json "$CONFIG_FILE" '
        ([.inbounds[]?.tag // empty]) as $in_tags |
        ([.inbounds[]? | .listen_port | tostring | "relay-out-" + .]) as $valid_relay_outs |
        .outbounds = ((.outbounds // []) | map(
            select(((.tag // "") | startswith("relay-out-") | not) or ($valid_relay_outs | index(.tag) != null))
        )) |
        if .route and .route.rules then
            .route.rules = (.route.rules | map(
                select((.inbound // null) == null or ([.inbound[]? | select($in_tags | index(.) != null)] | length > 0))
            ))
        else . end
    ' || return 1

    # 5. 清理孤立证书文件
    local f base
    for f in "${SINGBOX_DIR}"/anytls-in-*.pem "${SINGBOX_DIR}"/anytls-in-*.key; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        base="${base%.*}"
        if ! jq -e --arg tag "$base" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
            rm -f -- "$f"
            _info "已清理孤立证书文件: $f"
        fi
    done

    # 6. 重建服务文件并校验重启
    if [ -n "$SERVICE_FILE" ]; then
        _create_service_file
    fi

    if ! "$SINGBOX_BIN" check -c "$CONFIG_FILE" 2>&1; then
        _error "sing-box 配置校验仍未通过，请检查 ${CONFIG_FILE}。"
        return 1
    fi

    _manage_service restart || return 1
    _success "配置与服务修复完成！"
}

_service_menu() {
    echo ""
    echo "  1) 启动 sing-box"
    echo "  2) 停止 sing-box"
    echo "  3) 重启 sing-box"
    echo "  4) 查看状态"
    echo "  5) 查看日志 (最后 30 行)"
    echo "  6) 修复配置与服务 (fix)"
    echo "  0) 返回"
    read -p "请选择 [0-6]: " choice

    case "$choice" in
        1) _manage_service start ;;
        2) _manage_service stop ;;
        3) _manage_service restart ;;
        4) _manage_service status ;;
        5) _show_logs 30 false ;;
        6) _fix_config ;;
        0) return ;;
        *) _error "无效选择" ;;
    esac
}

# ============================================================
# 更新 sing-box 核心
# ============================================================

_update_core() {
    _info "--- 更新 sing-box 核心 ---"

    local current_version=""
    if [ -x "$SINGBOX_BIN" ]; then
        current_version=$("$SINGBOX_BIN" version 2>/dev/null | sed -n 's/^sing-box version \([^[:space:]]*\).*/\1/p' | head -n 1)
        _info "当前版本: v${current_version:-未知}"
    else
        _info "sing-box 尚未安装"
    fi

    # 获取最新版本号
    local latest_tag
    latest_tag=$(curl -fsSL --max-time 10 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null)
    local latest_version="${latest_tag#v}"

    if [ -n "$current_version" ] && [ "$current_version" == "$latest_version" ]; then
        _success "已是最新版本 v${current_version}，无需更新。"
        return 0
    fi

    if [ -n "$latest_version" ]; then
        _info "最新版本: v${latest_version}"
    fi

    read -p "确认更新? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        _info "已取消。"
        return
    fi

    # 停止服务
    _manage_service stop 2>/dev/null || true
    sleep 1

    _install_sing_box || return 1

    # 重启
    if [ -s "$CONFIG_FILE" ]; then
        _manage_service start
    fi
    _success "sing-box 核心已更新完成"
}

# ============================================================
# 1对1 落地中转管理 (Shadowsocks 出站)
# ============================================================

# 解析 Shadowsocks 链接 (支持 SIP002 等标准格式)
_parse_ss_link() {
    local raw_link="$1"
    raw_link=$(echo "$raw_link" | xargs)
    [[ "$raw_link" =~ ^ss:// ]] || { _error "链接格式不正确，必须以 ss:// 开头"; return 1; }

    local content="${raw_link#ss://}"
    local fragment=""
    if [[ "$content" == *"#"* ]]; then
        fragment="${content#*#}"
        content="${content%%#*}"
    fi

    local node_name="SS-落地"
    if [ -n "$fragment" ]; then
        node_name=$(_url_decode "$fragment")
    fi

    local method="" password="" server="" server_port=""

    if [[ "$content" == *"@"* ]]; then
        # 格式 2: ss://BASE64(method:password)@server:port 或 明文 ss://method:password@server:port (常见于 SS2022)
        local userinfo="${content%%@*}"
        local server_part="${content#*@}"

        server_part="${server_part%%\/*}"
        server_part="${server_part%%\?*}"

        local decoded_userinfo=""
        if [[ "$userinfo" == *":"* ]] || [[ "$userinfo" == *"%3A"* ]] || [[ "$userinfo" == *"%3a"* ]]; then
            # 明文或 URL 编码的 method:password (例如 ss://2022-blake3-aes-128-gcm:key%3D@ip:port)
            decoded_userinfo=$(_url_decode "$userinfo")
        else
            # Base64 编码的 method:password
            local pad_len=$(( (4 - ${#userinfo} % 4) % 4 ))
            local padded_userinfo="$userinfo"
            local i
            for ((i=0; i<pad_len; i++)); do padded_userinfo+="="; done
            decoded_userinfo=$(printf '%s' "$padded_userinfo" | tr '_-' '/+' | base64 -d 2>/dev/null)
        fi

        if [[ ! "$decoded_userinfo" == *":"* ]]; then
            _error "解析用户信息失败 (格式无法识别或 base64 解码异常)"
            return 1
        fi
        method="${decoded_userinfo%%:*}"
        password="${decoded_userinfo#*:}"

        if [[ "$server_part" =~ ^\[(.*)\]:([0-9]+)$ ]]; then
            server="${BASH_REMATCH[1]}"
            server_port="${BASH_REMATCH[2]}"
        elif [[ "$server_part" =~ ^(.*):([0-9]+)$ ]]; then
            server="${BASH_REMATCH[1]}"
            server_port="${BASH_REMATCH[2]}"
        else
            _error "无法从链接中解析服务器与端口: ${server_part}"
            return 1
        fi
    else
        # 格式 1: ss://BASE64(method:password@server:port)
        local pad_len=$(( (4 - ${#content} % 4) % 4 ))
        local padded_content="$content"
        local i
        for ((i=0; i<pad_len; i++)); do padded_content+="="; done

        local decoded
        decoded=$(printf '%s' "$padded_content" | tr '_-' '/+' | base64 -d 2>/dev/null)
        if [[ ! "$decoded" == *"@"* ]] || [[ ! "$decoded" == *":"* ]]; then
            _error "解析 Base64 失败，无法识别完整的 method:password@server:port"
            return 1
        fi
        local userinfo="${decoded%%@*}"
        local server_part="${decoded#*@}"
        server_part="${server_part%%\/*}"
        server_part="${server_part%%\?*}"

        method="${userinfo%%:*}"
        password="${userinfo#*:}"

        if [[ "$server_part" =~ ^\[(.*)\]:([0-9]+)$ ]]; then
            server="${BASH_REMATCH[1]}"
            server_port="${BASH_REMATCH[2]}"
        elif [[ "$server_part" =~ ^(.*):([0-9]+)$ ]]; then
            server="${BASH_REMATCH[1]}"
            server_port="${BASH_REMATCH[2]}"
        else
            _error "无法从链接中解析服务器与端口: ${server_part}"
            return 1
        fi
    fi

    if [ -z "$method" ] || [ -z "$password" ] || [ -z "$server" ] || [ -z "$server_port" ]; then
        _error "缺少必要的 Shadowsocks 参数 (加密/密码/服务器/端口)"
        return 1
    fi

    PARSED_SS_METHOD="$method"
    PARSED_SS_PASSWORD="$password"
    PARSED_SS_SERVER="$server"
    PARSED_SS_PORT="$server_port"
    PARSED_SS_NAME="$node_name"
    return 0
}

_ensure_route_block() {
    [ -s "$CONFIG_FILE" ] || return 1
    _atomic_modify_json "$CONFIG_FILE" '
        if .route == null then
            .route = { "rules": [], "final": "direct-out" }
        else
            .route.rules = (.route.rules // []) |
            .route.final = (.route.final // "direct-out")
        end
    '
}

_bind_node_relay() {
    _info "--- 绑定/更换 AnyTLS 节点的落地中转 ---"

    if [ ! -s "$METADATA_FILE" ] || [ "$(jq 'length' "$METADATA_FILE" 2>/dev/null)" == "0" ]; then
        _warn "当前机器暂无 AnyTLS 节点，请先通过菜单 [1] 创建节点。"
        return 1
    fi

    local -a tags=()
    local -a names=()
    local -a ports=()
    local idx=0

    echo ""
    echo "请选择要绑定落地的 AnyTLS 节点:"
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        idx=$((idx + 1))
        local tag name port relay_status
        tag=$(printf '%s' "$entry" | jq -r '.key')
        name=$(printf '%s' "$entry" | jq -r '.value.name // "未命名"')
        port="${tag#anytls-in-}"
        local is_relayed
        is_relayed=$(printf '%s' "$entry" | jq -r '.value.relay.enabled // false')
        if [ "$is_relayed" == "true" ]; then
            local r_name
            r_name=$(printf '%s' "$entry" | jq -r '.value.relay.name // "SS"')
            relay_status="${YELLOW}[已中转 -> ${r_name}]${NC}"
        else
            relay_status="${CYAN}[直连出站]${NC}"
        fi
        tags+=("$tag")
        names+=("$name")
        ports+=("$port")
        echo -e "  ${GREEN}[${idx}]${NC} ${name} (端口: ${port}) ${relay_status}"
    done < <(jq -c 'to_entries[] | select(.key | startswith("anytls-in-"))' "$METADATA_FILE" 2>/dev/null)

    if [ "$idx" -eq 0 ]; then
        _warn "暂无可操作的 AnyTLS 节点。"
        return 1
    fi

    echo "  [0] 返回"
    read -p "请选择节点编号 [0-${idx}]: " choice
    if [ "$choice" == "0" ] || [ -z "$choice" ]; then
        return 0
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$idx" ]; then
        _error "无效选择"
        return 1
    fi

    local selected_tag="${tags[$((choice-1))]}"
    local selected_name="${names[$((choice-1))]}"
    local selected_port="${ports[$((choice-1))]}"
    local relay_out_tag="relay-out-${selected_port}"

    echo ""
    echo -e "已选择 AnyTLS 节点: ${GREEN}${selected_name}${NC} (端口: ${selected_port})"
    read -p "请粘贴落地的 Shadowsocks 分享链接 (ss://...): " input_ss_link

    if ! _parse_ss_link "$input_ss_link"; then
        return 1
    fi

    echo ""
    _info "已成功解析落地节点信息:"
    echo "==========================================="
    echo -e "  落地备注:   ${GREEN}${PARSED_SS_NAME}${NC}"
    echo -e "  落地服务器: ${CYAN}${PARSED_SS_SERVER}${NC}"
    echo -e "  落地端口:   ${CYAN}${PARSED_SS_PORT}${NC}"
    echo -e "  加密方式:   ${CYAN}${PARSED_SS_METHOD}${NC}"
    echo "==========================================="
    echo ""
    read -p "确认将 [${selected_name}] 1对1 绑定到该落地节点? (Y/n): " confirm_bind
    if [[ "$confirm_bind" == "n" || "$confirm_bind" == "N" ]]; then
        _info "已取消。"
        return 0
    fi

    _ensure_route_block || return 1

    local new_outbound_json
    new_outbound_json=$(jq -n \
        --arg tag "$relay_out_tag" \
        --arg server "$PARSED_SS_SERVER" \
        --arg port "$PARSED_SS_PORT" \
        --arg method "$PARSED_SS_METHOD" \
        --arg password "$PARSED_SS_PASSWORD" \
        '{
            "type": "shadowsocks",
            "tag": $tag,
            "server": $server,
            "server_port": ($port | tonumber),
            "method": $method,
            "password": $password
        }')

    local new_rule_json
    new_rule_json=$(jq -n \
        --arg in_tag "$selected_tag" \
        --arg out_tag "$relay_out_tag" \
        '{
            "inbound": [$in_tag],
            "outbound": $out_tag
        }')

    _atomic_modify_json "$CONFIG_FILE" '
        .outbounds = ((.outbounds // []) | map(select(.tag != $out_tag))) + [$new_out] |
        .route.rules = ((.route.rules // []) | map(select((.inbound // []) | index($in_tag) | not))) + [$new_rule]
    ' --arg out_tag "$relay_out_tag" --arg in_tag "$selected_tag" \
      --argjson new_out "$new_outbound_json" --argjson new_rule "$new_rule_json" || return 1

    local relay_meta
    relay_meta=$(jq -n \
        --arg name "$PARSED_SS_NAME" \
        --arg server "$PARSED_SS_SERVER" \
        --arg port "$PARSED_SS_PORT" \
        --arg method "$PARSED_SS_METHOD" \
        '{
            "enabled": true,
            "type": "shadowsocks",
            "name": $name,
            "server": $server,
            "port": ($port | tonumber),
            "method": $method
        }')

    _atomic_modify_json "$METADATA_FILE" '.[$tag].relay = $relay' \
        --arg tag "$selected_tag" --argjson relay "$relay_meta" || return 1

    # 重启服务并进行存活检查
    if ! _manage_service restart; then
        _error "中转规则应用后服务启动失败，正在回滚..."
        _atomic_modify_json "$CONFIG_FILE" '
            .outbounds = ((.outbounds // []) | map(select(.tag != $out_tag))) |
            .route.rules = ((.route.rules // []) | map(select((.inbound // []) | index($in_tag) | not)))
        ' --arg out_tag "$relay_out_tag" --arg in_tag "$selected_tag"
        _atomic_modify_json "$METADATA_FILE" 'del(.[$tag].relay)' --arg tag "$selected_tag"
        _manage_service restart >/dev/null 2>&1 || true
        return 1
    fi

    sleep 1
    if ! _check_port_occupied "$selected_port" "tcp"; then
        _error "中转生效后端口 ${selected_port} 未处于监听状态，正在回滚..."
        _atomic_modify_json "$CONFIG_FILE" '
            .outbounds = ((.outbounds // []) | map(select(.tag != $out_tag))) |
            .route.rules = ((.route.rules // []) | map(select((.inbound // []) | index($in_tag) | not)))
        ' --arg out_tag "$relay_out_tag" --arg in_tag "$selected_tag"
        _atomic_modify_json "$METADATA_FILE" 'del(.[$tag].relay)' --arg tag "$selected_tag"
        _manage_service restart >/dev/null 2>&1 || true
        return 1
    fi

    _success "AnyTLS 节点 [${selected_name}] 已成功绑定落地 [${PARSED_SS_NAME}]！"
    _info "客户端连接方式不变（直接连本机的 ${selected_name} 节点），流量将自动由本机转发至境外落地 Shadowsocks。"
}

_view_relay_status() {
    _info "--- AnyTLS 节点中转出站状态 ---"

    if [ ! -s "$METADATA_FILE" ] || [ "$(jq 'length' "$METADATA_FILE" 2>/dev/null)" == "0" ]; then
        _warn "暂无节点。"
        return 0
    fi

    local idx=0
    echo ""
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        idx=$((idx + 1))
        local tag name port is_relayed
        tag=$(printf '%s' "$entry" | jq -r '.key')
        name=$(printf '%s' "$entry" | jq -r '.value.name // "未命名"')
        port="${tag#anytls-in-}"
        is_relayed=$(printf '%s' "$entry" | jq -r '.value.relay.enabled // false')

        echo -e "  ${GREEN}[${idx}]${NC} ${name} (端口: ${port})"
        if [ "$is_relayed" == "true" ]; then
            local r_name r_server r_port r_method
            r_name=$(printf '%s' "$entry" | jq -r '.value.relay.name // "SS"')
            r_server=$(printf '%s' "$entry" | jq -r '.value.relay.server // ""')
            r_port=$(printf '%s' "$entry" | jq -r '.value.relay.port // ""')
            r_method=$(printf '%s' "$entry" | jq -r '.value.relay.method // ""')
            echo -e "      模式: ${GREEN}1对1 落地中转 (Shadowsocks)${NC}"
            echo -e "      落地: ${CYAN}${r_name}${NC} (${r_server}:${r_port}) [${r_method}]"
        else
            echo -e "      模式: ${CYAN}默认直连出站 (direct)${NC}"
        fi
        echo ""
    done < <(jq -c 'to_entries[] | select(.key | startswith("anytls-in-"))' "$METADATA_FILE" 2>/dev/null)
}

_unbind_node_relay() {
    _info "--- 解除 AnyTLS 节点落地中转 (恢复直连) ---"

    if [ ! -s "$METADATA_FILE" ] || [ "$(jq 'length' "$METADATA_FILE" 2>/dev/null)" == "0" ]; then
        _warn "暂无节点。"
        return 0
    fi

    local -a relayed_tags=()
    local -a relayed_names=()
    local -a relayed_ports=()
    local -a relayed_targets=()
    local idx=0

    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        local is_relayed
        is_relayed=$(printf '%s' "$entry" | jq -r '.value.relay.enabled // false')
        if [ "$is_relayed" == "true" ]; then
            idx=$((idx + 1))
            local tag name port r_name
            tag=$(printf '%s' "$entry" | jq -r '.key')
            name=$(printf '%s' "$entry" | jq -r '.value.name // "未命名"')
            port="${tag#anytls-in-}"
            r_name=$(printf '%s' "$entry" | jq -r '.value.relay.name // "SS"')
            relayed_tags+=("$tag")
            relayed_names+=("$name")
            relayed_ports+=("$port")
            relayed_targets+=("$r_name")
            echo -e "  ${GREEN}[${idx}]${NC} ${name} (端口: ${port}) -> ${YELLOW}[${r_name}]${NC}"
        fi
    done < <(jq -c 'to_entries[] | select(.key | startswith("anytls-in-"))' "$METADATA_FILE" 2>/dev/null)

    if [ "$idx" -eq 0 ]; then
        _info "当前没有任何节点绑定了中转，全部节点均为直连出站。"
        return 0
    fi

    echo "  [0] 返回"
    read -p "请选择要解除中转的节点 [0-${idx}]: " choice
    if [ "$choice" == "0" ] || [ -z "$choice" ]; then
        return 0
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$idx" ]; then
        _error "无效选择"
        return 1
    fi

    local target_tag="${relayed_tags[$((choice-1))]}"
    local target_name="${relayed_names[$((choice-1))]}"
    local target_port="${relayed_ports[$((choice-1))]}"
    local relay_out_tag="relay-out-${target_port}"

    read -p "确认解除 [${target_name}] 的中转并恢复直连出站? (y/N): " confirm_unbind
    if [[ "$confirm_unbind" != "y" && "$confirm_unbind" != "Y" ]]; then
        _info "已取消。"
        return 0
    fi

    _atomic_modify_json "$CONFIG_FILE" '
        .outbounds = ((.outbounds // []) | map(select(.tag != $out_tag))) |
        if .route and .route.rules then
            .route.rules = (.route.rules | map(select((.inbound // []) | index($in_tag) | not)))
        else . end
    ' --arg out_tag "$relay_out_tag" --arg in_tag "$target_tag" || return 1

    _atomic_modify_json "$METADATA_FILE" 'del(.[$tag].relay)' --arg tag "$target_tag" || return 1

    _manage_service restart
    _success "节点 [${target_name}] 已成功解除中转，恢复为默认直连出站。"
}

_relay_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}============================================${NC}"
        echo -e "${CYAN}       AnyTLS 简易中转${NC}"
        echo -e "${CYAN}============================================${NC}"
        echo "  1) 绑定/更换落地中转"
        echo "  2) 查看中转状态"
        echo "  3) 解除落地中转"
        echo "  0) 返回主菜单"
        echo ""
        read -p "请选择 [0-3]: " r_choice
        echo ""
        case "$r_choice" in
            1) _bind_node_relay ;;
            2) _view_relay_status ;;
            3) _unbind_node_relay ;;
            0) return ;;
            *) _error "无效选择" ;;
        esac
        echo ""
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# ============================================================
# 完全卸载
# ============================================================

_uninstall() {
    echo ""
    _warn "⚠️ 即将完全卸载 sing-box (AnyTLS) ！"
    echo "  将删除: sing-box 核心、所有配置、证书、服务文件"
    echo ""
    read -p "确认卸载? 输入 'yes' 继续: " confirm

    if [ "$confirm" != "yes" ]; then
        _info "已取消。"
        return
    fi

    _info "正在停止服务..."
    _manage_service stop 2>/dev/null || true

    [ -z "$INIT_SYSTEM" ] && _detect_init_system

    # 删除服务文件
    case "$INIT_SYSTEM" in
        systemd)
            systemctl disable sing-box >/dev/null 2>&1 || true
            rm -f "$SERVICE_FILE"
            systemctl daemon-reload
            ;;
        openrc)
            rc-update del sing-box default >/dev/null 2>&1 || true
            rm -f "$SERVICE_FILE"
            ;;
    esac

    # 删除配置、证书、元数据与快捷指令
    rm -rf "$SINGBOX_DIR"
    rm -f "$SINGBOX_BIN"
    rm -rf "$RUNTIME_DIR"
    rm -f "$LOG_FILE"
    rm -f /usr/local/bin/sb 2>/dev/null || true

    _success "sing-box (AnyTLS) 已完全卸载。"
}

# ============================================================
# -auto 一键部署模式
# ============================================================

_auto_deploy() {
    local auto_port="${1:-}"
    local auto_sni="${2:-$DEFAULT_SNI}"
    local auto_password="${3:-}"

    _check_root
    _detect_init_system
    _setup_sb_alias
    _init_server_ip
    if [ -z "$server_ip" ]; then
        _error "无法自动获取服务器公网 IP，部署中止。"
        return 1
    fi
    _install_dependencies

    # 安装 sing-box (如果未安装)
    if [ ! -f "$SINGBOX_BIN" ]; then
        _install_sing_box || exit 1
    fi

    # 初始化配置
    _init_config

    # 创建或刷新服务文件
    if [ -n "$SERVICE_FILE" ]; then
        _create_service_file
    fi

    # 随机端口或校验指定端口
    if [ -n "$auto_port" ]; then
        if _check_port_conflict "$auto_port"; then
            return 1
        fi
    else
        while true; do
            auto_port=$(_get_random_port)
            if ! _check_port_conflict "$auto_port" "true"; then
                break
            fi
        done
    fi

    # 随机密码
    if [ -z "$auto_password" ]; then
        auto_password=$(_generate_uuid) || return 1
    fi

    local name="AnyTLS-${auto_port}"
    _create_anytls_node "$server_ip" "$auto_port" "$auto_sni" "$auto_password" "$name"
}

_auto_deploy_ss2022() {
    local ss_port="${1:-}"
    local ss_password="${2:-}"
    local ss_name="${3:-}"

    _check_root
    _detect_init_system
    _setup_sb_alias
    _init_server_ip
    if [ -z "$server_ip" ]; then
        _error "无法自动获取服务器公网 IP，部署中止。"
        return 1
    fi
    _install_dependencies

    if [ ! -f "$SINGBOX_BIN" ]; then
        _install_sing_box || exit 1
    fi

    _init_config

    if [ -n "$SERVICE_FILE" ]; then
        _create_service_file
    fi

    if [ -n "$ss_port" ]; then
        if _check_port_conflict "$ss_port"; then
            return 1
        fi
    else
        while true; do
            ss_port=$(_get_random_port)
            if ! _check_port_conflict "$ss_port" "true"; then
                break
            fi
        done
    fi

    if [ -z "$ss_password" ]; then
        ss_password=$(openssl rand -base64 32 2>/dev/null)
        if [ -z "$ss_password" ]; then
            _error "生成 2022-blake3-aes-256-gcm 密钥失败"
            return 1
        fi
    fi

    [ -z "$ss_name" ] && ss_name="SS2022-${ss_port}"
    _create_ss2022_node "$server_ip" "$ss_port" "$ss_password" "$ss_name"
}

# ============================================================
# 首次安装 (交互式)
# ============================================================

_first_install() {
    _info "首次安装，正在初始化环境..."
    _install_dependencies
    _detect_init_system
    _setup_sb_alias
    _install_sing_box || exit 1
    _init_config

    # 创建服务文件
    if [ -n "$SERVICE_FILE" ]; then
        _create_service_file
    fi
    _success "环境初始化完成，现在可以创建节点了。"
}

# ============================================================
# 主菜单
# ============================================================

_show_menu() {
    clear 2>/dev/null || true
    echo -e "${CYAN}============================================${NC}"
    echo -e "${CYAN}    sing-box AnyTLS 管理脚本 v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo ""

    # 状态显示
    if [ -x "$SINGBOX_BIN" ]; then
        local ver
        ver=$("$SINGBOX_BIN" version 2>/dev/null | sed -n 's/^sing-box version \([^[:space:]]*\).*/\1/p' | head -n 1)
        if [ -n "$ver" ]; then
            echo -e "  sing-box 核心: ${GREEN}v${ver}${NC}"
        else
            echo -e "  sing-box 核心: ${YELLOW}已安装(执行受限/内存紧缺)${NC}"
        fi
    else
        echo -e "  sing-box 核心: ${RED}未安装${NC}"
    fi

    local node_count=0
    [ -s "$METADATA_FILE" ] && node_count=$(jq 'length' "$METADATA_FILE" 2>/dev/null || echo 0)
    echo -e "  节点数量: ${CYAN}${node_count}${NC}"

    # 服务状态
    [ -z "$INIT_SYSTEM" ] && _detect_init_system
    local status_text="${RED}未运行${NC}"
    case "$INIT_SYSTEM" in
        systemd)
            systemctl is-active sing-box >/dev/null 2>&1 && status_text="${GREEN}运行中${NC}"
            ;;
        openrc)
            rc-service sing-box status >/dev/null 2>&1 && status_text="${GREEN}运行中${NC}"
            ;;
        direct)
            _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN" && status_text="${GREEN}运行中${NC}"
            ;;
    esac
    echo -e "  服务状态: ${status_text}"

    echo ""
    echo -e "    ${GREEN}[1]${NC} 创建节点"
    echo -e "    ${GREEN}[2]${NC} 查看节点"
    echo -e "    ${GREEN}[3]${NC} 删除节点"
    echo -e "    ${GREEN}[4]${NC} 修改节点"
    echo -e "    ${GREEN}[5]${NC} 服务管理"
    echo -e "    ${GREEN}[6]${NC} 更新核心"
    echo -e "    ${GREEN}[7]${NC} 简易中转"
    echo -e "    ${RED}[8]${NC} 完全卸载"
    echo -e "    ${GREEN}[0]${NC} 退出"
    echo ""
}

_main_loop() {
    while true; do
        _show_menu
        read -p "请选择 [0-8]: " choice
        echo ""
        case "$choice" in
            1)
                if [ ! -x "$SINGBOX_BIN" ]; then
                    _first_install
                fi
                _add_anytls
                ;;
            2) _view_nodes ;;
            3) _delete_node ;;
            4) _modify_node ;;
            5) _service_menu ;;
            6) _update_core ;;
            7) _relay_menu ;;
            8) _uninstall; exit 0 ;;
            0) _info "退出。"; exit 0 ;;
            *) _error "无效选项" ;;
        esac
        echo ""
        read -n 1 -s -r -p "按任意键继续..."
    done
}

_setup_sb_alias() {
    if [ -w "/usr/local/bin" ] && [ -f "$SELF_SCRIPT_PATH" ]; then
        ln -sf "$SELF_SCRIPT_PATH" /usr/local/bin/sb 2>/dev/null || true
    fi
}

_show_help() {
    cat << 'HELP_EOF'
用法: sb [子命令] [参数]

常用子命令:
  (无参数)                  进入交互式管理菜单
  info | i | url | u [筛选] 查看节点信息与分享链接 (可按序号/端口/名称筛选)
  status | st               查看 sing-box 服务状态
  start | stop | restart    启动 / 停止 / 重启 sing-box 服务
  log | logs [-f] [行数]    查看运行日志 (-f 实时跟踪，默认最近 50 行)
  fix                       校验并修复 config.json、metadata.json、证书与服务
  update                    更新 sing-box 核心
  -auto [port] [sni] [pw]   一键自动部署 AnyTLS 节点
  -ss2022 [port] [pw] [名]  一键自动部署 SS2022 落地节点
  help | -h | --help        显示此帮助信息
HELP_EOF
}

# ============================================================
# 入口
# ============================================================

case "${1:-}" in
    help|h|-h|--help)
        _show_help
        exit 0
        ;;
esac

_check_root
_detect_init_system
_setup_sb_alias

case "${1:-}" in
    -auto|--auto)
        shift
        _auto_deploy "$@"
        exit $?
        ;;
    -ss2022|--ss2022)
        shift
        _auto_deploy_ss2022 "$@"
        exit $?
        ;;
    info|i|url|u)
        _view_nodes "${2:-}"
        exit $?
        ;;
    status|st)
        _manage_service status
        exit $?
        ;;
    start|stop|restart)
        _manage_service "$1"
        exit $?
        ;;
    log|logs)
        shift
        if [ "${1:-}" == "-f" ] || [ "${1:-}" == "follow" ]; then
            _show_logs "${2:-50}" "true"
        else
            _show_logs "${1:-50}" "false"
        fi
        exit $?
        ;;
    fix)
        _fix_config
        exit $?
        ;;
    update)
        _update_core
        exit $?
        ;;
    *)
        _init_server_ip
        # 检查是否首次运行（sing-box 未安装或异常）
        if [ ! -f "$SINGBOX_BIN" ]; then
            echo ""
            _warn "sing-box 核心尚未安装。"
            read -p "是否现在安装? (Y/n): " install_confirm
            if [[ "$install_confirm" != "n" && "$install_confirm" != "N" ]]; then
                _first_install
            fi
        else
            # 核心文件存在，做一次探活检查
            test_out=$("$SINGBOX_BIN" version 2>&1)
            test_rc=$?
            if [ $test_rc -ne 0 ]; then
                _error "sing-box 核心文件存在 (${SINGBOX_BIN}) 但无法正常执行！(退出码: ${test_rc})"
                if [ $test_rc -eq 137 ] || [[ "$test_out" =~ "Killed" ]]; then
                    _error "原因：进程被操作系统内核直接杀死 (Killed)！机器可用内存不足或超出容器限制。"
                else
                    _error "错误信息: ${test_out}"
                fi
                read -p "是否尝试重新下载安装核心? (y/N): " reinstall_confirm
                if [[ "$reinstall_confirm" == "y" || "$reinstall_confirm" == "Y" ]]; then
                    _install_sing_box
                fi
            fi
        fi
        _main_loop
        ;;
esac
