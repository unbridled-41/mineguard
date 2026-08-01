# MineGuard ⛏️🛡️

**轻量级服务器监控 & 挖矿检测守护进程**

一个极致轻量的 Linux 服务器监控工具，专为检测加密货币挖矿入侵而设计。纯 Bash 实现，资源占用极低，完美兼容 x86_64 和 ARM64 架构。

灵感来源于多个优秀的开源项目：
- [telegram-bash-system-monitoring](https://github.com/russellgrapes/telegram-bash-system-monitoring) - 持续高 CPU 检测逻辑
- [server-guardian](https://github.com/alfiosalanitri/server-guardian) - 系统监控告警框架
- [server-security-toolkit](https://github.com/VertexElite/server-security-toolkit) - 挖矿进程扫描特征

## ✨ 特性

| 特性 | 说明 |
|------|------|
| 🪶 **极致轻量** | 纯 Bash 实现，运行时 RSS ~2MB，CPU < 0.1% |
| 🔄 **跨架构兼容** | 完美支持 x86_64 和 ARM64 (aarch64) |
| 📊 **CPU 监控** | 持续高 CPU 检测，过滤短暂峰值减少误报 |
| 💾 **内存监控** | 内存 + Swap 使用率监控 |
| ⛏️ **挖矿检测** | 多维度检测：进程名/路径/行为/网络连接/crontab |
| 📱 **Telegram 通知** | 实时推送告警到 Telegram Bot |
| 🔗 **Webhook 通知** | 兼容企业微信/钉钉/自定义 Webhook |
| 📧 **邮件通知** | SMTP 邮件告警 |
| 🧊 **告警冷却** | 防止告警轰炸，支持速率限制 |
| ✅ **恢复通知** | 系统恢复正常时自动通知 |
| 🔧 **systemd 集成** | 开机自启、崩溃自动重启 |
| 🔒 **安全加固** | systemd 沙箱隔离、资源限制 |

## 📐 架构

```
┌─────────────────────────────────────────────────┐
│                 MineGuard 守护进程                │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌───────────────┐  │
│  │ CPU 监控  │  │ 内存监控  │  │  挖矿检测模块  │  │
│  │          │  │          │  │               │  │
│  │/proc/stat│  │/proc/mem │  │ • 进程名匹配   │  │
│  │ 持续检测  │  │ Swap 检查 │  │ • 路径分析     │  │
│  └────┬─────┘  └────┬─────┘  │ • 行为评分     │  │
│       │             │        │ • 网络连接     │  │
│       │             │        │ • Crontab 扫描 │  │
│       │             │        └───────┬───────┘  │
│       └──────┬──────┴────────────────┘          │
│              ▼                                   │
│  ┌────────────────────────────────────────────┐  │
│  │            通知分发引擎                      │  │
│  │  ┌──────┐  ┌─────────┐  ┌──────┐          │  │
│  │  │ Tele │  │ Webhook │  │ SMTP │          │  │
│  │  │ gram │  │ 企微/钉钉│  │ 邮件  │          │  │
│  │  └──────┘  └─────────┘  └──────┘          │  │
│  │  告警冷却 ← 速率限制 ← 恢复检测             │  │
│  └────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

## 🚀 快速开始

### 1. 获取代码

```bash
git clone https://github.com/unbridled-41/mineguard.git
cd mineguard
```

### 2. 安装

```bash
sudo bash install.sh
```

### 3. 配置通知

```bash
sudo nano /etc/mineguard/config.conf
```

#### Telegram 配置

1. 在 Telegram 搜索 `@BotFather`，发送 `/newbot` 创建 Bot
2. 记录获得的 **Bot Token**
3. 给你的 Bot 发送一条消息，然后访问 `https://api.telegram.org/bot<TOKEN>/getUpdates` 获取 **Chat ID**
4. 编辑配置文件：

```bash
TELEGRAM_ENABLED=1
TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
TELEGRAM_CHAT_ID="987654321"
```

#### 企业微信 Webhook 配置

```bash
WEBHOOK_ENABLED=1
WEBHOOK_URL="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=YOUR_KEY"
WEBHOOK_TEMPLATE='{"msgtype":"text","text":{"content":"[{{LEVEL}}] {{HOSTNAME}}\n{{TITLE}}\n{{MESSAGE}}\n{{TIMESTAMP}}"}}'
```

#### 钉钉 Webhook 配置

```bash
WEBHOOK_ENABLED=1
WEBHOOK_URL="https://oapi.dingtalk.com/robot/send?access_token=YOUR_TOKEN"
WEBHOOK_TEMPLATE='{"msgtype":"text","text":{"content":"[{{LEVEL}}] {{HOSTNAME}}\n{{TITLE}}\n{{MESSAGE}}\n{{TIMESTAMP}}"}}'
```

### 4. 测试通知

```bash
sudo mineguard test-notify
```

### 5. 启动服务

```bash
# 启动 & 开机自启
sudo systemctl enable --now mineguard

# 查看状态
sudo systemctl status mineguard

# 查看日志
sudo journalctl -u mineguard -f
```

## 🛠 命令参考

```bash
sudo mineguard start          # 前台启动（调试用）
sudo mineguard daemon         # 后台守护进程模式
sudo mineguard stop           # 停止
sudo mineguard restart        # 重启
sudo mineguard status         # 查看状态 & 当前资源
sudo mineguard check          # 执行一次检查
sudo mineguard test-notify    # 测试所有通知渠道
sudo mineguard version        # 版本信息
```

## ⛏️ 挖矿检测原理

MineGuard 使用多维度检测策略，每个维度产生独立的威胁评分：

| 检测维度 | 说明 | 可信度 |
|----------|------|--------|
| **进程名匹配** | 对比 60+ 个已知挖矿程序名称 | 🔴 高 |
| **可疑路径** | 检查进程是否从 /tmp, /dev/shm 等临时目录运行 | 🟡 中 |
| **二进制删除** | 检查进程的可执行文件是否已被删除（隐匿手段） | 🟡 中 |
| **进程伪装** | 检查是否伪装为系统进程（如 kworker）但路径不符 | 🟡 中 |
| **矿池网络** | 检测到已知矿池端口（3333/4444/5555 等）的连接 | 🔴 高 |
| **持久化 Crontab** | 扫描 crontab 中的可疑下载/执行命令 | 🟡 中 |

## 📋 配置项说明

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `CHECK_INTERVAL` | 30 | 检查间隔（秒） |
| `CPU_WARN_THRESHOLD` | 80 | CPU 告警阈值（%） |
| `CPU_CRIT_THRESHOLD` | 95 | CPU 严重告警阈值（%） |
| `CPU_SUSTAINED_COUNT` | 3 | 持续高 CPU 检测次数 |
| `MEM_WARN_THRESHOLD` | 85 | 内存告警阈值（%） |
| `MEM_CRIT_THRESHOLD` | 95 | 内存严重告警阈值（%） |
| `ALERT_COOLDOWN` | 300 | 告警冷却时间（秒） |
| `MAX_ALERTS_PER_HOUR` | 10 | 每小时最大告警数 |
| `AUTO_KILL_MINER` | 0 | 自动终止挖矿进程 |

## 🔒 安全特性

- **systemd 沙箱**: `ProtectSystem=strict`, `PrivateTmp=true`
- **资源限制**: `MemoryMax=64M`, `CPUQuota=10%`
- **无 shell 暴露**: 不监听任何网络端口
- **只读文件系统**: 仅对日志和状态目录有写入权限

## 📁 文件结构

```
/etc/mineguard/
├── config.conf              # 配置文件
├── mining_signatures.txt    # 挖矿特征签名库
└── lib/
    ├── utils.sh             # 工具函数
    ├── notify.sh            # 通知模块
    ├── cpu.sh               # CPU 监控
    ├── memory.sh            # 内存监控
    └── process.sh           # 进程分析 & 挖矿检测

/usr/local/bin/mineguard     # 主程序
/var/log/mineguard/          # 日志目录
/var/lib/mineguard/          # 运行状态数据
```

## ❌ 卸载

```bash
sudo bash uninstall.sh
```

## 📝 自定义挖矿签名

编辑 `/etc/mineguard/mining_signatures.txt` 添加自定义特征：

```
# 进程名（一行一个）
my_custom_miner

# 矿池关键字
POOL:my-mining-pool.com

# 矿池端口
PORT:12345
```

## 🤝 致谢

本项目灵感和部分实现参考了以下优秀的开源项目：

- [russellgrapes/telegram-bash-system-monitoring](https://github.com/russellgrapes/telegram-bash-system-monitoring)
- [alfiosalanitri/server-guardian](https://github.com/alfiosalanitri/server-guardian)
- [VertexElite/server-security-toolkit](https://github.com/VertexElite/server-security-toolkit)
- [Sincan2/System-Monitoring-with-Telegram-Alerts](https://github.com/Sincan2/System-Monitoring-with-Telegram-Alerts)

## 📄 License

MIT License
