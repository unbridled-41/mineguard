#!/bin/bash
# ============================================================================
# MineGuard - 卸载脚本
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SERVICE_NAME="mineguard"
INSTALL_DIR="/etc/mineguard"
BIN_DIR="/usr/local/bin"
LOG_DIR="/var/log/mineguard"
STATE_DIR="/var/lib/mineguard"

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本${NC}"
    exit 1
fi

echo "MineGuard 卸载程序"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 确认
read -rp "确定要卸载 MineGuard？(y/N) " confirm
if [ "${confirm,,}" != "y" ]; then
    echo "取消卸载"
    exit 0
fi

# 停止服务
echo -n "停止服务... "
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
echo -e "${GREEN}✓${NC}"

# 删除 systemd 服务
echo -n "删除 systemd 服务... "
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload 2>/dev/null || true
echo -e "${GREEN}✓${NC}"

# 删除可执行文件
echo -n "删除程序文件... "
rm -f "$BIN_DIR/mineguard"
echo -e "${GREEN}✓${NC}"

# 询问是否删除配置
read -rp "是否删除配置文件 ($INSTALL_DIR)？(y/N) " del_config
if [ "${del_config,,}" = "y" ]; then
    rm -rf "$INSTALL_DIR"
    echo -e "配置文件已删除 ${GREEN}✓${NC}"
else
    echo -e "${YELLOW}配置文件已保留${NC}"
fi

# 询问是否删除日志
read -rp "是否删除日志文件 ($LOG_DIR)？(y/N) " del_logs
if [ "${del_logs,,}" = "y" ]; then
    rm -rf "$LOG_DIR"
    echo -e "日志文件已删除 ${GREEN}✓${NC}"
else
    echo -e "${YELLOW}日志文件已保留${NC}"
fi

# 删除状态文件
rm -rf "$STATE_DIR" 2>/dev/null || true

# 删除 PID 文件
rm -f "/var/run/mineguard.pid" 2>/dev/null || true

echo ""
echo -e "${GREEN}MineGuard 已成功卸载${NC}"
