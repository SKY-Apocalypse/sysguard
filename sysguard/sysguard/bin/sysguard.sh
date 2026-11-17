#!/usr/bin/env bash
#
# sysguard - System Health & Resource Monitor
#
# Checks CPU, load, memory, swap, disk and service health, logs the result and
# optionally posts alerts to a Slack/Discord-compatible webhook.
#
# Exit codes: 0 = healthy, 1 = one or more alerts, 2 = configuration/runtime error

set -euo pipefail
set -o errtrace

export LC_ALL=C

readonly SYSGUARD_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
OS="$(uname -s)"
readonly OS

trap 'echo "sysguard: unexpected error (line ${LINENO})" >&2; exit 2' ERR

# ---------------------------------------------------------------------------
# Defaults (overridden by the config file)
# ---------------------------------------------------------------------------
CPU_THRESHOLD=80
MEM_THRESHOLD=80
SWAP_THRESHOLD=50
DISK_THRESHOLD=85
DISK_PATH="/"
_tmp_dir="${TMPDIR:-/tmp}"
LOG_FILE="${_tmp_dir%/}/sysguard.log"
WEBHOOK_URL=""
SERVICES_TO_CHECK=""
CPU_SAMPLE_SECONDS=1

# CLI state
CONFIG_FILE=""
DRY_RUN=0
JSON_OUTPUT=0
QUIET=0
USE_COLOR=0

# Runtime state
HOSTNAME_VALUE="$(uname -n)"
CPU_PCT="0.0"
LOAD_1="0.00"
LOAD_5="0.00"
LOAD_15="0.00"
MEM_PCT="0.0"
SWAP_PCT="0.0"
DISK_RESULTS=""
SERVICE_RESULTS=""
ALERTS=""
ALERT_COUNT=0
TOP_CPU=""
TOP_MEM=""
PLAIN_BUF=""
STDOUT_BUF=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() {
  printf 'sysguard: error: %s\n' "$*" >&2
  exit 2
}

usage() {
  cat <<'EOF'
sysguard - System Health & Resource Monitor

Usage:
  sysguard.sh [options]

Options:
  --config <path>   Use this config file (default lookup: $SYSGUARD_CONFIG,
                    <script dir>/../config/sysguard.conf, /etc/sysguard/sysguard.conf)
  --dry-run         Print results only: no log file writes, no webhook calls
  --json            Print metrics as JSON on stdout
  --quiet, -q       Produce output only when an alert triggers
  --version         Print the version and exit
  --help, -h        Show this help and exit

Exit codes:
  0  healthy
  1  one or more thresholds breached or services down
  2  configuration or runtime error

Settings (config file): CPU_THRESHOLD, MEM_THRESHOLD, SWAP_THRESHOLD,
DISK_THRESHOLD, DISK_PATH, LOG_FILE, WEBHOOK_URL, SERVICES_TO_CHECK,
CPU_SAMPLE_SECONDS. See config/sysguard.conf.example.
EOF
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_number() {
  local re='^[0-9]+([.][0-9]+)?$'
  [[ "$1" =~ $re ]]
}

norm_number() {
  awk -v v="$1" 'BEGIN { printf "%.10g", v + 0 }'
}

exceeds() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# emit LEVEL MESSAGE - buffer a timestamped line for the log and for stdout.
emit() {
  local level="$1" msg="$2" ts tag color="" reset=""
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf -v tag '%-5s' "$level"
  PLAIN_BUF+="${ts} [${tag}] ${msg}"$'\n'
  if [[ "$USE_COLOR" -eq 1 ]]; then
    case "$level" in
      OK) color=$'\033[32m' ;;
      INFO) color=$'\033[36m' ;;
      WARN) color=$'\033[33m' ;;
      ALERT) color=$'\033[1;31m' ;;
    esac
    reset=$'\033[0m'
  fi
  STDOUT_BUF+="${ts} ${color}[${tag}]${reset} ${msg}"$'\n'
}

add_alert() {
  ALERT_COUNT=$((ALERT_COUNT + 1))
  ALERTS+="$1"$'\n'
  emit ALERT "$1"
}

