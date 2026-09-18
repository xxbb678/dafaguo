# NeoHeberg AFK 一键脚本

自动登录 [NeoHeberg](https://dash.neoheberg.fr) 并挂机刷广告额度，支持 Telegram 余额播报。

- 全程前台浏览器（Firefox）执行，与真实用户一致
- 自动过 Cloudflare 验证、Cap 验证码、【打地鼠】防刷小游戏
- 实时读取余额与今日进度（N/100），每轮打印单轮收益
- 刷满 100/100 后自动汇总并退出
- 支持 Telegram 播报（启动、收盘、异常）

> 仅供学习交流，使用风险自负。

## 🚀 一键安装

    bash <(curl -fsSL https://raw.githubusercontent.com/xxbb678/dafaguo/main/install.sh)

安装过程自动完成：装好 python3-venv / xvfb / xauth → 创建虚拟环境 → 安装 ruyipage → 下载 Firefox 运行时（约百兆，首次较慢）。

## 一键运行

传入凭证并后台启动：

    EMAIL='你的邮箱' PASSWORD='你的密码' \
      TG_BOT_TOKEN='机器人 token' TG_CHAT_ID='chatid' \
      bash <(curl -fsSL https://raw.githubusercontent.com/xxbb678/dafaguo/main/install.sh) run

凭证会写入 `/opt/neoheberg-afk/env`（权限 600），下次只需 `bash install.sh run`，无需重输。

交互菜单：直接运行 `bash install.sh`（无参数）。

## 命令

    install    安装依赖与浏览器运行时（默认）
    run        启动挂机（后台）
    account    填写账号密码
    tg         配置 Telegram 通知（含节点名称）
    balance    实时查余额（每 5 秒刷新）
    status     查看运行状态与最近日志
    schedule   每日定时挂机
    update     更新主脚本到最新版（不动依赖）
    uninstall  卸载（进程、凭证、依赖全删）

更新主脚本（已安装的机器）：

    bash <(curl -fsSL https://raw.githubusercontent.com/xxbb678/dafaguo/main/install.sh) update

## 多账号分时启动

多账号功能由 `multi-account.sh` 单独管理，不修改现有的 `install.sh`、`start.sh` 或单账号目录。每个账号都有独立的环境文件、每日日程、日志、PID、Firefox profile 和运行状态。

先为每个账号准备环境文件，例如 `account-a.env`：

```bash
EMAIL='账号邮箱'
PASSWORD='账号密码'
TG_BOT_TOKEN='可选的机器人 token'
TG_CHAT_ID='可选的 chat id'
NOTIFY_NAME='账号 A'
PROXY='可选代理'
NH_WAIT='30'
```

环境文件应只允许当前用户读取：

```bash
chmod 600 account-a.env
```

添加账号并设置每日启动时间：

```bash
./multi-account.sh add account-a 06:30 account-a.env
./multi-account.sh add account-b 08:15 account-b.env
```

常用命令：

```bash
./multi-account.sh start account-a       # 立即启动指定账号
./multi-account.sh stop account-a        # 停止指定账号
./multi-account.sh status account-a      # 查看单个账号状态
./multi-account.sh status                # 查看全部账号状态
./multi-account.sh delete account-a      # 停止并删除账号及其独立数据
./multi-account.sh install-timers         # 安装并启用所有账号的用户级定时器
./multi-account.sh remove-timers          # 停用并移除多账号定时器
```

账号数据默认保存在 `~/.local/share/dafaguo-multi/accounts/<账号名>/`。环境文件会复制为权限 `600` 的 `account.env`，命令输出和 systemd 单元均不会包含密码。账号名只允许字母、数字、下划线和连字符，防止路径穿越。

`install-timers` 使用 systemd 用户级定时器。若注销后仍需执行，可按系统配置启用 linger：

```bash
loginctl enable-linger "$USER"
```

## 环境要求

- Linux（测试于 Debian/Ubuntu），需能访问目标站点
- **出口 IP 非数据中心（推荐住宅 / WARP 类出口）**。数据中心 IP 会被广告网络直接甩走、跳过结算流程，导致「能运行但不涨币」。

## 依赖

```bash
python3 -m venv venv
venv/bin/pip install ruyipage
venv/bin/python -m ruyipage install   # 下载 Firefox 运行时（约百兆）
apt install -y xvfb
```

脚本会自动定位 `~/.cache/ruyipage/browsers/firefox-*/firefox/firefox`，无需硬编码路径。

## 环境变量

写入 `env` 文件（权限 600），或直接导出：

| 变量 | 必填 | 说明 |
|------|------|------|
| `EMAIL` | 是 | NeoHeberg 登录账号 |
| `PASSWORD` | 是 | 登录密码 |
| `TG_BOT_TOKEN` | 否 | Telegram 机器人 Token |
| `TG_CHAT_ID` | 否 | Telegram chat id |
| `NOTIFY_NAME` | 否 | 节点名称，多台机器共用同一 TG 机器人时用于区分 |
| `PROXY` | 否 | 如 `socks5://user:pass@host:port` |
| `BROWSER_WORK_DIR` | 否 | 工作目录，默认 `/home/browser/browser-work` |
| `BROWSER_USER_DATA_DIR` | 否 | 指定 Firefox profile 目录（保留登录态）|

## 日志样例

```
✅ 纯物理火狐挂机任务开始！余额 13.740000 coins，今日已看 66/100
🎲 触发【打地鼠】防刷游戏，启动自瞄外挂！
🔫 开火 [3/5]
✅ 打地鼠完成，靶子已消失
🎉 历劫归来！第 29 轮完成！余额 14.244600 coins（本轮 +0.034600）已看 67/100
```

## 常用命令

```bash
tail -f /opt/neoheberg-afk/neoheberg.log   # 实时日志
pkill -9 -f neoheberg.py                   # 停止
```
