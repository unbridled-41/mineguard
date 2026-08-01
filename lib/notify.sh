#!/bin/bash
# ============================================================================
# MineGuard - lib/notify.sh
# 通知模块 - 支持 Telegram / Webhook / Email
# ============================================================================

# ----------------------------------------------------------------------------
# 统一通知入口
# ----------------------------------------------------------------------------
send_alert() {
    local level="$1"    # WARN / CRIT / RECOVERY
    local title="$2"
    local message="$3"

    local timestamp
    timestamp=$(format_timestamp)
    local host
    host=$(get_hostname)

    log_info "发送告警: [$level] $title"

    # 检查每小时限制
    if ! check_hourly_limit; then
        log_warn "每小时告警数量已达上限 ($MAX_ALERTS_PER_HOUR)，暂停告警"
        return 1
    fi

    # 分发到各通知渠道
    if [ "$TELEGRAM_ENABLED" = "1" ]; then
        send_telegram "$level" "$title" "$message" "$timestamp" "$host" &
    fi

    if [ "$WEBHOOK_ENABLED" = "1" ]; then
        send_webhook "$level" "$title" "$message" "$timestamp" "$host" &
    fi

    if [ "$EMAIL_ENABLED" = "1" ]; then
        send_email "$level" "$title" "$message" "$timestamp" "$host" &
    fi

    # 等待所有后台通知完成（最多 10 秒）
    wait
}

# ----------------------------------------------------------------------------
# Telegram 通知
# ----------------------------------------------------------------------------
send_telegram() {
    local level="$1"
    local title="$2"
    local message="$3"
    local timestamp="$4"
    local host="$5"

    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        log_error "Telegram 配置不完整，跳过发送"
        return 1
    fi

    # 表情图标
    local emoji
    case "$level" in
        CRIT)     emoji="🚨" ;;
        WARN)     emoji="⚠️" ;;
        RECOVERY) emoji="✅" ;;
        INFO)     emoji="ℹ️" ;;
        *)        emoji="📢" ;;
    esac

    # 构建 Telegram 消息（MarkdownV2 格式）
    local text="${emoji} *MineGuard \\- ${level}*

🖥 *主机:* \`${host}\`
📋 *事件:* ${title}

${message}

🕐 ${timestamp}"

    # 发送请求
    local response
    response=$(curl -s --connect-timeout 10 --max-time 15 \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=MarkdownV2" \
        -d "text=${text}" 2>&1)

    if echo "$response" | grep -q '"ok":true'; then
        log_info "Telegram 通知发送成功"
    else
        # 尝试纯文本模式（MarkdownV2 可能存在转义问题）
        local plain_text="${emoji} MineGuard - ${level}
主机: ${host}
事件: ${title}
${message}
时间: ${timestamp}"

        response=$(curl -s --connect-timeout 10 --max-time 15 \
            -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=${plain_text}" 2>&1)

        if echo "$response" | grep -q '"ok":true'; then
            log_info "Telegram 通知发送成功（纯文本模式）"
        else
            log_error "Telegram 通知发送失败: $response"
        fi
    fi
}

# ----------------------------------------------------------------------------
# Webhook 通知（兼容企业微信/钉钉/自定义）
# ----------------------------------------------------------------------------
send_webhook() {
    local level="$1"
    local title="$2"
    local message="$3"
    local timestamp="$4"
    local host="$5"

    if [ -z "$WEBHOOK_URL" ]; then
        log_error "Webhook URL 未配置，跳过发送"
        return 1
    fi

    # 替换模板变量
    local payload="$WEBHOOK_TEMPLATE"
    payload=$(echo "$payload" | sed "s/{{HOSTNAME}}/${host}/g")
    payload=$(echo "$payload" | sed "s/{{LEVEL}}/${level}/g")
    payload=$(echo "$payload" | sed "s/{{TITLE}}/${title}/g")
    # message 可能包含特殊字符，需要转义
    local escaped_message
    escaped_message=$(echo "$message" | sed 's/"/\\"/g' | tr '\n' ' ')
    payload=$(echo "$payload" | sed "s/{{MESSAGE}}/${escaped_message}/g")
    payload=$(echo "$payload" | sed "s/{{TIMESTAMP}}/${timestamp}/g")

    # 发送请求
    local response
    response=$(curl -s --connect-timeout 10 --max-time 15 \
        -X "$WEBHOOK_METHOD" \
        -H "Content-Type: ${WEBHOOK_CONTENT_TYPE}" \
        -d "$payload" \
        "$WEBHOOK_URL" 2>&1)

    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        log_info "Webhook 通知发送成功"
    else
        log_error "Webhook 通知发送失败 (exit=$exit_code): $response"
    fi
}

# ----------------------------------------------------------------------------
# 邮件通知 (via curl + SMTP)
# ----------------------------------------------------------------------------
send_email() {
    local level="$1"
    local title="$2"
    local message="$3"
    local timestamp="$4"
    local host="$5"

    if [ -z "$SMTP_SERVER" ] || [ -z "$EMAIL_TO" ]; then
        log_error "邮件配置不完整，跳过发送"
        return 1
    fi

    local subject="[MineGuard-${level}] ${host}: ${title}"
    local body="MineGuard 服务器监控告警

级别: ${level}
主机: ${host}
事件: ${title}

详细信息:
${message}

时间: ${timestamp}
---
此邮件由 MineGuard 自动发送"

    # 使用 curl 发送 SMTP 邮件
    local mail_url="smtp://${SMTP_SERVER}:${SMTP_PORT}"
    if [ "$SMTP_PORT" = "465" ]; then
        mail_url="smtps://${SMTP_SERVER}:${SMTP_PORT}"
    fi

    echo -e "Subject: ${subject}\nFrom: ${EMAIL_FROM}\nTo: ${EMAIL_TO}\n\n${body}" | \
        curl -s --connect-timeout 10 --max-time 30 \
            --url "$mail_url" \
            --ssl-reqd \
            --mail-from "$EMAIL_FROM" \
            --mail-rcpt "$EMAIL_TO" \
            --user "${SMTP_USER}:${SMTP_PASS}" \
            -T - 2>&1

    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        log_info "邮件通知发送成功"
    else
        log_error "邮件通知发送失败 (exit=$exit_code)"
    fi
}

# ----------------------------------------------------------------------------
# 测试通知（用于安装后验证）
# ----------------------------------------------------------------------------
test_notifications() {
    echo "正在测试通知渠道..."

    local host
    host=$(get_hostname)
    local test_msg="这是一条测试消息，用于验证 MineGuard 通知配置是否正确。"

    if [ "$TELEGRAM_ENABLED" = "1" ]; then
        echo -n "  Telegram: "
        send_telegram "INFO" "通知测试" "$test_msg" "$(format_timestamp)" "$host"
        echo "已发送"
    else
        echo "  Telegram: 未启用"
    fi

    if [ "$WEBHOOK_ENABLED" = "1" ]; then
        echo -n "  Webhook: "
        send_webhook "INFO" "通知测试" "$test_msg" "$(format_timestamp)" "$host"
        echo "已发送"
    else
        echo "  Webhook: 未启用"
    fi

    if [ "$EMAIL_ENABLED" = "1" ]; then
        echo -n "  Email: "
        send_email "INFO" "通知测试" "$test_msg" "$(format_timestamp)" "$host"
        echo "已发送"
    else
        echo "  Email: 未启用"
    fi

    echo "通知测试完成，请检查是否收到消息。"
}