# ---------------------------------------------------------------------------
# Arguments & configuration
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || die "--config requires a path argument"
        CONFIG_FILE="$2"
        shift 2
        ;;
      --config=*)
        CONFIG_FILE="${1#--config=}"
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --json)
        JSON_OUTPUT=1
        shift
        ;;
      --quiet | -q)
        QUIET=1
        shift
        ;;
      --version)
        echo "sysguard ${SYSGUARD_VERSION}"
        exit 0
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        printf 'sysguard: unknown option: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

resolve_config() {
  local candidate
  if [[ -z "$CONFIG_FILE" && -n "${SYSGUARD_CONFIG:-}" ]]; then
    CONFIG_FILE="$SYSGUARD_CONFIG"
  fi
  if [[ -n "$CONFIG_FILE" ]]; then
    [[ -f "$CONFIG_FILE" && -r "$CONFIG_FILE" ]] || die "config file not found or unreadable: ${CONFIG_FILE}"
    return 0
  fi
  for candidate in "${SCRIPT_DIR}/../config/sysguard.conf" "/etc/sysguard/sysguard.conf"; do
    if [[ -f "$candidate" && -r "$candidate" ]]; then
      CONFIG_FILE="$candidate"
      return 0
    fi
  done
  CONFIG_FILE=""
}

