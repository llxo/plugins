#!/bin/sh

# ========================================
# Alpine / Busybox 环境自检测与自举
# ========================================
if [ -z "$BASH_VERSION" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    elif command -v apk >/dev/null 2>&1; then
        echo "检测到 Alpine 系统未安装 bash，正在安装基础组件..."
        apk update && apk add --no-cache bash curl wget tar ca-certificates
        exec bash "$0" "$@"
    else
        echo "错误：当前环境缺少 bash，请先安装 bash 后再运行此脚本！"
        exit 1
    fi
fi

# ========================================
# 全局配置
# ========================================
REALM_DIR="/root/realm"
CONFIG_FILE="$REALM_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
OPENRC_SERVICE_FILE="/etc/init.d/realm"
LOG_FILE="/var/log/realm_manager.log"

# ========================================
# 颜色定义
# ========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ========================================
# 系统与架构检测
# ========================================
detect_system() {
    # 架构识别
    local arch_raw
    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64|amd64)
            ARCH="x86_64"
            ;;
        aarch64|arm64)
            ARCH="aarch64"
            ;;
        armv7*|armhf)
            ARCH="armv7"
            ;;
        arm*)
            ARCH="arm"
            ;;
        *)
            ARCH="x86_64"
            ;;
    esac

    # libc 识别 (GNU vs Musl)
    LIBC="gnu"
    if [ -f /etc/alpine-release ] || ldd --version 2>&1 | grep -iq musl || ls -d /lib/ld-musl* &>/dev/null; then
        LIBC="musl"
    fi

    # Init 服务管理系统识别 (systemd vs openrc)
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null || [ -f /sbin/openrc-run ] || [ -f /etc/alpine-release ]; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="openrc"
    fi
}

# ========================================
# 初始化检查
# ========================================
init_check() {
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}✖ 必须使用root权限运行本脚本${NC}"
        exit 1
    fi

    detect_system

    # 检查基础依赖
    local missing_pkgs=()
    for cmd in curl wget tar; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_pkgs+=("$cmd")
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        echo -e "${YELLOW}▶ 正在安装依赖工具: ${missing_pkgs[*]}...${NC}"
        if command -v apk &>/dev/null; then
            apk update && apk add --no-cache "${missing_pkgs[@]}" ca-certificates bash
        elif command -v apt-get &>/dev/null; then
            apt-get update && apt-get install -y "${missing_pkgs[@]}" ca-certificates
        elif command -v yum &>/dev/null; then
            yum install -y "${missing_pkgs[@]}" ca-certificates
        elif command -v dnf &>/dev/null; then
            dnf install -y "${missing_pkgs[@]}" ca-certificates
        else
            echo -e "${RED}✖ 无法自动安装依赖，请手动安装: ${missing_pkgs[*]}${NC}"
            exit 1
        fi
    fi

    # 创建必要目录
    mkdir -p "$REALM_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE" 2>/dev/null || true

    log "脚本启动 (系统: $INIT_SYSTEM, libc: $LIBC, 架构: $ARCH)"
}

# ========================================
# 日志系统
# ========================================
log() {
    local log_msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$log_msg" >> "$LOG_FILE" 2>/dev/null || true
}

# ========================================
# 服务状态及控制
# ========================================
check_service_status() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl is-active --quiet realm 2>/dev/null
        return $?
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        if command -v rc-service &>/dev/null; then
            rc-service realm status 2>/dev/null | grep -q "status: started"
            return $?
        else
            pgrep -x realm &>/dev/null
            return $?
        fi
    else
        pgrep -x realm &>/dev/null
        return $?
    fi
}

service_control() {
    case $1 in
        start)
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                systemctl unmask realm.service 2>/dev/null
                systemctl daemon-reload 2>/dev/null
                systemctl restart realm.service
                systemctl enable realm.service 2>/dev/null
            else
                rc-service realm start 2>/dev/null || rc-service realm restart
                rc-update add realm default 2>/dev/null
            fi
            log "启动服务"
            echo -e "${GREEN}✔ 服务已启动${NC}"
            ;;
        stop)
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                systemctl stop realm 2>/dev/null
            else
                rc-service realm stop 2>/dev/null
            fi
            log "停止服务"
            echo -e "${YELLOW}⚠ 服务已停止${NC}"
            ;;
        restart)
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                systemctl unmask realm.service 2>/dev/null
                systemctl daemon-reload 2>/dev/null
                systemctl restart realm.service
                systemctl enable realm.service 2>/dev/null
            else
                rc-service realm restart 2>/dev/null || rc-service realm start
                rc-update add realm default 2>/dev/null
            fi
            log "重启服务"
            echo -e "${GREEN}✔ 服务已重启${NC}"
            ;;
        status)
            if check_service_status; then
                echo -e "${GREEN}● 服务运行中${NC}"
            else
                echo -e "${RED}● 服务未运行${NC}"
            fi
            ;;
    esac
}

