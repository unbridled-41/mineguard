#!/bin/bash
# ============================================================================
# MineGuard - lib/utils.sh
# 通用工具函数库
# ============================================================================

# 颜色定义（用于终端输出）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志级别
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3

# 当前日志级别（默认 INFO）
CURRENT_LOG_LEVEL=${CURRENT_LOG_LEVEL:-$LOG_LEVEL_INFO}

# ----------------------------------------------------------------------------
# 日志函数
# ----------------------------------------------------------------------------
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[$timestamp] [$level] $message"

    # 确保日志目录存在
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    [ ! -d "$log_dir" ] && mkdir -p "$log_dir" 2>/dev/null

    # 写入日志文件
    echo "$log_line" >> "$LOG_FILE" 2>/dev/null

    # 日志轮转检查
    check_log_rotation
}

log_debug() { [ "$CURRENT_LOG_LEVEL" -le "$LOG_LEVEL_DEBUG" ] && log "DEBUG" "$1"; }
log_info()  { log "INFO"  "$1"; }
log_warn()  { log "WARN"  "$1"; }
log_error() { log "ERROR" "$1"; }

# ----------------------------------------------------------------------------
# 日志轮转
# ----------------------------------------------------------------------------
check_log_rotation() {
    if [ -f "$LOG_FILE" ]; then
        local size_bytes
        size_bytes=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        local max_bytes=$((LOG_MAX_SIZE_MB * 1024 * 1024))
        if [ "$size_bytes" -gt "$max_bytes" ]; then
            mv "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null
            log_info "日志文件已轮转"
        fi
    fi
}

# ----------------------------------------------------------------------------
# 状态文件管理
# ----------------------------------------------------------------------------
# 设置状态值
set_state() {
    local key="$1"
    local value="$2"
    [ ! -d "$STATE_DIR" ] && mkdir -p "$STATE_DIR" 2>/dev/null
    echo "$value" > "${STATE_DIR}/${key}" 2>/dev/null
}

# 获取状态值
get_state() {
    local key="$1"
    local default="${2:-}"
    local file="${STATE_DIR}/${key}"
    if [ -f "$file" ]; then
        cat "$file" 2>/dev/null
    else
        echo "$default"
    fi
}

# 递增计数器
increment_state() {
    local key="$1"
    local current
    current=$(get_state "$key" "0")
    set_state "$key" "$((current + 1))"
    echo "$((current + 1))"
}

# 重置状态
reset_state() {
    local key="$1"
    rm -f "${STATE_DIR}/${key}" 2>/dev/null
}

# ----------------------------------------------------------------------------
# 告警冷却管理
# ----------------------------------------------------------------------------
# 检查告警是否在冷却中
is_alert_cooling() {
    local alert_type="$1"
    local cooldown_file="${STATE_DIR}/cooldown_${alert_type}"

    if [ -f "$cooldown_file" ]; then
        local last_alert
        last_alert=$(cat "$cooldown_file" 2>/dev/null)
        local now
        now=$(date +%s)
        local elapsed=$((now - last_alert))
        if [ "$elapsed" -lt "$ALERT_COOLDOWN" ]; then
            return 0  # 仍在冷却中
        fi
    fi
    return 1  # 不在冷却中
}

# 记录告警时间（开始冷却）
start_alert_cooldown() {
    local alert_type="$1"
    local cooldown_file="${STATE_DIR}/cooldown_${alert_type}"
    date +%s > "$cooldown_file" 2>/dev/null
}

# 检查每小时告警数量限制
check_hourly_limit() {
    local counter_file="${STATE_DIR}/hourly_alert_count"
    local hour_file="${STATE_DIR}/current_hour"
    local current_hour
    current_hour=$(date +%H)
    local saved_hour
    saved_hour=$(get_state "current_hour" "")

    # 新的小时，重置计数器
    if [ "$current_hour" != "$saved_hour" ]; then
        set_state "current_hour" "$current_hour"
        set_state "hourly_alert_count" "0"
    fi

    local count
    count=$(get_state "hourly_alert_count" "0")
    if [ "$count" -ge "$MAX_ALERTS_PER_HOUR" ]; then
        return 1  # 超过限制
    fi

    increment_state "hourly_alert_count" > /dev/null
    return 0
}

# ----------------------------------------------------------------------------
# 系统信息获取
# ----------------------------------------------------------------------------
get_hostname() {
    hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown"
}

get_ip_address() {
    # 尝试获取公网 IP（带超时）
    local public_ip
    public_ip=$(curl -s --connect-timeout 3 --max-time 5 ifconfig.me 2>/dev/null)
    if [ -n "$public_ip" ]; then
        echo "$public_ip"
        return
    fi
    # 回退到内网 IP
    ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1
}

get_uptime() {
    uptime -p 2>/dev/null || uptime | sed 's/.*up/up/' | sed 's/,.*load.*//'
}

get_kernel() {
    uname -r
}

get_arch() {
    uname -m
}

# ----------------------------------------------------------------------------
# 数值比较（支持浮点数）
# ----------------------------------------------------------------------------
float_ge() {
    # $1 >= $2 返回 0（true）
    awk "BEGIN { exit !($1 >= $2) }" 2>/dev/null
}

float_gt() {
    # $1 > $2 返回 0（true）
    awk "BEGIN { exit !($1 > $2) }" 2>/dev/null
}

# ----------------------------------------------------------------------------
# 时间格式化
# ----------------------------------------------------------------------------
format_timestamp() {
    date '+%Y-%m-%d %H:%M:%S %Z'
}

format_duration() {
    local seconds=$1
    local days=$((seconds / 86400))
    local hours=$(( (seconds % 86400) / 3600 ))
    local minutes=$(( (seconds % 3600) / 60 ))

    if [ "$days" -gt 0 ]; then
        printf "%d天%d小时%d分钟" "$days" "$hours" "$minutes"
    elif [ "$hours" -gt 0 ]; then
        printf "%d小时%d分钟" "$hours" "$minutes"
    else
        printf "%d分钟" "$minutes"
    fi
}

# ----------------------------------------------------------------------------
# 依赖检查
# ----------------------------------------------------------------------------
check_dependencies() {
    local missing=()
    local deps=("awk" "grep" "sed" "ps" "free" "curl" "stat" "date" "hostname")

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "缺少以下依赖: ${missing[*]}"
        echo "请安装: sudo apt-get install -y coreutils procps curl net-tools"
        return 1
    fi
    return 0
}
