#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MULTI_HOME=${DAFAGUO_MULTI_HOME:-"$HOME/.local/share/dafaguo-multi"}
ACCOUNTS_DIR="$MULTI_HOME/accounts"
SYSTEMD_DIR=${DAFAGUO_SYSTEMD_USER_DIR:-"$HOME/.config/systemd/user"}
PYTHON_BIN=${DAFAGUO_PYTHON_BIN:-python3}
APP="$SCRIPT_DIR/neoheberg.py"
SING_BOX_BIN=${DAFAGUO_SING_BOX_BIN:-}
SING_BOX_HOME="$MULTI_HOME/sing-box"
VLESS_PORT_BASE=${DAFAGUO_VLESS_PORT_BASE:-10810}

usage() {
  cat <<'EOF'
用法：
  multi-account.sh add <账号名> <HH:MM> <环境文件>
  multi-account.sh delete <账号名>
  multi-account.sh start [账号名...]      # 不给名字则启动全部
  multi-account.sh stop [账号名...]       # 不给名字则停止全部
  multi-account.sh restart [账号名...]     # 重启（不给名字则全部）
  multi-account.sh set-proxy <账号名> <代理地址>  # 设置账号代理：socks5://user:pass@host:port 或 vless://…（需 sing-box，自动转本地 SOCKS5）
  multi-account.sh set-proxy <账号名>               # 清除账号代理
  multi-account.sh status [账号名]
  multi-account.sh list                    # 列出全部账号
  multi-account.sh watch [账号名...]        # 收益看护：N 分钟(默认5)无收益自动重启
  multi-account.sh install-watch-timers    # 配置每分钟收益看护 cron
  multi-account.sh remove-watch-timers     # 关闭收益看护 cron
  multi-account.sh install-timers
  multi-account.sh remove-timers
EOF
}

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
valid_name() { [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; }
# 展示用代理地址：隐藏 userinfo 里的密码（保留用户名），避免密码出现在终端输出
mask_proxy() {
  local p=${1:-} proto rest userinfo hostpart user
  [[ $p == *"//"* && $p == *@* ]] || { printf '%s' "$p"; return; }
  proto=${p%%://*}
  rest=${p#*://}
  userinfo=${rest%%@*}
  hostpart=${rest#*@}
  user=${userinfo%%:*}
  if [[ -n "$user" ]]; then
    printf '%s://%s:****@%s' "$proto" "$user" "$hostpart"
  else
    printf '%s://****@%s' "$proto" "$hostpart"
  fi
}
valid_time() { [[ ${1:-} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
account_dir() { printf '%s/%s' "$ACCOUNTS_DIR" "$1"; }
require_name() { valid_name "${1:-}" || fail '账号名只能包含字母、数字、下划线和连字符，且不能以符号开头'; }
require_account() { require_name "$1"; [[ -d "$(account_dir "$1")" ]] || fail "账号不存在：$1"; }
account_exists() { valid_name "${1:-}" && [[ -d "$(account_dir "$1")" ]]; }
all_account_names() {
  local dir
  [[ -d "$ACCOUNTS_DIR" ]] || return 0
  for dir in "$ACCOUNTS_DIR"/*; do
    [[ -d "$dir" ]] || continue
    printf '%s\n' "${dir##*/}"
  done
}
has_accounts() { [[ -d "$ACCOUNTS_DIR" ]] && compgen -G "$ACCOUNTS_DIR/*" >/dev/null; }

# ---- vless:// 节点支持：本机 sing-box 转成 127.0.0.1 上的 SOCKS5 ----
sing_box_bin() {
  if [[ -n "$SING_BOX_BIN" ]]; then printf '%s' "$SING_BOX_BIN"; return 0; fi
  command -v sing-box >/dev/null 2>&1 && { command -v sing-box; return 0; }
  [[ -x /usr/local/bin/sing-box ]] && { printf '/usr/local/bin/sing-box'; return 0; }
  return 1
}

# 解析 vless:// URL，输出 TSV：uuid 主机 端口 SNI 传输 path Host头 tls(1/0)
# 兼容两种格式：标准 vless://uuid@host:port?security=tls&type=ws&...
# 与 Snip 风格 vless://base64(user:uuid@host:port)?peer=..&obfs=websocket&path=..
parse_vless() {
  python3 - "$1" <<'PY'
import base64, sys
from urllib.parse import urlparse, parse_qs

url = sys.argv[1]
try:
    u = urlparse(url)
    if u.scheme != "vless":
        sys.exit("协议不是 vless")
    netloc = u.netloc
    if "@" in netloc:
        user_info, hostpart = netloc.rsplit("@", 1)
    else:
        raw = netloc + "=" * (-len(netloc) % 4)
        try:
            decoded = base64.b64decode(raw).decode()
        except Exception:
            sys.exit("无法解码节点信息（不是 base64，也没有 uuid@host:port）")
        if "@" not in decoded:
            sys.exit("无法解析节点信息")
        user_info, hostpart = decoded.rsplit("@", 1)
    if ":" in hostpart:
        host, port_s = hostpart.rsplit(":", 1)
        port = int(port_s)
    else:
        host, port = hostpart, 443
    uuid = user_info.split(":")[-1].strip()
    if not uuid or not host:
        sys.exit("缺少 uuid 或服务器地址")
    q = {k: v[0] for k, v in parse_qs(u.query).items()}
    sni = q.get("sni") or q.get("peer") or q.get("serverName") or ""
    hosthdr = q.get("host") or q.get("Host") or q.get("obfsParam") or sni
    t = (q.get("type") or q.get("obfs") or "tcp").lower()
    if t in ("websocket", "ws"):
        t = "ws"
    elif t in ("httpupgrade",):
        t = "httpupgrade"
    elif t == "tcp":
        t = "tcp"
    else:
        sys.exit("暂不支持的传输方式：%s（目前支持 ws/httpupgrade/tcp）" % t)
    path = q.get("path") or ""
    if t == "tcp" and path:
        sys.exit("tcp 传输不应带 path 参数")
    tls = 1 if (q.get("security") == "tls" or q.get("tls") == "1" or sni) else 0
    if tls and not sni:
        sni = host
    print("\t".join([uuid, host, str(port), sni, t, path, hosthdr, str(tls)]))
except SystemExit as e:
    if str(e):
        print(str(e), file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print("vless 解析失败：%s" % e, file=sys.stderr)
    sys.exit(1)
PY
}

# 生成 sing-box 配置（vless 出站 + 本地 socks 入站）
# 参数：config port uuid host dport sni transport path hosthdr tls
vless_write_config() {
  python3 - "$@" <<'PY'
import json, sys
config, port, uuid, host, dport, sni, t, path, hosthdr, tls = sys.argv[1:11]
out = {
    "type": "vless",
    "tag": "vless-out",
    "server": host,
    "server_port": int(dport),
    "uuid": uuid,
}
if tls == "1":
    out["tls"] = {"enabled": True, "server_name": sni}
if t == "ws":
    tr = {"type": "ws"}
    if path:
        tr["path"] = path
    if hosthdr:
        tr["headers"] = {"Host": hosthdr}
    out["transport"] = tr
elif t == "httpupgrade":
    tr = {"type": "httpupgrade"}
    if path:
        tr["path"] = path
    if hosthdr:
        tr["host"] = hosthdr
    out["transport"] = tr
doc = {
    "log": {"level": "warning", "timestamp": True, "output": config.rsplit(".json", 1)[0] + ".log"},
    "inbounds": [{"type": "socks", "tag": "socks-in", "listen": "127.0.0.1",
                  "listen_port": int(port), "users": []}],
    "outbounds": [out],
}
with open(config, "w") as f:
    json.dump(doc, f, indent=2)
PY
}

# 取 127.0.0.1 上空闲的 TCP 端口
alloc_free_port() {
  local p
  for p in $(seq "$VLESS_PORT_BASE" $((VLESS_PORT_BASE + 99))); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

# 确保某节点的 sing-box 实例在跑；$1=bin $2=config
vless_ensure_running() {
  local bin=$1 config=$2 pidfile pid
  pidfile="$config.pid"
  if [[ -f "$pidfile" ]]; then
    read -r pid < "$pidfile" || true
    if [[ ${pid:-} =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    rm -f "$pidfile"
  fi
  mkdir -p "$(dirname "$config")"
  if command -v setsid >/dev/null 2>&1; then
    setsid "$bin" run -c "$config" >/dev/null 2>&1 &
  else
    nohup "$bin" run -c "$config" >/dev/null 2>&1 &
  fi
  pid=$!
  printf '%s\n' "$pid" > "$pidfile"
  sleep 1
  kill -0 "$pid" 2>/dev/null || fail "sing-box 启动失败：$config（详见 ${config%.json}.log）"
}

# 核心：按 vless URL 生成配置并确保 sing-box 运行，输出本地 SOCKS 端口
# 参数：$1=账号目录 $2=vless URL
vless_apply() {
  local dir=$1 url=$2 bin config id port line
  local v_uuid v_host v_dport v_sni v_trans v_path v_hosthdr v_tls
  bin=$(sing_box_bin) || fail '未找到 sing-box，无法启用 vless:// 节点（请先安装 sing-box）'
  line=$(parse_vless "$url") || fail "无法解析该 vless:// 节点"
  IFS=$'\t' read -r v_uuid v_host v_dport v_sni v_trans v_path v_hosthdr v_tls <<< "$line"
  id=$(printf '%s' "$url" | md5sum | cut -c1-12)
  mkdir -p "$SING_BOX_HOME"
  config="$SING_BOX_HOME/vless-$id.json"
  if [[ -f "$config" ]]; then
    port=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["inbounds"][0]["listen_port"])' "$config" 2>/dev/null) || port=""
  fi
  [[ ${port:-} =~ ^[0-9]+$ ]] || { port=$(alloc_free_port) || fail '没有可用端口（10810-10909 全被占用）'; }
  vless_write_config "$config" "$port" "$v_uuid" "$v_host" "$v_dport" "$v_sni" "$v_trans" "$v_path" "$v_hosthdr" "$v_tls" \
    || fail "生成 sing-box 配置失败：$config"
  vless_ensure_running "$bin" "$config"
  printf '%s\n' "$port"
}

start_batch() {
  local name failed=0
  if (( $# > 0 )); then
    for name in "$@"; do
      if account_exists "$name"; then
        start_account "$name" || failed=1
      else
        printf '错误：账号不存在：%s（跳过）\n' "${name:-}" >&2
        failed=1
      fi
    done
  else
    has_accounts || { printf '尚未添加账号\n'; return 0; }
    for name in $(all_account_names); do
      start_account "$name" || failed=1
    done
  fi
  if (( failed )); then return 1; fi
  return 0
}

stop_batch() {
  local name failed=0
  if (( $# > 0 )); then
    for name in "$@"; do
      if account_exists "$name"; then
        stop_account "$name" || failed=1
      else
        printf '错误：账号不存在：%s（跳过）\n' "${name:-}" >&2
        failed=1
      fi
    done
  else
    has_accounts || { printf '尚未添加账号\n'; return 0; }
    for name in $(all_account_names); do
      stop_account "$name" || failed=1
    done
  fi
  if (( failed )); then return 1; fi
  return 0
}

restart_batch() {
  local name failed=0 targets=()
  if (( $# > 0 )); then
    for name in "$@"; do
      if account_exists "$name"; then
        targets+=("$name")
      else
        printf '错误：账号不存在：%s（跳过）\n' "${name:-}" >&2
        failed=1
      fi
    done
  else
    for name in $(all_account_names); do
      targets+=("$name")
    done
  fi
  if (( ${#targets[@]} == 0 )); then
    if (( $# > 0 )); then return 1; fi
    printf '尚未添加账号\n'
    return 0
  fi
  for name in "${targets[@]}"; do
    stop_account "$name" || failed=1
    start_account "$name" || failed=1
  done
  if (( failed )); then return 1; fi
  return 0
}

list_accounts() {
  local name any=0
  for name in $(all_account_names); do
    any=1
    printf '%s\n' "$name"
  done
  if (( ! any )); then printf '尚未添加账号\n'; fi
  return 0
}

# ═══════════ 收益看护：N 分钟无收益自动重启 ═══════════
# 收益信号 = 当日日志里“历劫归来”行（每完成一轮广告、余额入账即记录）。
# 超过 DAFAGUO_NO_GAIN_MINUTES（默认 5）分钟没有新收益 → 自动 restart 该账号。
NO_GAIN_MINUTES=${DAFAGUO_NO_GAIN_MINUTES:-5}

# 返回账号当日日志最后一次“历劫归来”的 epoch 秒；无记录返回 0
last_gain_epoch() {
  local dir=$1 log last ts
  log="$dir/logs/$(date +%F).log"
  [[ -f "$log" ]] || { echo 0; return 0; }
  last=$(grep -F '历劫归来' "$log" | tail -1)
  [[ -n "$last" ]] || { echo 0; return 0; }
  ts=$(printf '%s\n' "$last" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1)
  if [[ -n "$ts" ]] && date -d "$ts" +%s 2>/dev/null; then
    return 0
  fi
  echo 0
}

watch_account() {
  local name=${1:-} dir pid_file pid log last now age
  require_account "$name"
  dir=$(account_dir "$name")
  pid_file="$dir/run.pid"
  # 未运行：不在这里补启动，交给每日定时器；仅当进程意外死亡时自恢复
  if [[ ! -f "$pid_file" ]]; then
    printf 'watch[%s]: 未运行（无 PID 文件），交由每日定时启动\n' "$name"
    return 0
  fi
  read -r pid < "$pid_file" || true
  if ! ([[ ${pid:-} =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null); then
    printf 'watch[%s]: 进程已死 (PID %s)，自动重启\n' "$name" "${pid:-unknown}"
    rm -f "$pid_file"
    start_account "$name"
    return 0
  fi
  last=$(last_gain_epoch "$dir")
  if (( ! last )); then
    printf 'watch[%s]: 今日日志尚无“历劫归来”收益记录，跳过\n' "$name"
    return 0
  fi
  now=$(date +%s)
  age=$(( now - last ))
  if (( age >= NO_GAIN_MINUTES * 60 )); then
    printf 'watch[%s]: 已 %d 分钟无收益(超过 %d 分钟)，自动重启\n' \
      "$name" "$(( age / 60 ))" "$NO_GAIN_MINUTES"
    restart_account "$name"
  else
    printf 'watch[%s]: 正常，最近收益于 %d 分钟前\n' "$name" "$(( age / 60 ))"
  fi
}

watch_batch() {
  local name found=0
  if (( $# > 0 )); then
    for name in "$@"; do
      account_exists "$name" || { printf '错误：账号不存在：%s（跳过）\n' "$name" >&2; found=1; continue; }
      recommended=1
      watch_account "$name"
    done
    return 0
  fi
  [[ -d "$ACCOUNTS_DIR" ]] || { printf '尚未添加账号\n'; return 0; }
  for dir in "$ACCOUNTS_DIR"/*; do
    [[ -d "$dir" ]] || continue
    found=1
    watch_account "${dir##*/}"
  done
  (( found )) || printf '尚未添加账号\n'
  return 0
}

# 配置每分钟看护 cron
install_watch_cron() {
  local tag="# DAFAGUO-V1-WATCH"
  local cronline="* * * * * DAFAGUO_MULTI_HOME=$MULTI_HOME bash \"$SCRIPT_DIR/multi-account.sh\" watch >> \"$MULTI_HOME/cron.log\" 2>&1 $tag"
  ( crontab -l 2>/dev/null | grep -vF "$tag"; printf '%s\n' "$cronline" ) | crontab -
  if crontab -l | grep -qF "$tag"; then
    printf '已配置每分钟收益看护 cron (无收益 %d 分钟自动重启)\n' "$NO_GAIN_MINUTES"
  else
    printf 'cron 写入失败，可手动执行: %s watch\n' "$SCRIPT_DIR/multi-account.sh"
  fi
}

# 关闭看护 cron
remove_watch_cron() {
  local tag="# DAFAGUO-V1-WATCH"
  crontab -l 2>/dev/null | grep -vF "$tag" | crontab - || true
  printf '已关闭收益看护 cron\n'
}

reload_systemd() {
  if [[ $SYSTEMD_DIR == "$HOME/.config/systemd/user" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
}

add_account() {
  local name=${1:-} schedule=${2:-} source_env=${3:-} dir
  require_name "$name"
  valid_time "$schedule" || fail '每日启动时间必须为 HH:MM（00:00 至 23:59）'
  [[ -f "$source_env" ]] || fail '环境文件不存在'
  dir=$(account_dir "$name")
  [[ ! -e "$dir" ]] || fail "账号已存在：$name"
  umask 077
  mkdir -p "$dir/logs" "$dir/firefox-profile" "$dir/state"
  cp -- "$source_env" "$dir/account.env"
  chmod 600 "$dir/account.env"
  printf '%s\n' "$schedule" > "$dir/schedule"
  chmod 600 "$dir/schedule"
  printf '已安全添加账号：%s（每日 %s）\n' "$name" "$schedule"
}

delete_account() {
  local name=${1:-} dir
  require_account "$name"
  stop_account "$name" >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_DIR/dafaguo-$name.service" "$SYSTEMD_DIR/dafaguo-$name.timer"
  dir=$(account_dir "$name")
  rm -rf -- "$dir"
  reload_systemd
  printf '已删除账号：%s\n' "$name"
}

start_account() {
  local name=${1:-} dir pid_file log_file pid
  require_account "$name"
  dir=$(account_dir "$name")
  pid_file="$dir/run.pid"
  # 清理该账号 profile 上残留的 Firefox 进程：
  # 崩溃/被杀的旧实例会残留（占内存且占用 marionette 端口 2828），
  # 导致新实例 "Could not bind to port 2828" 后连接失败。
  pkill -9 -f "profile $dir/firefox-profile" 2>/dev/null || true
  sleep 1
  if [[ -f "$pid_file" ]]; then
    read -r pid < "$pid_file" || true
    if [[ ${pid:-} =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      printf '账号 %s 已在运行（PID %s）\n' "$name" "$pid"
      return 0
    fi
    rm -f "$pid_file"
  fi
  # 自恢复：该账号配置了 vless 节点时，确保对应 sing-box 实例在跑
  # （VPS 重启后定时任务拉起账号时会自动把代理带起来）
  if [[ -f "$dir/vless-source" ]]; then
    vless_apply "$dir" "$(cat "$dir/vless-source")" >/dev/null
  fi
  log_file="$dir/logs/$(date +%F).log"
  # 组装启动命令：无显示环境走 xvfb-run；setsid 脱离会话（SSH 断开不影响）
  local -a launch=()
  if command -v setsid >/dev/null 2>&1; then
    launch+=(setsid)
  fi
  if [[ -z "${DISPLAY:-}" ]] && command -v xvfb-run >/dev/null 2>&1; then
    launch+=(xvfb-run -a -s "-screen 0 1024x768x24")
  fi
  launch+=("$PYTHON_BIN" "$APP")
  (
    set -a
    source "$dir/account.env"
    set +a
    export BROWSER_WORK_DIR="$dir/state"
    export BROWSER_USER_DATA_DIR="$dir/firefox-profile"
    # LXC/容器内 Firefox 沙箱会导致调试端口不开，必须禁用
    exec env \
      MOZ_DISABLE_CONTENT_SANDBOX=1 \
      MOZ_DISABLE_GMP_SANDBOX=1 \
      MOZ_DISABLE_RDD_SANDBOX=1 \
      MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1 \
      MOZ_DISABLE_GPU_SANDBOX=1 \
      "${launch[@]}" >>"$log_file" 2>&1
  ) &
  pid=$!
  printf '%s\n' "$pid" > "$pid_file"
  chmod 600 "$pid_file"
  printf '已启动账号：%s（PID %s）\n' "$name" "$pid"
}

stop_account() {
  local name=${1:-} dir pid_file pid
  require_account "$name"
  dir=$(account_dir "$name")
  pid_file="$dir/run.pid"
  if [[ ! -f "$pid_file" ]]; then
    printf '账号 %s 未运行\n' "$name"
    return 0
  fi
  read -r pid < "$pid_file" || true
  if [[ ${pid:-} =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    # 整组终止（setsid 启动的进程自成进程组，可带走 xvfb-run/Xvfb/Firefox 全家）
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
  printf '已停止账号：%s\n' "$name"
}

set_proxy() {
  local name=${1:-} proxy=${2:-} dir env_file line tmp found=0 port
  require_account "$name"
  dir=$(account_dir "$name")
  env_file="$dir/account.env"
  [[ -f "$env_file" ]] || fail "账号凭证文件不存在：$env_file"
  # vless:// 节点：本机 sing-box 转成 127.0.0.1 的 SOCKS5 再交给账号
  local vless_note=0
  if [[ $proxy == vless://* ]]; then
    port=$(vless_apply "$dir" "$proxy")
    printf '%s\n' "$proxy" > "$dir/vless-source"
    chmod 600 "$dir/vless-source"
    vless_note=1
    proxy="socks5://127.0.0.1:$port"
  elif [[ -z "$proxy" && -f "$dir/vless-source" ]]; then
    rm -f "$dir/vless-source"
  fi
  tmp=$(mktemp) || fail '无法创建临时文件'
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ $line =~ ^[[:space:]]*PROXY[[:space:]]*= ]]; then
      found=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$env_file"
  if [[ -n "$proxy" ]]; then
    printf 'PROXY=%q\n' "$proxy" >> "$tmp"
  elif (( found )); then
    : # 已删除原 PROXY 行
  else
    printf 'PROXY=\n' >> "$tmp"
  fi
  cat "$tmp" > "$env_file"
  chmod 600 "$env_file"
  rm -f "$tmp"
  if [[ -n "$proxy" ]]; then
    if (( vless_note )); then
      printf '账号 %s 已启用 vless 节点：本地 SOCKS5 127.0.0.1:%s\n' "$name" "$port"
    else
      printf '账号 %s 代理已设置：%s\n' "$name" "$(mask_proxy "$proxy")"
    fi
  else
    printf '账号 %s 代理已清除\n' "$name"
  fi
  printf '重启该账号后生效：multi-account.sh restart %s\n' "$name"
}

status_one() {
  local name=$1 dir pid_file pid schedule proxy_line proxy_val
  require_account "$name"
  dir=$(account_dir "$name")
  schedule=$(<"$dir/schedule")
  proxy_val=""
  if [[ -f "$dir/account.env" ]]; then
    proxy_line=$(grep -E '^[[:space:]]*PROXY[[:space:]]*=' "$dir/account.env" 2>/dev/null | tail -1) || true
    if [[ -n "$proxy_line" ]]; then
      proxy_val=${proxy_line#*=}
      proxy_val=${proxy_val#\"}; proxy_val=${proxy_val%\"}
      proxy_val=${proxy_val#\'}; proxy_val=${proxy_val%\'}
    fi
  fi
  pid_file="$dir/run.pid"
  if [[ -n "$proxy_val" ]]; then
    proxy_val=$(mask_proxy "$proxy_val")
    if [[ -f "$dir/vless-source" ]]; then
      proxy_val="vless→$proxy_val"
    fi
  fi
  if [[ -f "$pid_file" ]]; then
    read -r pid < "$pid_file" || true
    if [[ ${pid:-} =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      printf '%s：\033[32m运行中\033[0m，PID %s，每日 %s，代理 %s\n' \
        "$name" "$pid" "$schedule" "${proxy_val:-(无)}"
      return
    fi
    rm -f "$pid_file"
  fi
  printf '%s：\033[31m未运行\033[0m，每日 %s，代理 %s\n' "$name" "$schedule" "${proxy_val:-(无)}"
}

status_accounts() {
  local name=${1:-} dir found=0
  if [[ -n "$name" ]]; then status_one "$name"; return; fi
  [[ -d "$ACCOUNTS_DIR" ]] || { printf '尚未添加账号\n'; return; }
  for dir in "$ACCOUNTS_DIR"/*; do
    [[ -d "$dir" ]] || continue
    found=1
    status_one "${dir##*/}"
  done
  (( found )) || printf '尚未添加账号\n'
}

install_timers() {
  local dir name schedule quoted_script
  mkdir -p "$SYSTEMD_DIR"
  quoted_script=$(printf '%q' "$SCRIPT_DIR/multi-account.sh")
  [[ -d "$ACCOUNTS_DIR" ]] || fail '尚未添加账号'
  for dir in "$ACCOUNTS_DIR"/*; do
    [[ -d "$dir" ]] || continue
    name=${dir##*/}
    schedule=$(<"$dir/schedule")
    cat > "$SYSTEMD_DIR/dafaguo-$name.service" <<EOF
[Unit]
Description=dafaguo 多账号任务：$name

[Service]
Type=forking
ExecStart=$quoted_script start $name
ExecStop=$quoted_script stop $name
RemainAfterExit=yes
EOF
    cat > "$SYSTEMD_DIR/dafaguo-$name.timer" <<EOF
[Unit]
Description=dafaguo 每日定时启动：$name

[Timer]
OnCalendar=*-*-* $schedule:00
Persistent=true
Unit=dafaguo-$name.service

[Install]
WantedBy=timers.target
EOF
    chmod 644 "$SYSTEMD_DIR/dafaguo-$name.service" "$SYSTEMD_DIR/dafaguo-$name.timer"
    if [[ $SYSTEMD_DIR == "$HOME/.config/systemd/user" ]] && command -v systemctl >/dev/null 2>&1; then
      systemctl --user enable --now "dafaguo-$name.timer" >/dev/null
    fi
  done
  reload_systemd
  printf '已安装所有账号的用户级定时器\n'
}

remove_timers() {
  local file unit
  mkdir -p "$SYSTEMD_DIR"
  for file in "$SYSTEMD_DIR"/dafaguo-*.timer; do
    [[ -e "$file" ]] || continue
    unit=${file##*/}
    if [[ $SYSTEMD_DIR == "$HOME/.config/systemd/user" ]] && command -v systemctl >/dev/null 2>&1; then
      systemctl --user disable --now "$unit" >/dev/null 2>&1 || true
    fi
  done
  rm -f "$SYSTEMD_DIR"/dafaguo-*.timer "$SYSTEMD_DIR"/dafaguo-*.service
  reload_systemd
  printf '已移除所有多账号定时器\n'
}

mkdir -p "$ACCOUNTS_DIR"
command=${1:-}
shift || true
case "$command" in
  add) add_account "$@" ;;
  delete|remove) delete_account "$@" ;;
  start) start_batch "$@" ;;
  stop) stop_batch "$@" ;;
  restart) restart_batch "$@" ;;
  set-proxy|proxy) set_proxy "$@" ;;
  status) status_accounts "$@" ;;
  list) list_accounts "$@" ;;
  watch) if (( $# > 0 )); then watch_batch "$@"; else watch_batch; fi ;;
  install-watch-timers) install_watch_cron ;;
  remove-watch-timers) remove_watch_cron ;;
  install-timers) install_timers "$@" ;;
  remove-timers) remove_timers "$@" ;;
  -h|--help|help|'') usage ;;
  *) usage >&2; exit 1 ;;
esac