# ========================================
# 核心功能模块
# ========================================
deploy_realm() {
    log "开始安装Realm"
    echo -e "${BLUE}▶ 正在安装Realm...${NC}"
    detect_system
    
    mkdir -p "$REALM_DIR"
    cd "$REALM_DIR" || exit 1

    # 获取最新版本号
    echo -e "${BLUE}▶ 正在检测最新版本...${NC}"
    LATEST_VERSION=$(curl -sL --connect-timeout 5 "https://api.github.com/repos/zhboner/realm/releases/latest" 2>/dev/null | grep '"tag_name":' | head -n1 | sed -E 's/.*"v([^"]+)".*/\1/')
    if [[ -z "$LATEST_VERSION" ]]; then
        LATEST_VERSION=$(curl -sL --connect-timeout 5 https://github.com/zhboner/realm/releases 2>/dev/null | grep -oE '/zhboner/realm/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | cut -d'/' -f6 | tr -d 'v')
    fi
    
    # 版本号验证
    if [[ -z "$LATEST_VERSION" || ! "$LATEST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "版本检测失败，使用备用版本2.9.6"
        LATEST_VERSION="2.9.6"
        echo -e "${YELLOW}⚠ 无法获取最新版本，使用备用版本 v${LATEST_VERSION}${NC}"
    else
        echo -e "${GREEN}✓ 检测到最新版本 v${LATEST_VERSION}${NC}"
    fi

    # 动态匹配架构与 libc 对应的资产文件
    local asset_name=""
    if [[ "$LIBC" == "musl" ]]; then
        case "$ARCH" in
            x86_64)  asset_name="realm-x86_64-unknown-linux-musl.tar.gz" ;;
            aarch64) asset_name="realm-aarch64-unknown-linux-musl.tar.gz" ;;
            armv7)   asset_name="realm-armv7-unknown-linux-musleabihf.tar.gz" ;;
            arm)     asset_name="realm-arm-unknown-linux-musleabi.tar.gz" ;;
            *)       asset_name="realm-x86_64-unknown-linux-musl.tar.gz" ;;
        esac
    else
        case "$ARCH" in
            x86_64)  asset_name="realm-x86_64-unknown-linux-gnu.tar.gz" ;;
            aarch64) asset_name="realm-aarch64-unknown-linux-gnu.tar.gz" ;;
            armv7)   asset_name="realm-armv7-unknown-linux-gnueabihf.tar.gz" ;;
            arm)     asset_name="realm-arm-unknown-linux-gnueabi.tar.gz" ;;
            *)       asset_name="realm-x86_64-unknown-linux-gnu.tar.gz" ;;
        esac
    fi

    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/v${LATEST_VERSION}/${asset_name}"
    echo -e "${BLUE}▶ 适配系统环境: ${GREEN}${ARCH} / ${LIBC} (${INIT_SYSTEM})${NC}"
    echo -e "${BLUE}▶ 正在下载: ${asset_name}...${NC}"

    rm -f realm.tar.gz realm
    if ! wget --timeout=15 -qO realm.tar.gz "$DOWNLOAD_URL"; then
        echo -e "${YELLOW}⚠ 尝试通过加速镜像下载...${NC}"
        if ! wget --timeout=15 -qO realm.tar.gz "https://ghfast.top/${DOWNLOAD_URL}"; then
            log "安装失败：下载错误 $DOWNLOAD_URL"
            echo -e "${RED}✖ 文件下载失败，请检查网络连接！${NC}"
            return 1
        fi
    fi

    # 解压安装
    tar -xzf realm.tar.gz 2>/dev/null
    chmod +x realm
    rm -f realm.tar.gz

    # 二进制执行验证
    if ! ./realm --version >/dev/null 2>&1; then
        echo -e "${RED}✖ 二进制文件校验失败，可能架构不匹配！${NC}"
        log "二进制执行校验失败"
        return 1
    fi

    # 初始化配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<'EOF'
[network]
no_tcp = false
use_udp = true
EOF
    fi

    # 创建系统服务文件
    echo -e "${BLUE}▶ 创建系统服务 (${INIT_SYSTEM})...${NC}"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm Proxy Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$REALM_DIR/realm -c $CONFIG_FILE
Restart=always
RestartSec=2s
LimitNOFILE=65535
User=root

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable realm.service 2>/dev/null
    else
        # OpenRC 服务配置
        cat > "$OPENRC_SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="realm"
