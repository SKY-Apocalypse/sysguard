#!/usr/bin/env bash
#
# Automated tests for sysguard (CLI flags, JSON output, dry-run, alert logic).
# Usage: tests/test_sysguard.sh
# No real network calls are made: `curl` is replaced by a recording stub.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSGUARD="${SCRIPT_DIR}/../bin/sysguard.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sysguard-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

TESTS_RUN=0
TESTS_FAILED=0
OUT=""
ERR=""
RC=0

# --- curl stub: records its arguments and stdin so we can assert on them ------
STUB_BIN="${TMP_ROOT}/bin"
CURL_LOG="${TMP_ROOT}/curl.log"
export CURL_LOG
mkdir -p "$STUB_BIN"
cat >"${STUB_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
{
  printf 'ARGS:'
  printf ' %s' "$@"
  printf '\n'
  cat
} >>"$CURL_LOG"
exit 0
EOF
chmod +x "${STUB_BIN}/curl"
export PATH="${STUB_BIN}:${PATH}"
export NO_COLOR=1

# --- helpers -------------------------------------------------------------------
pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf '  PASS  %s\n' "$1"
}

fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  FAIL  %s\n' "$1"
  if [[ -n "${2:-}" ]]; then
    printf '        %s\n' "$2"
  fi
}

skip() {
  printf '  SKIP  %s\n' "$1"
}

run() {
  OUT="$("$SYSGUARD" "$@" 2>"${TMP_ROOT}/stderr")"
  RC=$?
  ERR="$(cat "${TMP_ROOT}/stderr")"
}

assert_rc() {
  if [[ "$RC" -eq "$1" ]]; then pass "$2"; else fail "$2" "expected exit $1, got $RC"; fi
}

assert_contains() {
  if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3" "missing: $2"; fi
}

assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3" "unexpected: $2"; fi
}

assert_empty() {
  if [[ -z "$1" ]]; then pass "$2"; else fail "$2" "expected no output, got: ${1:0:80}"; fi
}

assert_file_exists() {
  if [[ -e "$1" ]]; then pass "$2"; else fail "$2" "missing file: $1"; fi
}

assert_file_missing() {
  if [[ ! -e "$1" ]]; then pass "$2"; else fail "$2" "file should not exist: $1"; fi
}

json_valid() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import json, sys; json.load(sys.stdin)' >/dev/null 2>&1
  elif command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -e . >/dev/null 2>&1
  else
    return 2
  fi
}

assert_json() {
  json_valid "$1"
  case $? in
    0) pass "$2" ;;
    2) skip "$2 (no python3/jq available)" ;;
    *) fail "$2" "invalid JSON: ${1:0:120}" ;;
  esac
}

# make_conf NAME KEY=VALUE... -> prints the path of a temporary config file
make_conf() {
  local file="${TMP_ROOT}/$1.conf" kv
  shift
  : >"$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >>"$file"
  done
  printf '%s' "$file"
}

# Healthy baseline: nothing can exceed 100%, no services.
healthy_conf() {
  make_conf "$1" CPU_THRESHOLD=100 MEM_THRESHOLD=100 SWAP_THRESHOLD=100 \
    DISK_THRESHOLD=100 DISK_PATH=/ SERVICES_TO_CHECK= \
    "LOG_FILE=${TMP_ROOT}/$1.log" CPU_SAMPLE_SECONDS=0.2 "${@:2}"
}

# Breach: any machine uses more than 0% memory.
breach_conf() {
  make_conf "$1" CPU_THRESHOLD=100 MEM_THRESHOLD=0 SWAP_THRESHOLD=100 \
    DISK_THRESHOLD=100 DISK_PATH=/ SERVICES_TO_CHECK= \
    "LOG_FILE=${TMP_ROOT}/$1.log" CPU_SAMPLE_SECONDS=0.2 \
    "WEBHOOK_URL=https://hooks.example.test/services/SECRET" "${@:2}"
}

