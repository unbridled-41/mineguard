#!/bin/bash
# ============================================================================
# MineGuard - 安装脚本
# 将 MineGuard 安装为 systemd 服务
# 支持 Ubuntu / Debian (x86_64 / ARM64)
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_DIR="/etc/mineguard"
BIN_DIR="/usr/local/bin"
LOG_DIR="/var/log/mineguard"
STATE_DIR="/var/lib/mineguard"
SERVICE_NAME="mineguard"

echo -e "${BLUE}"
cat << 'BANNER'
  __  __ _            ____                     _
 |  \/  (_)_ __   ___/ ___|_   _  __ _ _ __ __| |
 | |\/| | | '_ \ / _ \___ \ | | |/ _` | '__/ _` |
 | |  | | | | | |  __/___) | |_| | (_| | | | (_| |
 |_|  |_|_|_| |_|\___|____/ \__,_|\__,_|_|  \__,_|

 轻量级服务器监控 & 挖矿检测守护进程
BANNER
echo -e "${NC}"

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本${NC}"
    echo "用法: sudo bash install.sh"
    exit 1
fi

# 检查系统
echo -e "${BLUE}[1/6]${NC} 检查系统环境..."
ARCH=$(uname -m)
OS=$(lsb_release -is 2>/dev/null || cat /etc/os-release 2>/dev/null | grep ^ID= | cut -d= -f2 | tr -d '"')
echo "  操作系统: ${OS}"
echo "  架构: ${ARCH}"
echo "  内核: $(uname -r)"

# 检查依赖
echo -e "${BLUE}[2/6]${NC} 检查依赖..."
DEPS=("bash" "awk" "grep" "sed" "ps" "curl" "ss")
MISSING=()
for dep in "${DEPS[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
        MISSING+=("$dep")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo -e "${YELLOW}  安装缺少的依赖: ${MISSING[*]}${NC}"
    apt-get update -qq && apt-get install -y -qq coreutils procps curl iproute2 2>/dev/null || true
fi
echo -e "${GREEN}  ✓ 所有依赖已满足${NC}"

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 创建安装目录
echo -e "${BLUE}[3/6]${NC} 安装文件..."
mkdir -p "$INSTALL_DIR/lib"
mkdir -p "$LOG_DIR"
mkdir -p "$STATE_DIR"

# 复制文件
cp "$SCRIPT_DIR/mineguard.sh" "$BIN_DIR/mineguard"
chmod +x "$BIN_DIR/mineguard"

cp "$SCRIPT_DIR/lib/"*.sh "$INSTALL_DIR/lib/"
chmod +x "$INSTALL_DIR/lib/"*.sh

cp "$SCRIPT_DIR/mining_signatures.txt" "$INSTALL_DIR/"

# 配置文件（不覆盖已有配置）
if [ -f "$INSTALL_DIR/config.conf" ]; then
    echo -e "${YELLOW}  ⚠ 配置文件已存在，保留现有配置${NC}"
    cp "$SCRIPT_DIR/config.conf" "$INSTALL_DIR/config.conf.new"
    echo "  新配置已保存为 $INSTALL_DIR/config.conf.new"
else
    cp "$SCRIPT_DIR/config.conf" "$INSTALL_DIR/config.conf"
fi

echo -e "${GREEN}  ✓ 文件已安装到 $INSTALL_DIR${NC}"

# 创建 systemd 服务
echo -e "${BLUE}[4/6]${NC} 配置 systemd 服务..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=MineGuard - 轻量级服务器监控 & 挖矿检测
Documentation=https://github.com/unbridled-41/mineguard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/mineguard start
ExecStop=${BIN_DIR}/mineguard stop
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mineguard

# 安全加固
NoNewPrivileges=no
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${LOG_DIR} ${STATE_DIR} /var/run
PrivateTmp=true

# 资源限制
MemoryMax=64M
CPUQuota=10%

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
echo -e "${GREEN}  ✓ systemd 服务已创建${NC}"

# 配置提示
echo -e "${BLUE}[5/6]${NC} 配置通知渠道..."
echo ""
echo -e "${YELLOW}  ⚠ 请编辑配置文件以启用通知:${NC}"
echo "  ${GREEN}sudo nano $INSTALL_DIR/config.conf${NC}"
echo ""
echo "  Telegram 配置:"
echo "    1. 在 Telegram 中搜索 @BotFather 创建 Bot"
echo "    2. 获取 Bot Token"
echo "    3. 获取 Chat ID（发送消息给 @userinfobot）"
echo "    4. 在 config.conf 中设置:"
echo "       TELEGRAM_ENABLED=1"
echo "       TELEGRAM_BOT_TOKEN=\"your-token\""
echo "       TELEGRAM_CHAT_ID=\"your-chat-id\""
echo ""
echo "  Webhook 配置（企业微信/钉钉）:"
echo "    1. 在 config.conf 中设置:"
echo "       WEBHOOK_ENABLED=1"
echo "       WEBHOOK_URL=\"your-webhook-url\""
echo ""

# 完成
echo -e "${BLUE}[6/6]${NC} 安装完成！"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}  MineGuard 已成功安装！${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  常用命令:"
echo "    ${GREEN}sudo systemctl start mineguard${NC}     # 启动服务"
echo "    ${GREEN}sudo systemctl enable mineguard${NC}    # 开机自启"
echo "    ${GREEN}sudo systemctl status mineguard${NC}    # 查看状态"
echo "    ${GREEN}sudo mineguard status${NC}              # 查看详细状态"
echo "    ${GREEN}sudo mineguard check${NC}               # 执行单次检查"
echo "    ${GREEN}sudo mineguard test-notify${NC}         # 测试通知"
echo "    ${GREEN}sudo journalctl -u mineguard -f${NC}    # 查看日志"
echo ""
echo "  配置文件: ${GREEN}$INSTALL_DIR/config.conf${NC}"
echo "  日志文件: ${GREEN}$LOG_DIR/mineguard.log${NC}"
echo ""
echo -e "${YELLOW}  提示: 请先编辑配置文件启用通知，然后启动服务${NC}"
echo ""