description="Realm Proxy Service"
command="$REALM_DIR/realm"
command_args="-c $CONFIG_FILE"
command_background="yes"
pidfile="/run/realm.pid"
respawn="yes"
respawn_delay=2
respawn_max=0

depend() {
    need net
    after firewall
}
EOF
        chmod +x "$OPENRC_SERVICE_FILE"
        rc-update add realm default 2>/dev/null
    fi

    service_control restart >/dev/null
    log "安装成功"
    echo -e "${GREEN}✔ 安装完成！${NC}"
}

# 查看转发规则
show_rules() {
    echo -e "                   ${YELLOW}当前 Realm 转发规则${NC}                   "
    echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}${YELLOW}"
    printf "%-5s| %-30s| %-40s| %-20s\n" "序号" "   本地地址:端口 " "   目标地址:端口 " "备注"
    echo -e "${NC}${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "未找到配置文件 $CONFIG_FILE"
        return
    fi

    local lines=($(grep -n 'listen =' "$CONFIG_FILE"))
    if [ ${#lines[@]} -eq 0 ]; then
        echo -e "没有发现任何转发规则。"
        return
    fi

    local index=1
    for line in "${lines[@]}"; do
        local line_number=$(echo "$line" | cut -d ':' -f 1)
        local listen_info=$(sed -n "${line_number}p" "$CONFIG_FILE" | cut -d '"' -f 2)
        local remote_info=$(sed -n "$((line_number + 1))p" "$CONFIG_FILE" | cut -d '"' -f 2)
        local remark=$(sed -n "$((line_number - 1))p" "$CONFIG_FILE" | grep "^# 备注:" | cut -d ':' -f 2)
        
        printf "%-4s| %-24s| %-34s| %-20s\n" " $index" "$listen_info" "$remote_info" "$remark"
        echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
        let index+=1
    done
}

# 添加转发规则
add_rule() {
    log "添加转发规则"
    while : ; do
        echo -e "\n${BLUE}▶ 添加新规则（输入 q 退出）${NC}"
        
        # 获取输入
        read -rp "本地监听端口: " local_port
        [ "$local_port" = "q" ] && break
        read -rp "目标服务器IP: " remote_ip
        read -rp "目标端口: " remote_port
        read -rp "规则备注: " remark

        # 输入验证
        if ! [[ "$local_port" =~ ^[0-9]+$ ]] || ! [[ "$remote_port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}✖ 端口必须为数字！${NC}"
            continue
        fi

        # 监听模式选择
        echo -e "\n${YELLOW}请选择监听模式：${NC}"
        echo "1) 双栈监听 [::]:${local_port} (默认)"
        echo "2) 仅IPv4监听 0.0.0.0:${local_port}"
        echo "3) 自定义监听地址"
        read -rp "请输入选项 [1-3] (默认1): " ip_choice
        ip_choice=${ip_choice:-1}

        case $ip_choice in
            1)
                listen_addr="[::]:$local_port"
                desc="双栈监听"
                ;;
            2)
                listen_addr="0.0.0.0:$local_port"
                desc="仅IPv4"
                ;;
            3)
                while : ; do
                    read -rp "请输入完整监听地址(格式如 0.0.0.0:80 或 [::]:443): " listen_addr
                    if ! [[ "$listen_addr" =~ ^([0-9a-fA-F.:]+|\[.*\]):[0-9]+$ ]]; then
                        echo -e "${RED}✖ 格式错误！示例: 0.0.0.0:80 或 [::]:443${NC}"
                        continue
                    fi
                    break
                done
                desc="自定义监听"
                ;;
            *)
                echo -e "${RED}无效选择，使用默认值！${NC}"
                listen_addr="[::]:$local_port"
                desc="双栈监听"
                ;;
        esac

        # 写入配置文件
        cat >> "$CONFIG_FILE" <<EOF

[[endpoints]]
# 备注: $remark 
listen = "$listen_addr"
remote = "$remote_ip:$remote_port"
EOF

        # 双栈提示
        if [ "$ip_choice" -eq 1 ]; then
            echo -e "\n${CYAN}ℹ 双栈监听需要确保：${NC}"
            echo -e "${CYAN}   - Realm 配置中 [network] 段的 ipv6_only = false${NC}"
            echo -e "${CYAN}   - 系统已启用 IPv6 双栈支持 (sysctl net.ipv6.bindv6only=0)${NC}"
        fi

        # 重启服务
        service_control restart >/dev/null
        log "规则已添加: $listen_addr → $remote_ip:$remote_port"
        echo -e "${GREEN}✔ 添加成功！${NC}"
        
        read -rp "继续添加？(y/n): " cont
        [[ "$cont" != "y" ]] && break
    done
}

