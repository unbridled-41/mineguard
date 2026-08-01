#!/bin/bash
# ============================================================================
# MineGuard - lib/process.sh
# 进程分析 & 挖矿检测模块
# 灵感来源: VertexElite/server-security-toolkit
#            russellgrapes/telegram-bash-system-monitoring
# ============================================================================

# ----------------------------------------------------------------------------
# 加载挖矿特征签名
# ----------------------------------------------------------------------------
load_mining_signatures() {
    MINING_PROC_NAMES=()
    MINING_POOL_KEYWORDS=()
    MINING_POOL_PORTS=()

    if [ ! -f "$MINING_SIGNATURES_FILE" ]; then
        log_warn "挖矿特征签名文件不存在: $MINING_SIGNATURES_FILE"
        # 使用内置默认值
        MINING_PROC_NAMES=("xmrig" "xmr-stak" "minerd" "cpuminer" "cgminer"
                           "ethminer" "kdevtmpfsi" "kinsing" "kworkerds")
        MINING_POOL_KEYWORDS=("stratum" "mining" "nicehash" "nanopool" "f2pool"
                              "moneroocean" "supportxmr")
        MINING_POOL_PORTS=("3333" "4444" "5555" "7777" "8888" "9999" "14433" "14444")
        return
    fi

    while IFS= read -r line; do
        # 跳过空行和注释
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        if [[ "$line" =~ ^POOL: ]]; then
            MINING_POOL_KEYWORDS+=("${line#POOL:}")
        elif [[ "$line" =~ ^PORT: ]]; then
            MINING_POOL_PORTS+=("${line#PORT:}")
        else
            MINING_PROC_NAMES+=("$line")
        fi
    done < "$MINING_SIGNATURES_FILE"

    log_debug "已加载挖矿特征: ${#MINING_PROC_NAMES[@]} 进程名, ${#MINING_POOL_KEYWORDS[@]} 矿池关键字, ${#MINING_POOL_PORTS[@]} 矿池端口"
}

# ----------------------------------------------------------------------------
# 检测已知挖矿进程名称
# 返回: 匹配的进程列表（为空表示未检测到）
# ----------------------------------------------------------------------------
detect_mining_by_name() {
    local detected=""

    for name in "${MINING_PROC_NAMES[@]}"; do
        # 使用 pgrep 检测进程（大小写不敏感）
        local matches
        matches=$(ps -eo pid,pcpu,pmem,user,args 2>/dev/null | \
                  grep -i "$name" | grep -v "grep" | grep -v "mineguard")

        if [ -n "$matches" ]; then
            detected+="[特征匹配: $name]
${matches}
"
        fi
    done

    echo "$detected"
}