# Parse KEY=VALUE lines. The file is never executed, only read.
load_config() {
  local line key value re_line re_dq re_sq
  re_line='^(export[[:space:]]+)?([A-Z_]+)[[:space:]]*=(.*)$'
  re_dq='^"([^"]*)"'
  re_sq="^'([^']*)'"
  [[ -n "$CONFIG_FILE" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "${line%$'\r'}")"
    if [[ -z "$line" || "$line" == \#* ]]; then
      continue
    fi
    if [[ ! "$line" =~ $re_line ]]; then
      die "invalid line in ${CONFIG_FILE}: ${line}"
    fi
    key="${BASH_REMATCH[2]}"
    value="$(trim "${BASH_REMATCH[3]}")"
    if [[ "$value" =~ $re_dq ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ $re_sq ]]; then
      value="${BASH_REMATCH[1]}"
    else
      value="$(trim "${value%%[[:space:]]#*}")"
    fi
    if [[ "$value" == \~/* ]]; then
      value="${HOME:-}/${value#\~/}"
    fi
    case "$key" in
      CPU_THRESHOLD | MEM_THRESHOLD | SWAP_THRESHOLD | DISK_THRESHOLD | \
        DISK_PATH | LOG_FILE | WEBHOOK_URL | SERVICES_TO_CHECK | CPU_SAMPLE_SECONDS)
        printf -v "$key" '%s' "$value"
        ;;
      *) die "unknown setting '${key}' in ${CONFIG_FILE}" ;;
    esac
  done <"$CONFIG_FILE"
}

validate_config() {
  local name value url_re='^https?://[^[:space:]]+$'
  for name in CPU_THRESHOLD MEM_THRESHOLD SWAP_THRESHOLD DISK_THRESHOLD; do
    value="${!name}"
    is_number "$value" || die "${name} must be a number between 0 and 100 (got '${value}')"
    if exceeds "$value" 100; then
      die "${name} must be between 0 and 100 (got '${value}')"
    fi
    printf -v "$name" '%s' "$(norm_number "$value")"
  done
  is_number "$CPU_SAMPLE_SECONDS" || die "CPU_SAMPLE_SECONDS must be a number (got '${CPU_SAMPLE_SECONDS}')"
  [[ -n "$DISK_PATH" ]] || die "DISK_PATH must not be empty"
  [[ -n "$LOG_FILE" ]] || die "LOG_FILE must not be empty"
  if [[ -n "$WEBHOOK_URL" && ! "$WEBHOOK_URL" =~ $url_re ]]; then
    die "WEBHOOK_URL must start with http:// or https://"
  fi
}

prepare_logging() {
  [[ "$DRY_RUN" -eq 0 ]] || return 0
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || die "cannot create log directory for ${LOG_FILE}"
  touch "$LOG_FILE" 2>/dev/null || die "cannot write to log file ${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Metric collection (Linux and macOS)
# ---------------------------------------------------------------------------
linux_cpu_counters() {
  # prints "<idle> <total>"; guest time is already part of user/nice
  awk '/^cpu / { idle = $5 + $6; total = 0; for (i = 2; i <= 9; i++) total += $i; print idle, total; exit }' /proc/stat
}

get_cpu_linux() {
  local idle1 total1 idle2 total2
  read -r idle1 total1 < <(linux_cpu_counters)
  sleep "$CPU_SAMPLE_SECONDS"
  read -r idle2 total2 < <(linux_cpu_counters)
  awk -v i1="$idle1" -v t1="$total1" -v i2="$idle2" -v t2="$total2" 'BEGIN {
    dt = t2 - t1; di = i2 - i1
    if (dt <= 0) { printf "0.0" } else { printf "%.1f", (dt - di) * 100 / dt }
  }'
}

get_cpu_darwin() {
  top -l 2 -n 0 -s 1 | awk '/^CPU usage/ { l = $0 } END {
    if (match(l, /[0-9.]+% idle/)) {
      v = substr(l, RSTART, RLENGTH); sub(/% idle/, "", v); printf "%.1f", 100 - v
    } else { printf "0.0" }
  }'
}

get_mem_linux() {
  # prints "<ram%> <swap%>"
  awk '
    /^MemTotal:/ { t = $2 }
    /^MemAvailable:/ { a = $2 }
    /^MemFree:/ { f = $2 }
    /^SwapTotal:/ { st = $2 }
    /^SwapFree:/ { sf = $2 }
    END {
      if (a == "") a = f
      mem = (t > 0) ? (t - a) * 100 / t : 0
      swap = (st > 0) ? (st - sf) * 100 / st : 0
      printf "%.1f %.1f", mem, swap
    }' /proc/meminfo
}

get_mem_darwin() {
  local total mem swap
  total="$(sysctl -n hw.memsize)"
  mem="$(vm_stat | awk -v total="$total" '
    /page size of/ { ps = $8 }
    /^Pages free:/ { f = $3 }
    /^Pages inactive:/ { i = $3 }
    /^Pages speculative:/ { s = $3 }
    END { avail = (f + i + s) * ps; printf "%.1f", (total > 0) ? (total - avail) * 100 / total : 0 }')"
  swap="$(sysctl -n vm.swapusage | awk '
    function mb(x) { v = x + 0; if (x ~ /G$/) v *= 1024; else if (x ~ /K$/) v /= 1024; return v }
    { t = mb($3); u = mb($6); printf "%.1f", (t > 0) ? u * 100 / t : 0 }')"
  printf '%s %s' "$mem" "$swap"
}

get_load() {
  # prints "<1m> <5m> <15m>"
  if [[ -r /proc/loadavg ]]; then
    awk '{ printf "%s %s %s", $1, $2, $3 }' /proc/loadavg
  else
    uptime | awk -F'load averages?: ' '{ print $2 }' | tr ',' ' ' | awk '{ printf "%s %s %s", $1, $2, $3 }'
  fi
}

get_disk_pct() {
  df -P "$1" 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $5 }'
}

# top_procs cpu|mem - prints up to three lines: "pid|cpu%|mem%|command"
top_procs() {
  local key=1
  if [[ "$1" == "mem" ]]; then
    key=2
  fi
  ps -A -o '%cpu=' -o '%mem=' -o 'pid=' -o 'comm=' 2>/dev/null |
    sort -k"${key},${key}" -nr |
    awk 'NR <= 3 {
      c = $4; for (i = 5; i <= NF; i++) c = c " " $i
      gsub(/[^[:print:]]/, "", c); sub(/^.*\//, "", c)
      printf "%s|%s|%s|%s\n", $3, $1, $2, c
    }'
}

service_running() {
  local svc="$1"
  if [[ "$OS" == "Linux" ]] && command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl is-active --quiet "$svc" 2>/dev/null
    return $?
  fi
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x "$svc" >/dev/null 2>&1 || pgrep -x "${svc}d" >/dev/null 2>&1
    return $?
  fi
  ps -A -o comm= 2>/dev/null | awk -v s="$svc" -v d="${svc}d" '{
    sub(/^.*\//, "", $0); if ($0 == s || $0 == d) f = 1
  } END { exit !f }'
}

collect_metrics() {
  local out
  case "$OS" in
    Linux)
      [[ -r /proc/stat && -r /proc/meminfo ]] || die "/proc is not available"
      CPU_PCT="$(get_cpu_linux)"
      out="$(get_mem_linux)"
      ;;
    Darwin)
      CPU_PCT="$(get_cpu_darwin)"
      out="$(get_mem_darwin)"
      ;;
    *) die "unsupported operating system: ${OS}" ;;
  esac
  MEM_PCT="${out% *}"
  SWAP_PCT="${out#* }"
  out="$(get_load)"
  read -r LOAD_1 LOAD_5 LOAD_15 <<<"$out"
  LOAD_1="$(norm_number "${LOAD_1:-0}")"
  LOAD_5="$(norm_number "${LOAD_5:-0}")"
  LOAD_15="$(norm_number "${LOAD_15:-0}")"
}

# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------
check_threshold() {
  local label="$1" value="$2" threshold="$3"
  if exceeds "$value" "$threshold"; then
    add_alert "${label} is ${value}% (threshold ${threshold}%)"
  else
    emit OK "${label} ${value}% (threshold ${threshold}%)"
  fi
}

check_disks() {
  local path pct
  while IFS= read -r path; do
    path="$(trim "$path")"
    [[ -n "$path" ]] || continue
    pct="$(get_disk_pct "$path" || true)"
    [[ -n "$pct" ]] || die "cannot read disk usage for '${path}' (check DISK_PATH)"
    DISK_RESULTS+="${path}|${pct}"$'\n'
    check_threshold "Disk usage on ${path}" "$pct" "$DISK_THRESHOLD"
  done < <(printf '%s\n' "$DISK_PATH" | tr ',' '\n')
}

check_services() {
  local svc
  while IFS= read -r svc; do
    svc="$(trim "$svc")"
    [[ -n "$svc" ]] || continue
    if service_running "$svc"; then
      SERVICE_RESULTS+="${svc}|running"$'\n'
      emit OK "Service '${svc}' is running"
    else
      SERVICE_RESULTS+="${svc}|down"$'\n'
      add_alert "Service '${svc}' is not running"
    fi
  done < <(printf '%s\n' "$SERVICES_TO_CHECK" | tr ',' '\n')
}

emit_top_procs() {
  local label="$1" data="$2" n=0 pid cpu mem cmd
  while IFS='|' read -r pid cpu mem cmd; do
    [[ -n "$pid" ]] || continue
    n=$((n + 1))
    emit INFO "Top ${label} #${n}: ${cmd} (pid ${pid}, cpu ${cpu}%, mem ${mem}%)"
  done <<<"$data"
}

evaluate() {
  emit INFO "sysguard ${SYSGUARD_VERSION} on ${HOSTNAME_VALUE} (${OS})"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    emit INFO "dry-run: log file and webhook are disabled"
  fi
  check_threshold "CPU usage" "$CPU_PCT" "$CPU_THRESHOLD"
  emit INFO "Load average (1m/5m/15m): ${LOAD_1} ${LOAD_5} ${LOAD_15}"
  check_threshold "Memory usage" "$MEM_PCT" "$MEM_THRESHOLD"
  check_threshold "Swap usage" "$SWAP_PCT" "$SWAP_THRESHOLD"
  check_disks
  check_services

  if [[ "$ALERT_COUNT" -gt 0 ]]; then
    TOP_CPU="$(top_procs cpu || true)"
    TOP_MEM="$(top_procs mem || true)"
    emit_top_procs "CPU" "$TOP_CPU"
    emit_top_procs "memory" "$TOP_MEM"
    emit ALERT "${ALERT_COUNT} alert(s) triggered"
  else
    emit OK "All checks passed"
  fi
}

# ---------------------------------------------------------------------------
# Notification
# ---------------------------------------------------------------------------
send_webhook() {
  local text payload alert_lines
  [[ "$ALERT_COUNT" -gt 0 && -n "$WEBHOOK_URL" ]] || return 0

  if [[ "$DRY_RUN" -eq 1 ]]; then
    emit INFO "dry-run: would send webhook notification"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    emit WARN "curl not found; webhook notification skipped"
    return 0
  fi

  alert_lines="$(printf '%s' "$ALERTS" | sed 's/^/- /')"
  text=":rotating_light: sysguard alert on ${HOSTNAME_VALUE} (${OS})"$'\n'"${alert_lines}"
  text="${text:0:1900}"
  payload="{\"text\": \"$(json_escape "$text")\", \"content\": \"$(json_escape "$text")\"}"

  # The URL is passed on stdin so it never shows up in the process list.
  if printf 'url = "%s"\n' "$WEBHOOK_URL" |
    curl --silent --show-error --fail --max-time 10 --request POST \
      --header 'Content-Type: application/json' \
      --data-binary "$payload" --config - >/dev/null 2>&1; then
    emit INFO "Webhook notification sent"
  else
    emit WARN "Webhook notification failed"
  fi
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
json_procs() {
  local data="$1" sep="" pid cpu mem cmd
  printf '['
  while IFS='|' read -r pid cpu mem cmd; do
    [[ -n "$pid" ]] || continue
    printf '%s{"pid": %s, "cpu_percent": %s, "mem_percent": %s, "command": "%s"}' \
      "$sep" "$pid" "$cpu" "$mem" "$(json_escape "$cmd")"
    sep=", "
  done <<<"$data"
  printf ']'
}

build_json() {
  local status="healthy" sep="" path pct svc state line
  if [[ "$ALERT_COUNT" -gt 0 ]]; then
    status="alert"
  fi

  printf '{\n'
  printf '  "timestamp": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '  "hostname": "%s",\n' "$(json_escape "$HOSTNAME_VALUE")"
  printf '  "os": "%s",\n' "$OS"
  printf '  "status": "%s",\n' "$status"
  printf '  "cpu": {"usage_percent": %s, "threshold": %s},\n' "$CPU_PCT" "$CPU_THRESHOLD"
  printf '  "load_average": {"1m": %s, "5m": %s, "15m": %s},\n' "$LOAD_1" "$LOAD_5" "$LOAD_15"
  printf '  "memory": {"usage_percent": %s, "threshold": %s},\n' "$MEM_PCT" "$MEM_THRESHOLD"
  printf '  "swap": {"usage_percent": %s, "threshold": %s},\n' "$SWAP_PCT" "$SWAP_THRESHOLD"

  printf '  "disks": ['
  while IFS='|' read -r path pct; do
    [[ -n "$path" ]] || continue
    printf '%s\n    {"path": "%s", "usage_percent": %s, "threshold": %s}' \
      "$sep" "$(json_escape "$path")" "$pct" "$DISK_THRESHOLD"
    sep=","
  done <<<"$DISK_RESULTS"
  printf '\n  ],\n'

  sep=""
  printf '  "services": ['
  while IFS='|' read -r svc state; do
    [[ -n "$svc" ]] || continue
    printf '%s\n    {"name": "%s", "status": "%s"}' "$sep" "$(json_escape "$svc")" "$state"
    sep=","
  done <<<"$SERVICE_RESULTS"
  printf '\n  ],\n'

  sep=""
  printf '  "alerts": ['
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '%s\n    "%s"' "$sep" "$(json_escape "$line")"
    sep=","
  done <<<"$ALERTS"
  printf '\n  ],\n'

  printf '  "top_processes": {\n'
  printf '    "cpu": %s,\n' "$(json_procs "$TOP_CPU")"
  printf '    "memory": %s\n' "$(json_procs "$TOP_MEM")"
  printf '  }\n'
  printf '}\n'
}

flush_output() {
  if [[ "$QUIET" -eq 1 && "$ALERT_COUNT" -eq 0 ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" -eq 0 ]]; then
    printf '%s' "$PLAIN_BUF" >>"$LOG_FILE" || die "cannot write to log file ${LOG_FILE}"
  fi
  if [[ "$JSON_OUTPUT" -eq 1 ]]; then
    build_json
  else
    printf '%s' "$STDOUT_BUF"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  resolve_config
  load_config
  validate_config
  prepare_logging

  if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    USE_COLOR=1
  fi

  collect_metrics
  evaluate
  send_webhook
  flush_output

  if [[ "$ALERT_COUNT" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