# 删除转发规则
delete_rule() {
    echo -e "                   ${YELLOW}当前 Realm 转发规则${NC}                   "
    echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}${YELLOW}"
    printf "%-5s| %-30s| %-40s| %-20s\n" "序号" "   本地地址:端口 " "   目标地址:端口 " "备注"
    echo -e "${NC}${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "未找到配置文件。"
        return
    fi

    local lines=($(grep -n '^\[\[endpoints\]\]' "$CONFIG_FILE"))
    if [ ${#lines[@]} -eq 0 ]; then
        echo "没有发现任何转发规则。"
        return
    fi

    local index=1
    for line in "${lines[@]}"; do
        local line_number=$(echo "$line" | cut -d ':' -f 1)
        local remark_line=$((line_number + 1))
        local listen_line=$((line_number + 2))
        local remote_line=$((line_number + 3))

        local remark=$(sed -n "${remark_line}p" "$CONFIG_FILE" | grep "^# 备注:" | cut -d ':' -f 2)
        local listen_info=$(sed -n "${listen_line}p" "$CONFIG_FILE" | cut -d '"' -f 2)
        local remote_info=$(sed -n "${remote_line}p" "$CONFIG_FILE" | cut -d '"' -f 2)

        printf "%-4s| %-24s| %-34s| %-20s\n" " $index" "$listen_info" "$remote_info" "$remark"
        echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
        let index+=1
    done

    echo "请输入要删除的转发规则序号，直接按回车返回主菜单。"
    read -rp "选择: " choice
    if [ -z "$choice" ]; then
        echo "返回主菜单。"
        return
    fi

    if ! [[ $choice =~ ^[0-9]+$ ]]; then
        echo "无效输入，请输入数字。"
        return
    fi

    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#lines[@]}" ]; then
        echo "选择超出范围，请输入有效序号。"
        return
    fi

    local chosen_line=${lines[$((choice - 1))]}
    local start_line=$(echo "$chosen_line" | cut -d ':' -f 1)

    local next_endpoints_line=$(grep -n '^\[\[endpoints\]\]' "$CONFIG_FILE" | grep -A 1 "^$start_line:" | tail -n 1 | cut -d ':' -f 1)

    local end_line
    if [ -z "$next_endpoints_line" ] || [ "$next_endpoints_line" -le "$start_line" ]; then
        end_line=$(wc -l < "$CONFIG_FILE")
    else
        end_line=$((next_endpoints_line - 1))
    fi

    sed -i "${start_line},${end_line}d" "$CONFIG_FILE"
    sed -i '/^[[:space:]]*$/d' "$CONFIG_FILE"

    echo "转发规则及其备注已删除。"
    service_control restart >/dev/null
    echo -e "${GREEN}✔ 规则已删除，服务已重启生效！${NC}"
}

# 定时任务管理
manage_cron() {
    echo -e "\n${YELLOW}定时任务管理：${NC}"
    echo "1. 添加每日重启任务"
    echo "2. 删除所有任务"
    echo "3. 查看当前任务"
    read -rp "请选择: " choice

    local restart_cmd
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        restart_cmd="systemctl restart realm"
    else
        restart_cmd="rc-service realm restart"
    fi

    case $choice in
        1)
            read -rp "输入每日重启时间 (0-23): " hour
            if [[ "$hour" =~ ^[0-9]+$ ]] && (( hour >= 0 && hour <= 23 )); then
                if command -v crontab &>/dev/null; then
                    (crontab -l 2>/dev/null | grep -v "realm"; echo "0 $hour * * * $restart_cmd") | crontab -
                fi
                if [ -f /etc/crontab ]; then
                    sed -i "/realm/d" /etc/crontab 2>/dev/null || true
                    echo "0 $hour * * * root $restart_cmd" >> /etc/crontab
                fi
                log "添加定时任务：每日 $hour 时重启 ($restart_cmd)"
                echo -e "${GREEN}✔ 定时任务已添加！${NC}"
            else
                echo -e "${RED}✖ 无效时间！${NC}"
            fi
            ;;
        2)
            if command -v crontab &>/dev/null; then
                (crontab -l 2>/dev/null | grep -v "realm") | crontab - 2>/dev/null || true
            fi
            if [ -f /etc/crontab ]; then
                sed -i "/realm/d" /etc/crontab 2>/dev/null || true
            fi
            log "清除定时任务"
            echo -e "${YELLOW}✔ 定时任务已清除！${NC}"
            ;;
        3)
            echo -e "\n${BLUE}当前定时任务：${NC}"
            if command -v crontab &>/dev/null; then
                crontab -l 2>/dev/null | grep --color=auto "realm" || true
            fi
            if [ -f /etc/crontab ]; then
                grep --color=auto "realm" /etc/crontab 2>/dev/null || true
            fi
            ;;
        *)
            echo -e "${RED}✖ 无效选择！${NC}"
            ;;
    esac
}

