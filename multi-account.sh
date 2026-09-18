#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MULTI_HOME=${DAFAGUO_MULTI_HOME:-"$HOME/.local/share/dafaguo-multi"}
ACCOUNTS_DIR="$MULTI_HOME/accounts"
SYSTEMD_DIR=${DAFAGUO_SYSTEMD_USER_DIR:-"$HOME/.config/systemd/user"}
PYTHON_BIN=${DAFAGUO_PYTHON_BIN:-python3}
APP="$SCRIPT_DIR/neoheberg.py"

usage() {
  cat <<'EOF'
用法：
  multi-account.sh add <账号名> <HH:MM> <环境文件>
  multi-account.sh delete <账号名>
  multi-account.sh start <账号名>
  multi-account.sh stop <账号名>
  multi-account.sh status [账号名]
  multi-account.sh install-timers
  multi-account.sh remove-timers
EOF
}

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
valid_name() { [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; }
valid_time() { [[ ${1:-} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
account_dir() { printf '%s/%s' "$ACCOUNTS_DIR" "$1"; }
require_name() { valid_name "${1:-}" || fail '账号名只能包含字母、数字、下划线和连字符，且不能以符号开头'; }
require_account() { require_name "$1"; [[ -d "$(account_dir "$1")" ]] || fail "账号不存在：$1"; }

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
  if [[ -f "$pid_file" ]]; then
    read -r pid < "$pid_file" || true
    if [[ ${pid:-} =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      printf '账号 %s 已在运行（PID %s）\n' "$name" "$pid"
      return 0
    fi
    rm -f "$pid_file"
  fi
  log_file="$dir/logs/$(date +%F).log"
  (
    set -a
    source "$dir/account.env"
    set +a
    export BROWSER_WORK_DIR="$dir/state"
    export BROWSER_USER_DATA_DIR="$dir/firefox-profile"
    exec "$PYTHON_BIN" "$APP" >>"$log_file" 2>&1
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
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
  printf '已停止账号：%s\n' "$name"
}

status_one() {
  local name=$1 dir pid_file pid schedule
  require_account "$name"
  dir=$(account_dir "$name")
  schedule=$(<"$dir/schedule")
  pid_file="$dir/run.pid"
  if [[ -f "$pid_file" ]]; then
    read -r pid < "$pid_file" || true
    if [[ ${pid:-} =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      printf '%s：运行中，PID %s，每日 %s\n' "$name" "$pid" "$schedule"
      return
    fi
    rm -f "$pid_file"
  fi
  printf '%s：未运行，每日 %s\n' "$name" "$schedule"
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
  start) start_account "$@" ;;
  stop) stop_account "$@" ;;
  status) status_accounts "$@" ;;
  install-timers) install_timers "$@" ;;
  remove-timers) remove_timers "$@" ;;
  -h|--help|help|'') usage ;;
  *) usage >&2; exit 1 ;;
esac