# --- tests ---------------------------------------------------------------------
echo "CLI flags"
run --help
assert_rc 0 "--help exits 0"
assert_contains "$OUT" "Usage:" "--help prints usage"
assert_contains "$OUT" "--dry-run" "--help documents --dry-run"

run -h
assert_rc 0 "-h exits 0"

run --version
assert_rc 0 "--version exits 0"
assert_contains "$OUT" "sysguard" "--version prints name"

run --bogus
assert_rc 2 "unknown flag exits 2"
assert_contains "$ERR" "unknown option" "unknown flag explains the error"

run --config
assert_rc 2 "--config without a path exits 2"

run --config "${TMP_ROOT}/does-not-exist.conf"
assert_rc 2 "missing explicit config exits 2"

echo "Config validation"
CONF="$(make_conf bad_threshold CPU_THRESHOLD=abc "LOG_FILE=${TMP_ROOT}/x.log")"
run --config "$CONF" --dry-run
assert_rc 2 "non-numeric threshold exits 2"

CONF="$(make_conf out_of_range MEM_THRESHOLD=150 "LOG_FILE=${TMP_ROOT}/x.log")"
run --config "$CONF" --dry-run
assert_rc 2 "threshold above 100 exits 2"

CONF="$(make_conf unknown_key FOO=bar)"
run --config "$CONF" --dry-run
assert_rc 2 "unknown setting exits 2"

CONF="$(make_conf bad_url WEBHOOK_URL=ftp://nope "LOG_FILE=${TMP_ROOT}/x.log")"
run --config "$CONF" --dry-run
assert_rc 2 "invalid webhook URL exits 2"

CONF="$(healthy_conf bad_disk DISK_PATH=/definitely/not/a/mount)"
run --config "$CONF" --dry-run
assert_rc 2 "unreadable DISK_PATH exits 2"

CONF="$(healthy_conf bad_log LOG_FILE=/dev/null/nope/sysguard.log)"
run --config "$CONF"
assert_rc 2 "unwritable log file exits 2"

CONF="$(make_conf quoted \
  'CPU_THRESHOLD="100"  # trailing comment' "MEM_THRESHOLD='100'" \
  SWAP_THRESHOLD=100 DISK_THRESHOLD=100 "LOG_FILE=${TMP_ROOT}/quoted.log" \
  CPU_SAMPLE_SECONDS=0.2)"
run --config "$CONF" --json --dry-run
assert_rc 0 "quoted values and inline comments are parsed"
assert_contains "$OUT" '"cpu": {"usage_percent"' "parsed config yields metrics"

echo "Healthy run"
CONF="$(healthy_conf healthy)"
run --config "$CONF"
assert_rc 0 "healthy system exits 0"
assert_contains "$OUT" "[OK" "human output has OK lines"
assert_contains "$OUT" "All checks passed" "human output has summary"
assert_not_contains "$OUT" $'\033' "no ANSI colors when not a terminal"
assert_file_exists "${TMP_ROOT}/healthy.log" "log file is written"
assert_not_contains "$(cat "${TMP_ROOT}/healthy.log")" $'\033' "log file is plain text"

echo "JSON output"
CONF="$(healthy_conf json_ok)"
run --config "$CONF" --json --dry-run
assert_rc 0 "--json exits 0 when healthy"
assert_json "$OUT" "--json output is valid JSON"
assert_contains "$OUT" '"status": "healthy"' "--json reports healthy status"
assert_contains "$OUT" '"load_average"' "--json includes load averages"
assert_contains "$OUT" '"swap"' "--json includes swap"
assert_not_contains "$OUT" "[OK" "--json prints no human-readable lines"

CONF="$(breach_conf json_bad)"
run --config "$CONF" --json --dry-run
assert_rc 1 "--json exits 1 on breach"
assert_json "$OUT" "--json output is valid JSON during an alert"
assert_contains "$OUT" '"status": "alert"' "--json reports alert status"
assert_contains "$OUT" "Memory usage is" "--json lists the alert text"
assert_contains "$OUT" '"pid":' "--json includes top processes on alert"