# 完全卸载
uninstall() {
    log "开始卸载"
    echo -e "${YELLOW}▶ 正在卸载...${NC}"
    
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop realm 2>/dev/null
        systemctl disable realm 2>/dev/null
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload 2>/dev/null
    else
        rc-service realm stop 2>/dev/null
        rc-update del realm default 2>/dev/null
        rm -f "$OPENRC_SERVICE_FILE"
    fi

    rm -rf "$REALM_DIR"
    rm -f "$0" 2>/dev/null || true
    
    if command -v crontab &>/dev/null; then
        (crontab -l 2>/dev/null | grep -v "realm") | crontab - 2>/dev/null || true
    fi
    if [ -f /etc/crontab ]; then
        sed -i "/realm/d" /etc/crontab 2>/dev/null || true
    fi
    
    log "卸载完成"
    echo -e "${GREEN}✔ 已完全卸载！${NC}"
}

# 安装状态检测
check_installed() {
    local installed=false
    if [[ -f "$REALM_DIR/realm" ]]; then
        if [[ "$INIT_SYSTEM" == "systemd" && -f "$SERVICE_FILE" ]]; then
            installed=true
        elif [[ "$INIT_SYSTEM" == "openrc" && -f "$OPENRC_SERVICE_FILE" ]]; then
            installed=true
        fi
    fi

    if $installed; then
        echo -e "${GREEN}已安装${NC}"
    else
        echo -e "${RED}未安装${NC}"
    fi
}

# ========================================
# 主界面
# ========================================
main_menu() {
    clear
    init_check

    while true; do
        echo -e "${YELLOW}▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂${NC}"
        echo -e "  "
        echo -e "                ${BLUE}Realm 管理脚本${NC}"
        echo -e "        ${CYAN}适配支持：Debian / Ubuntu / CentOS / Alpine${NC}"
        echo -e "        ${CYAN}架构支持：x86_64 / aarch64 / armv7 (glibc & musl)${NC}"
        echo -e "        仓库：https://github.com/qqrrooty/EZrealm"
        echo -e "${YELLOW}▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂${NC}"
        echo -e "  "
        echo -e "${YELLOW}系统环境：$INIT_SYSTEM | $LIBC | $ARCH${NC}"
        echo -e "${YELLOW}服务状态：$(service_control status)${NC}"
        echo -e "${YELLOW}安装状态：$(check_installed)${NC}"
        echo -e "  "
        echo -e "${YELLOW}------------------${NC}"
        echo "1. 安装/更新 Realm"
        echo -e "${YELLOW}------------------${NC}"
        echo "2. 添加转发规则"
        echo "3. 查看转发规则"
        echo "4. 删除转发规则"
        echo -e "${YELLOW}------------------${NC}"
        echo "5. 启动服务"
        echo "6. 停止服务"
        echo "7. 重启服务"
        echo -e "${YELLOW}------------------${NC}"
        echo "8. 定时任务管理"
        echo "9. 查看日志"
        echo -e "${YELLOW}------------------${NC}"
        echo "10. 完全卸载"
        echo -e "${YELLOW}------------------${NC}"
        echo "0. 退出脚本"
        echo -e "${YELLOW}------------------${NC}"

        read -rp "请输入选项: " choice
        case $choice in
            1) deploy_realm ;;
            2) add_rule ;;
            3) show_rules ;;
            4) delete_rule ;;
            5) service_control start ;;
            6) service_control stop ;;
            7) service_control restart ;;
            8) manage_cron ;;
            9) 
                echo -e "\n${BLUE}最近日志：${NC}"
                tail -n 10 "$LOG_FILE" 2>/dev/null || echo "暂无日志"
                ;;
            10) 
                read -rp "确认完全卸载？(y/n): " confirm
                if [[ "$confirm" == "y" ]]; then
                    uninstall
                    read -rp "按回车键继续..."
                    clear
                    exit 0
                fi
                ;;
            0) exit 0 
            ;;
            *) echo -e "${RED}无效选项！${NC}" ;;
        esac
        read -rp "按回车键继续..."
        clear
    done
}

# ========================================
# 脚本入口
# ========================================
main_menu "$@"