# ----------------------------------------------------------------------------
# 检测可疑的高 CPU 进程
# 查找持续占用高 CPU 且不在白名单中的进程
# ----------------------------------------------------------------------------
detect_suspicious_high_cpu() {
    local detected=""

    # 获取所有 CPU 占用超过阈值的进程
    local high_cpu_procs
    high_cpu_procs=$(ps -eo pid,pcpu,pmem,user,comm,args --sort=-pcpu 2>/dev/null | \
                     awk -v threshold="$PROCESS_CPU_THRESHOLD" 'NR>1 && $2+0 >= threshold {print}')

    if [ -z "$high_cpu_procs" ]; then
        return
    fi

    while IFS= read -r proc_line; do
        [ -z "$proc_line" ] && continue

        local proc_name
        proc_name=$(echo "$proc_line" | awk '{print $5}')

        # 检查白名单
        if echo "$proc_name" | grep -qEi "$CPU_WHITELIST"; then
            continue
        fi

        # 检查 /proc/{pid}/exe 指向的真实路径
        local pid
        pid=$(echo "$proc_line" | awk '{print $1}')
        local exe_path=""
        if [ -L "/proc/${pid}/exe" ]; then
            exe_path=$(readlink -f "/proc/${pid}/exe" 2>/dev/null)
        fi

        # 可疑特征评分
        local suspicion=0
        local reasons=""

        # 1. 进程在 /tmp, /var/tmp, /dev/shm 中运行（挖矿常见路径）
        if [[ "$exe_path" =~ ^/(tmp|var/tmp|dev/shm) ]]; then
            suspicion=$((suspicion + 3))
            reasons+="  ⚡ 从临时目录运行: ${exe_path}\n"
        fi

        # 2. 进程名被删除（(deleted) 标记）
        if [[ "$exe_path" =~ \(deleted\) ]]; then
            suspicion=$((suspicion + 3))
            reasons+="  ⚡ 二进制文件已被删除\n"
        fi

        # 3. 进程名伪装成系统服务
        local fake_names="kworker|kthread|bioset|systemd|syslog|cron|atd"
        if echo "$proc_name" | grep -qEi "$fake_names"; then
            # 检查真实路径是否与系统路径不符
            if [ -n "$exe_path" ] && ! [[ "$exe_path" =~ ^/(usr/(s?bin|lib)|sbin|lib) ]]; then
                suspicion=$((suspicion + 2))
                reasons+="  ⚡ 可能伪装系统进程: ${proc_name} (实际路径: ${exe_path})\n"
            fi
        fi

        # 4. 高 CPU 占用本身就是可疑信号
        local cpu_pct
        cpu_pct=$(echo "$proc_line" | awk '{print $2}')
        if float_ge "$cpu_pct" "90"; then
            suspicion=$((suspicion + 2))
            reasons+="  ⚡ CPU 占用极高: ${cpu_pct}%\n"
        else
            suspicion=$((suspicion + 1))
            reasons+="  ⚡ CPU 占用过高: ${cpu_pct}%\n"
        fi

        # 5. 进程无 TTY（后台运行，大多挖矿程序如此）
        local tty
        tty=$(ps -o tty= -p "$pid" 2>/dev/null)
        if [ "$tty" = "?" ]; then
            suspicion=$((suspicion + 1))
        fi

        # 可疑度达到阈值时报告
        if [ "$suspicion" -ge 3 ]; then
            detected+="[可疑进程 - 威胁评分: ${suspicion}/10]
  PID: ${pid}
  进程名: ${proc_name}
  用户: $(echo "$proc_line" | awk '{print $4}')
  命令: $(echo "$proc_line" | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}')
  可执行文件: ${exe_path:-未知}
$(echo -e "$reasons")
"
        fi
    done <<< "$high_cpu_procs"

    echo "$detected"
}

# ----------------------------------------------------------------------------
# 检测挖矿网络连接
# 检查是否有到已知矿池端口/域名的连接
# ----------------------------------------------------------------------------
detect_mining_network() {
    local detected=""

    # 检查 ss/netstat 是否可用
    local net_cmd=""
    if command -v ss &>/dev/null; then
        net_cmd="ss"
    elif command -v netstat &>/dev/null; then
        net_cmd="netstat"
    else
        log_debug "ss/netstat 均不可用，跳过网络检测"
        return
    fi

    # 获取所有对外连接
    local connections
    if [ "$net_cmd" = "ss" ]; then
        connections=$(ss -tnp state established 2>/dev/null)
    else
        connections=$(netstat -tnp 2>/dev/null | grep ESTABLISHED)
    fi

    [ -z "$connections" ] && return

    # 检查矿池端口
    for port in "${MINING_POOL_PORTS[@]}"; do
        # 排除白名单端口
        if echo "$port" | grep -qE "^(${NET_WHITELIST_PORTS})$"; then
            continue
        fi

        local matches
        matches=$(echo "$connections" | grep ":${port}" | grep -v "grep")
        if [ -n "$matches" ]; then
            detected+="[矿池端口连接检测]
  目标端口: ${port}
  连接详情:
$(echo "$matches" | head -5)
"
        fi
    done

    # 检查 DNS 解析中的矿池关键字（如果有 /etc/resolv.conf 且可读取）
    # 通过检查 /proc/net/tcp 中的远程地址来间接检测
    # 这里使用 ss 的进程信息来检查

    echo "$detected"
}

