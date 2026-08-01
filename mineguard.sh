#!/bin/bash
# ============================================================================
# MineGuard - 轻量级服务器监控 & 挖矿检测守护进程
#
# 主程序入口
#
# 灵感来源:
#   - russellgrapes/telegram-bash-system-monitoring
#   - alfiosalanitri/server-guardian
#   - VertexElite/server-security-toolkit
#
# 特性:
#   - 极低资源占用（纯 Bash，~2MB RSS）
#   - x86 / ARM 完全兼容
#   - CPU / 内存 / Swap 监控
#   - 挖矿进程多维度检测（进程名/路径/行为/网络/crontab）
#   - 持续高 CPU 过滤（避免误报）
#   - Telegram / Webhook / Email 多通道告警
#   - 告警冷却 & 速率限制（防轰炸）
#   - systemd 服务集成
#
# 用法:
#   mineguard start       - 前台启动（调试用）
#   mineguard daemon      - 后台守护进程模式
#   mineguard stop        - 停止守护进程
#   mineguard status      - 查看运行状态
#   mineguard check       - 执行一次检查（不进入循环）
#   mineguard test-notify - 测试通知渠道
#   mineguard version     - 显示版本
# ============================================================================

set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------------------------------------------------------
# 加载配置和模块
# ----------------------------------------------------------------------------
load_config() {
    local config_file="${1:-}"

    # 配置文件查找顺序
    local config_paths=(
        "$config_file"
        "/etc/mineguard/config.conf"
        "${SCRIPT_DIR}/config.conf"
        "$HOME/.mineguard/config.conf"
    )

    local loaded=0
    for cfg in "${config_paths[@]}"; do
        if [ -n "$cfg" ] && [ -f "$cfg" ]; then
            # shellcheck source=/dev/null
            source "$cfg"
            loaded=1
            echo "配置文件: $cfg"
            break
        fi
    done

    if [ "$loaded" -eq 0 ]; then
        echo "错误: 未找到配置文件"
        echo "查找路径: ${config_paths[*]}"
        exit 1
    fi
}

load_modules() {
    local lib_paths=(
        "/etc/mineguard/lib"
        "${SCRIPT_DIR}/lib"
    )

    local lib_dir=""
    for path in "${lib_paths[@]}"; do
        if [ -d "$path" ]; then
            lib_dir="$path"
            break
        fi
    done

    if [ -z "$lib_dir" ]; then
        echo "错误: 未找到 lib 目录"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "${lib_dir}/utils.sh"
    # shellcheck source=/dev/null
    source "${lib_dir}/notify.sh"
    # shellcheck source=/dev/null
    source "${lib_dir}/cpu.sh"
    # shellcheck source=/dev/null
    source "${lib_dir}/memory.sh"
    # shellcheck source=/dev/null
    source "${lib_dir}/process.sh"
}

# ----------------------------------------------------------------------------
# 信号处理
# ----------------------------------------------------------------------------
cleanup() {
    log_info "MineGuard 正在停止..."
    rm -f "$PID_FILE" 2>/dev/null

    # 发送停止通知
    local host
    host=$(get_hostname)
    if [ "$TELEGRAM_ENABLED" = "1" ] || [ "$WEBHOOK_ENABLED" = "1" ]; then
        send_alert "INFO" "MineGuard 已停止" \
"监控服务已在 ${host} 上停止运行。
⚠️ 服务器当前未受监控保护。"
    fi

    exit 0
}

# ----------------------------------------------------------------------------
# 单次检查循环
# ----------------------------------------------------------------------------
run_check() {
    log_debug "━━━ 开始检查 ━━━"

    # 1. CPU 检查
    check_cpu

    # 2. 内存检查
    check_memory

    # 3. 挖矿检测
    check_mining

    log_debug "━━━ 检查完成 ━━━"
}

# ----------------------------------------------------------------------------
# 主监控循环
# ----------------------------------------------------------------------------
run_monitor() {
    log_info "MineGuard v${VERSION} 启动"
    log_info "主机: $(get_hostname) | 架构: $(get_arch) | 内核: $(get_kernel)"
    log_info "检查间隔: ${CHECK_INTERVAL}s"
    log_info "CPU 阈值: 告警=${CPU_WARN_THRESHOLD}% 严重=${CPU_CRIT_THRESHOLD}%"
    log_info "内存阈值: 告警=${MEM_WARN_THRESHOLD}% 严重=${MEM_CRIT_THRESHOLD}%"
    log_info "挖矿检测: 进程名=${MINING_NAME_DETECT} 网络=${MINING_NET_DETECT}"

    # 加载挖矿签名
    load_mining_signatures

    # 发送启动通知
    local host
    host=$(get_hostname)
    local ip
    ip=$(get_ip_address)
    local arch
    arch=$(get_arch)

    send_alert "INFO" "MineGuard 监控已启动" \
"🖥 主机: ${host}
🌐 IP: ${ip:-未知}
📐 架构: ${arch}
🐧 内核: $(get_kernel)
⏱ 检查间隔: ${CHECK_INTERVAL}s
📊 CPU 阈值: 告警=${CPU_WARN_THRESHOLD}% / 严重=${CPU_CRIT_THRESHOLD}%
💾 内存阈值: 告警=${MEM_WARN_THRESHOLD}% / 严重=${MEM_CRIT_THRESHOLD}%"

    # 主循环
    while true; do
        run_check
        sleep "$CHECK_INTERVAL"
    done
}

