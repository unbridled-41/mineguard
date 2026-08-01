#!/bin/bash
# ============================================================================
# MineGuard - lib/memory.sh
# 内存监控模块
# ============================================================================

# ----------------------------------------------------------------------------
# 获取内存使用信息
# 输出: 总量(MB) 已用(MB) 使用率(%)
# ----------------------------------------------------------------------------
get_memory_usage() {
    # 从 /proc/meminfo 读取（跨架构兼容）
    local mem_total mem_available mem_used usage_pct

    mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    mem_available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)

    # 如果 MemAvailable 不存在（极旧内核），使用 MemFree + Buffers + Cached
    if [ -z "$mem_available" ]; then
        local mem_free mem_buffers mem_cached
        mem_free=$(awk '/^MemFree:/ {print $2}' /proc/meminfo)
        mem_buffers=$(awk '/^Buffers:/ {print $2}' /proc/meminfo)
        mem_cached=$(awk '/^Cached:/ {print $2}' /proc/meminfo)
        mem_available=$((mem_free + mem_buffers + mem_cached))
    fi

    mem_used=$((mem_total - mem_available))
    local total_mb=$((mem_total / 1024))
    local used_mb=$((mem_used / 1024))

    if [ "$mem_total" -gt 0 ]; then
        usage_pct=$(awk "BEGIN { printf \"%.1f\", ($mem_used / $mem_total) * 100 }")
    else
        usage_pct="0"
    fi

    echo "${total_mb} ${used_mb} ${usage_pct}"
}

# ----------------------------------------------------------------------------
# 获取 Swap 使用信息
# 输出: 总量(MB) 已用(MB) 使用率(%)
# ----------------------------------------------------------------------------
get_swap_usage() {
    local swap_total swap_free swap_used usage_pct

    swap_total=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
    swap_free=$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)

    if [ -z "$swap_total" ] || [ "$swap_total" -eq 0 ]; then
        echo "0 0 0"
        return
    fi

    swap_used=$((swap_total - swap_free))
    local total_mb=$((swap_total / 1024))
    local used_mb=$((swap_used / 1024))
    usage_pct=$(awk "BEGIN { printf \"%.1f\", ($swap_used / $swap_total) * 100 }")

    echo "${total_mb} ${used_mb} ${usage_pct}"
}

# ----------------------------------------------------------------------------
# 获取内存占用最高的进程列表
# ----------------------------------------------------------------------------
get_top_mem_processes() {
    local count="${1:-5}"
    ps -eo pid,pmem,rss,user,comm --sort=-rss 2>/dev/null | head -n $((count + 1)) | \
        awk 'NR==1 {printf "%-8s %-6s %-10s %-10s %s\n", $1, $2, "RSS(KB)", $4, $5}
             NR>1  {printf "%-8s %-5s%% %-10s %-10s %s\n", $1, $2, $3, $4, $5}'
}

# ----------------------------------------------------------------------------
# 内存监控检查
# 返回: 0=正常, 1=告警, 2=严重
# ----------------------------------------------------------------------------
check_memory() {
    local mem_info
    mem_info=$(get_memory_usage)
    local mem_total_mb mem_used_mb mem_pct
    read -r mem_total_mb mem_used_mb mem_pct <<< "$mem_info"

    log_debug "内存使用率: ${mem_pct}% (${mem_used_mb}MB / ${mem_total_mb}MB)"

    local alert_sent=0

    # 检查内存
    if float_ge "$mem_pct" "$MEM_CRIT_THRESHOLD"; then
        if ! is_alert_cooling "mem_crit"; then
            local top_procs
            top_procs=$(get_top_mem_processes 5)

            send_alert "CRIT" "内存使用率严重过高" \
"内存使用率: ${mem_pct}% (阈值: ${MEM_CRIT_THRESHOLD}%)
已用: ${mem_used_mb}MB / 总计: ${mem_total_mb}MB

🔝 内存占用最高的进程:
${top_procs}"
            start_alert_cooldown "mem_crit"
            set_state "mem_was_high" "1"
        fi
        alert_sent=2

    elif float_ge "$mem_pct" "$MEM_WARN_THRESHOLD"; then
        if ! is_alert_cooling "mem_warn"; then
            local top_procs
            top_procs=$(get_top_mem_processes 5)

            send_alert "WARN" "内存使用率过高" \
"内存使用率: ${mem_pct}% (阈值: ${MEM_WARN_THRESHOLD}%)
已用: ${mem_used_mb}MB / 总计: ${mem_total_mb}MB

🔝 内存占用最高的进程:
${top_procs}"
            start_alert_cooldown "mem_warn"
            set_state "mem_was_high" "1"
        fi
        alert_sent=1

    else
        # 恢复通知
        local was_high
        was_high=$(get_state "mem_was_high" "0")
        if [ "$was_high" = "1" ] && [ "$SEND_RECOVERY_ALERT" = "1" ]; then
            if ! is_alert_cooling "mem_recovery"; then
                send_alert "RECOVERY" "内存使用率已恢复正常" \
"内存使用率: ${mem_pct}% (${mem_used_mb}MB / ${mem_total_mb}MB)"
                start_alert_cooldown "mem_recovery"
            fi
        fi
        reset_state "mem_was_high"
    fi

    # 检查 Swap
    if [ "$SWAP_WARN_THRESHOLD" -gt 0 ]; then
        local swap_info
        swap_info=$(get_swap_usage)
        local swap_total_mb swap_used_mb swap_pct
        read -r swap_total_mb swap_used_mb swap_pct <<< "$swap_info"

        if [ "$swap_total_mb" -gt 0 ] && float_ge "$swap_pct" "$SWAP_WARN_THRESHOLD"; then
            if ! is_alert_cooling "swap_warn"; then
                send_alert "WARN" "Swap 使用率过高" \
"Swap 使用率: ${swap_pct}% (阈值: ${SWAP_WARN_THRESHOLD}%)
Swap 已用: ${swap_used_mb}MB / 总计: ${swap_total_mb}MB
💡 提示: 高 Swap 使用通常表示物理内存不足"
                start_alert_cooldown "swap_warn"
            fi
        fi
    fi

    return $alert_sent
}
