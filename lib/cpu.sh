#!/bin/bash
# ============================================================================
# MineGuard - lib/cpu.sh
# CPU 监控模块
# ============================================================================

# ----------------------------------------------------------------------------
# 获取当前 CPU 使用率（精确，基于 /proc/stat）
# 比 top 更轻量，且在 x86/ARM 上行为一致
# ----------------------------------------------------------------------------
get_cpu_usage() {
    # 两次采样间隔 1 秒
    local cpu_line_1 cpu_line_2
    cpu_line_1=$(head -1 /proc/stat)
    sleep 1
    cpu_line_2=$(head -1 /proc/stat)

    # 解析 CPU 时间
    local user1 nice1 system1 idle1 iowait1 irq1 softirq1
    read -r _ user1 nice1 system1 idle1 iowait1 irq1 softirq1 _ <<< "$cpu_line_1"

    local user2 nice2 system2 idle2 iowait2 irq2 softirq2
    read -r _ user2 nice2 system2 idle2 iowait2 irq2 softirq2 _ <<< "$cpu_line_2"

    local total1=$((user1 + nice1 + system1 + idle1 + iowait1 + irq1 + softirq1))
    local total2=$((user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2))
    local total_diff=$((total2 - total1))
    local idle_diff=$((idle2 - idle1))

    if [ "$total_diff" -eq 0 ]; then
        echo "0"
        return
    fi

    # 计算使用率
    awk "BEGIN { printf \"%.1f\", (($total_diff - $idle_diff) / $total_diff) * 100 }"
}

# ----------------------------------------------------------------------------
# 快速获取 CPU 使用率（基于 /proc/loadavg，不阻塞）
# 适用于快速检查，精度略低
# ----------------------------------------------------------------------------
get_cpu_usage_fast() {
    local cores
    cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    local load1
    load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null)

    if [ -n "$load1" ] && [ "$cores" -gt 0 ]; then
        awk "BEGIN { usage = ($load1 / $cores) * 100; if (usage > 100) usage = 100; printf \"%.1f\", usage }"
    else
        echo "0"
    fi
}

# ----------------------------------------------------------------------------
# 获取 CPU 核心数
# ----------------------------------------------------------------------------
get_cpu_cores() {
    nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1
}

# ----------------------------------------------------------------------------
# 获取 CPU 负载平均值
# ----------------------------------------------------------------------------
get_load_average() {
    cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}'
}

# ----------------------------------------------------------------------------
# CPU 监控检查
# 返回: 0=正常, 1=告警, 2=严重
# ----------------------------------------------------------------------------
check_cpu() {
    local cpu_usage
    cpu_usage=$(get_cpu_usage)

    log_debug "CPU 使用率: ${cpu_usage}%"

    # 检查持续高 CPU
    local sustained_count
    sustained_count=$(get_state "cpu_high_count" "0")

    if float_ge "$cpu_usage" "$CPU_CRIT_THRESHOLD"; then
        # 严重
        sustained_count=$((sustained_count + 1))
        set_state "cpu_high_count" "$sustained_count"

        if [ "$sustained_count" -ge "$CPU_SUSTAINED_COUNT" ]; then
            if ! is_alert_cooling "cpu_crit"; then
                local top_procs
                top_procs=$(get_top_cpu_processes 5)
                local load
                load=$(get_load_average)
                local cores
                cores=$(get_cpu_cores)

                send_alert "CRIT" "CPU 使用率严重过高" \
"CPU 使用率: ${cpu_usage}% (阈值: ${CPU_CRIT_THRESHOLD}%)
已持续 ${sustained_count} 次检测 (间隔 ${CHECK_INTERVAL}s)
CPU 核心数: ${cores}
负载均值: ${load}

🔝 占用最高的进程:
${top_procs}"
                start_alert_cooldown "cpu_crit"
            fi
            return 2
        fi

    elif float_ge "$cpu_usage" "$CPU_WARN_THRESHOLD"; then
        # 告警
        sustained_count=$((sustained_count + 1))
        set_state "cpu_high_count" "$sustained_count"

        if [ "$sustained_count" -ge "$CPU_SUSTAINED_COUNT" ]; then
            if ! is_alert_cooling "cpu_warn"; then
                local top_procs
                top_procs=$(get_top_cpu_processes 5)

                send_alert "WARN" "CPU 使用率过高" \
"CPU 使用率: ${cpu_usage}% (阈值: ${CPU_WARN_THRESHOLD}%)
已持续 ${sustained_count} 次检测

🔝 占用最高的进程:
${top_procs}"
                start_alert_cooldown "cpu_warn"
            fi
            return 1
        fi

    else
        # 正常 - 检查是否从异常恢复
        if [ "$sustained_count" -ge "$CPU_SUSTAINED_COUNT" ] && [ "$SEND_RECOVERY_ALERT" = "1" ]; then
            if ! is_alert_cooling "cpu_recovery"; then
                send_alert "RECOVERY" "CPU 使用率已恢复正常" \
"CPU 使用率: ${cpu_usage}%
已从持续高占用状态恢复"
                start_alert_cooldown "cpu_recovery"
            fi
        fi
        reset_state "cpu_high_count"
        return 0
    fi

    return 0
}

# ----------------------------------------------------------------------------
# 获取 CPU 占用最高的进程列表
# ----------------------------------------------------------------------------
get_top_cpu_processes() {
    local count="${1:-5}"
    ps -eo pid,pcpu,pmem,user,comm --sort=-pcpu 2>/dev/null | head -n $((count + 1)) | \
        awk 'NR==1 {printf "%-8s %-6s %-6s %-10s %s\n", $1, $2, $3, $4, $5}
             NR>1  {printf "%-8s %-5s%% %-5s%% %-10s %s\n", $1, $2, $3, $4, $5}'
}