CONF="$(healthy_conf multi_disk DISK_PATH=/,/tmp)"
run --config "$CONF" --json --dry-run
assert_rc 0 "multiple mount points are accepted"
assert_json "$OUT" "multi-disk JSON is valid"
assert_contains "$OUT" '"path": "/tmp"' "second mount point is reported"

echo "Alert logic"
CONF="$(breach_conf breach)"
: >"$CURL_LOG"
run --config "$CONF"
assert_rc 1 "threshold breach exits 1"
assert_contains "$OUT" "[ALERT]" "breach is flagged ALERT"
assert_contains "$OUT" "Top memory #1" "top memory processes are listed on alert"
assert_contains "$OUT" "Top CPU #1" "top CPU processes are listed on alert"
assert_file_exists "${TMP_ROOT}/breach.log" "breach is logged"
assert_contains "$(cat "${TMP_ROOT}/breach.log")" "[ALERT]" "log file contains the alert"
assert_contains "$(cat "$CURL_LOG" 2>/dev/null)" "sysguard alert" "webhook payload is sent on breach"
assert_contains "$(cat "$CURL_LOG" 2>/dev/null)" "https://hooks.example.test/services/SECRET" "webhook URL goes via stdin"
assert_not_contains "$(grep '^ARGS:' "$CURL_LOG" 2>/dev/null)" "SECRET" "webhook URL is not in curl arguments"

CONF="$(healthy_conf nohook WEBHOOK_URL=https://hooks.example.test/x)"
: >"$CURL_LOG"
run --config "$CONF"
assert_rc 0 "no webhook call when healthy (exit 0)"
assert_empty "$(cat "$CURL_LOG")" "webhook is not fired when healthy"

CONF="$(healthy_conf svc_down SERVICES_TO_CHECK=sysguard_no_such_service)"
run --config "$CONF" --dry-run
assert_rc 1 "stopped service triggers exit 1"
assert_contains "$OUT" "sysguard_no_such_service" "stopped service is named in the alert"

if ! [[ -d /run/systemd/system ]] && command -v pgrep >/dev/null 2>&1; then
  CONF="$(healthy_conf svc_up SERVICES_TO_CHECK=bash)"
  run --config "$CONF" --dry-run
  assert_rc 0 "running service passes the check"
  assert_contains "$OUT" "Service 'bash' is running" "running service is reported"
else
  skip "running-service check (systemd host or no pgrep)"
fi

echo "--dry-run"
CONF="$(breach_conf dry)"
: >"$CURL_LOG"
run --config "$CONF" --dry-run
assert_rc 1 "--dry-run still reports exit 1 on breach"
assert_contains "$OUT" "dry-run" "--dry-run announces itself"
assert_contains "$OUT" "would send webhook" "--dry-run describes the webhook it skipped"
assert_file_missing "${TMP_ROOT}/dry.log" "--dry-run writes no log file"
assert_empty "$(cat "$CURL_LOG")" "--dry-run fires no webhook"

echo "--quiet"
CONF="$(healthy_conf quiet_ok)"
run --config "$CONF" --quiet
assert_rc 0 "--quiet exits 0 when healthy"
assert_empty "$OUT" "--quiet prints nothing when healthy"
assert_empty "$(cat "${TMP_ROOT}/quiet_ok.log")" "--quiet writes nothing to the log when healthy"

CONF="$(breach_conf quiet_bad)"
run --config "$CONF" --quiet --dry-run
assert_rc 1 "--quiet exits 1 on breach"
assert_contains "$OUT" "[ALERT]" "--quiet prints output on breach"

CONF="$(healthy_conf quiet_json)"
run --config "$CONF" --quiet --json --dry-run
assert_empty "$OUT" "--quiet --json prints nothing when healthy"

# --- summary -------------------------------------------------------------------
echo
printf '%d tests, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
  exit 1
fi
