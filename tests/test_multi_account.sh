#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO_DIR/multi-account.sh"
SANDBOX="$REPO_DIR/.test-multi-account"
DATA_DIR="$SANDBOX/data"
SYSTEMD_DIR="$SANDBOX/systemd"
SOURCE_ENV="$SANDBOX/source.env"

cleanup() {
  rm -rf "$SANDBOX"
}
trap cleanup EXIT
cleanup
mkdir -p "$DATA_DIR" "$SYSTEMD_DIR"

fail() {
  printf '失败: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "文件不存在: $1"
}

assert_not_file() {
  [[ ! -e "$1" ]] || fail "文件不应存在: $1"
}

assert_contains() {
  local file=$1 text=$2
  grep -Fq -- "$text" "$file" || fail "$file 不包含: $text"
}

assert_mode() {
  local file=$1 expected=$2 actual
  actual=$(stat -c '%a' "$file")
  [[ "$actual" == "$expected" ]] || fail "$file 权限为 $actual，预期 $expected"
}

run_multi() {
  DAFAGUO_MULTI_HOME="$DATA_DIR" \
  DAFAGUO_SYSTEMD_USER_DIR="$SYSTEMD_DIR" \
  DAFAGUO_PYTHON_BIN=/bin/true \
  "$SCRIPT" "$@"
}

[[ -x "$SCRIPT" ]] || fail "multi-account.sh 不存在或不可执行"

cat > "$SOURCE_ENV" <<'ENV'
EMAIL=test@example.com
PASSWORD=not-a-real-password
TG_BOT_TOKEN=
TG_CHAT_ID=
NOTIFY_NAME=测试账号
PROXY=
NH_WAIT=30
ENV
chmod 600 "$SOURCE_ENV"

run_multi add account_a 06:30 "$SOURCE_ENV"
assert_file "$DATA_DIR/accounts/account_a/account.env"
assert_mode "$DATA_DIR/accounts/account_a/account.env" 600
assert_file "$DATA_DIR/accounts/account_a/schedule"
assert_contains "$DATA_DIR/accounts/account_a/schedule" '06:30'
mkdir -p "$DATA_DIR/accounts/account_a/logs" "$DATA_DIR/accounts/account_a/firefox-profile" "$DATA_DIR/accounts/account_a/state"

output=$(run_multi status account_a)
[[ "$output" != *'not-a-real-password'* ]] || fail 'status 泄露了密码'

run_multi start account_a
assert_file "$DATA_DIR/accounts/account_a/run.pid"
run_multi stop account_a
assert_not_file "$DATA_DIR/accounts/account_a/run.pid"

run_multi install-timers
assert_file "$SYSTEMD_DIR/dafaguo-account_a.service"
assert_file "$SYSTEMD_DIR/dafaguo-account_a.timer"
assert_contains "$SYSTEMD_DIR/dafaguo-account_a.timer" 'OnCalendar=*-*-* 06:30:00'
assert_contains "$SYSTEMD_DIR/dafaguo-account_a.service" 'account_a'

run_multi remove-timers
assert_not_file "$SYSTEMD_DIR/dafaguo-account_a.service"
assert_not_file "$SYSTEMD_DIR/dafaguo-account_a.timer"

if run_multi add '../escape' 07:00 "$SOURCE_ENV" >/dev/null 2>&1; then
  fail '接受了不安全的账号名'
fi
if run_multi add account_b 25:99 "$SOURCE_ENV" >/dev/null 2>&1; then
  fail '接受了无效启动时间'
fi

run_multi delete account_a
assert_not_file "$DATA_DIR/accounts/account_a"

printf '全部多账号功能测试通过\n'