# ----------------------------------------------------------------------------
# 检查可疑的 crontab 条目
# 挖矿程序经常通过 crontab 实现持久化
# ----------------------------------------------------------------------------
detect_suspicious_crontab() {
    local detected=""
    local suspicious_patterns="(curl|wget|bash|sh|python|perl|ruby).*\|.*(bash|sh)"
    suspicious_patterns+="|/tmp/|/var/tmp/|/dev/shm/"
    suspicious_patterns+="|base64.*-d|base64.*--decode"

    # 检查所有用户的 crontab
    if [ -d "/var/spool/cron/crontabs" ]; then
        for cronfile in /var/spool/cron/crontabs/*; do
            [ -f "$cronfile" ] || continue
            local user
            user=$(basename "$cronfile")
            local suspicious
            suspicious=$(grep -vE '^#|^$' "$cronfile" 2>/dev/null | grep -Ei "$suspicious_patterns")
            if [ -n "$suspicious" ]; then
                detected+="[可疑 crontab - 用户: ${user}]
${suspicious}
"
            fi
        done
    fi

    # 检查系统级 cron
    for crondir in /etc/cron.d /etc/cron.daily /etc/cron.hourly; do
        [ -d "$crondir" ] || continue
        for cronfile in "$crondir"/*; do
            [ -f "$cronfile" ] || continue
            local suspicious
            suspicious=$(grep -vE '^#|^$' "$cronfile" 2>/dev/null | grep -Ei "$suspicious_patterns")
            if [ -n "$suspicious" ]; then
                detected+="[可疑系统 cron - ${cronfile}]
${suspicious}
"
            fi
        done
    done

    echo "$detected"
}

# ----------------------------------------------------------------------------
# 综合挖矿检测
# ----------------------------------------------------------------------------
check_mining() {
    local all_detections=""
    local threat_level=0  # 0=无威胁, 1=可疑, 2=确认

    # 1. 进程名称匹配检测
    if [ "$MINING_NAME_DETECT" = "1" ]; then
        local name_result
        name_result=$(detect_mining_by_name)
        if [ -n "$name_result" ]; then
            all_detections+="━━━ 进程名称特征匹配 ━━━
${name_result}
"
            threat_level=2  # 名称匹配 = 高置信度
        fi
    fi

    # 2. 可疑高 CPU 进程检测
    local suspicious_result
    suspicious_result=$(detect_suspicious_high_cpu)
    if [ -n "$suspicious_result" ]; then
        all_detections+="━━━ 可疑高 CPU 进程 ━━━
${suspicious_result}
"
        [ "$threat_level" -lt 1 ] && threat_level=1
    fi

    # 3. 网络连接检测
    if [ "$MINING_NET_DETECT" = "1" ]; then
        local net_result
        net_result=$(detect_mining_network)
        if [ -n "$net_result" ]; then
            all_detections+="━━━ 矿池网络连接 ━━━
${net_result}
"
            threat_level=2  # 矿池连接 = 高置信度
        fi
    fi

    # 4. 可疑 crontab 检测（每 10 次检查做一次，减少开销）
    local cron_counter
    cron_counter=$(get_state "cron_check_counter" "0")
    cron_counter=$((cron_counter + 1))
    set_state "cron_check_counter" "$cron_counter"

    if [ $((cron_counter % 10)) -eq 0 ]; then
        local cron_result
        cron_result=$(detect_suspicious_crontab)
        if [ -n "$cron_result" ]; then
            all_detections+="━━━ 可疑 Crontab 条目 ━━━
${cron_result}
"
            [ "$threat_level" -lt 1 ] && threat_level=1
        fi
    fi

    # 发送告警
    if [ -n "$all_detections" ]; then
        local alert_level
        if [ "$threat_level" -ge 2 ]; then
            alert_level="CRIT"
        else
            alert_level="WARN"
        fi

        if ! is_alert_cooling "mining_${alert_level}"; then
            send_alert "$alert_level" "🔍 检测到可疑挖矿活动" \
"威胁级别: $([ $threat_level -ge 2 ] && echo '🔴 高' || echo '🟡 中')

${all_detections}
💡 建议操作:
  1. 检查上述进程是否为合法服务
  2. 使用 'kill -9 <PID>' 终止可疑进程
  3. 检查是否有未授权的 SSH 密钥或 crontab
  4. 检查 /tmp, /var/tmp, /dev/shm 目录"

            start_alert_cooldown "mining_${alert_level}"
        fi

        # 自动 kill（如果启用）
        if [ "$AUTO_KILL_MINER" = "1" ] && [ "$threat_level" -ge 2 ]; then
            auto_kill_miners
        fi

        return $threat_level
    fi

    return 0
}

# ----------------------------------------------------------------------------
# 自动终止检测到的挖矿进程
# ⚠️ 危险操作，仅在配置启用时执行
# ----------------------------------------------------------------------------
auto_kill_miners() {
    log_warn "⚠️ 自动终止挖矿进程已启用"

    for name in "${MINING_PROC_NAMES[@]}"; do
        local pids
        pids=$(pgrep -i "$name" 2>/dev/null)
        if [ -n "$pids" ]; then
            while IFS= read -r pid; do
                local proc_cmd
                proc_cmd=$(ps -p "$pid" -o comm= 2>/dev/null)
                log_warn "终止可疑进程: PID=$pid CMD=$proc_cmd"
                kill -9 "$pid" 2>/dev/null
            done <<< "$pids"
        fi
    done
}