# ----------------------------------------------------------------------------
# 守护进程模式
# ----------------------------------------------------------------------------
start_daemon() {
    # 检查是否已在运行
    if [ -f "$PID_FILE" ]; then
        local old_pid
        old_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            echo "MineGuard 已在运行 (PID: $old_pid)"
            exit 1
        fi
        rm -f "$PID_FILE"
    fi

    echo "正在以守护进程模式启动 MineGuard..."

    # 创建必要目录
    mkdir -p "$(dirname "$PID_FILE")" 2>/dev/null || true
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    mkdir -p "$STATE_DIR" 2>/dev/null || true

    # 启动后台进程
    nohup "$0" start >> "$LOG_FILE" 2>&1 &
    local daemon_pid=$!
    echo "$daemon_pid" > "$PID_FILE"
    echo "MineGuard 已启动 (PID: $daemon_pid)"
    echo "日志文件: $LOG_FILE"
}

stop_daemon() {
    if [ ! -f "$PID_FILE" ]; then
        echo "MineGuard 未在运行"
        return 1
    fi

    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "正在停止 MineGuard (PID: $pid)..."
        kill "$pid" 2>/dev/null
        # 等待进程退出
        local count=0
        while kill -0 "$pid" 2>/dev/null && [ "$count" -lt 10 ]; do
            sleep 1
            count=$((count + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$PID_FILE"
        echo "MineGuard 已停止"
    else
        echo "MineGuard 进程不存在 (PID: $pid)"
        rm -f "$PID_FILE"
    fi
}

show_status() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  MineGuard v${VERSION} 状态"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "  状态:    🟢 运行中 (PID: $pid)"
            echo "  运行时间: $(ps -p "$pid" -o etime= 2>/dev/null || echo '未知')"
        else
            echo "  状态:    🔴 已停止（PID 文件残留）"
        fi
    else
        echo "  状态:    🔴 未运行"
    fi

    echo "  日志:    $LOG_FILE"
    echo "  配置:    /etc/mineguard/config.conf"
    echo ""

    # 显示当前系统资源
    if [ -f "/proc/stat" ]; then
        echo "  当前资源使用:"
        local mem_info
        mem_info=$(get_memory_usage 2>/dev/null || echo "0 0 0")
        local mem_total mem_used mem_pct
        read -r mem_total mem_used mem_pct <<< "$mem_info"
        local cpu_fast
        cpu_fast=$(get_cpu_usage_fast 2>/dev/null || echo "0")
        echo "    CPU:   ~${cpu_fast}%"
        echo "    内存:  ${mem_pct}% (${mem_used}MB / ${mem_total}MB)"
        echo "    负载:  $(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')"
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ----------------------------------------------------------------------------
# 使用帮助
# ----------------------------------------------------------------------------
show_usage() {
    cat << 'EOF'
MineGuard - 轻量级服务器监控 & 挖矿检测守护进程

用法: mineguard <命令> [选项]

命令:
  start          前台启动监控（调试用）
  daemon         后台守护进程模式启动
  stop           停止守护进程
  restart        重启守护进程
  status         查看运行状态和系统资源
  check          执行一次检查（不进入循环）
  test-notify    发送测试通知
  version        显示版本信息

选项:
  -c, --config   指定配置文件路径

示例:
  mineguard start                    # 前台启动（调试）
  mineguard daemon                   # 后台启动
  mineguard -c /path/to/config start # 使用自定义配置
  mineguard check                    # 单次检查
  mineguard test-notify              # 测试通知

项目地址: https://github.com/unbridled-41/mineguard
EOF
}

# ----------------------------------------------------------------------------
# 主入口
# ----------------------------------------------------------------------------
main() {
    local config_file=""
    local command=""

    # 解析参数
    while [ $# -gt 0 ]; do
        case "$1" in
            -c|--config)
                config_file="$2"
                shift 2
                ;;
            *)
                command="$1"
                shift
                ;;
        esac
    done

    # 加载配置和模块
    load_config "$config_file"
    load_modules

    # 创建必要目录
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    mkdir -p "$STATE_DIR" 2>/dev/null || true

    case "${command:-}" in
        start)
            # 设置信号处理
            trap cleanup SIGTERM SIGINT SIGHUP

            # 依赖检查
            if ! check_dependencies; then
                exit 1
            fi

            # 写入 PID
            echo $$ > "$PID_FILE" 2>/dev/null || true

            run_monitor
            ;;
        daemon)
            start_daemon
            ;;
        stop)
            stop_daemon
            ;;
        restart)
            stop_daemon 2>/dev/null || true
            sleep 2
            start_daemon
            ;;
        status)
            # 需要加载 cpu.sh 和 memory.sh 中的函数
            show_status
            ;;
        check)
            if ! check_dependencies; then
                exit 1
            fi
            load_mining_signatures
            echo "执行单次检查..."
            run_check
            echo "检查完成，请查看日志: $LOG_FILE"
            ;;
        test-notify|test)
            test_notifications
            ;;
        version|-v|--version)
            echo "MineGuard v${VERSION}"
            ;;
        help|-h|--help|"")
            show_usage
            ;;
        *)
            echo "未知命令: $command"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
