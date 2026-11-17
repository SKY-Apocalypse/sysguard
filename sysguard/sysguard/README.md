# sysguard

A small, dependency-free **System Health & Resource Monitor** written in Bash.
It checks CPU, load, memory, swap, disk and services, logs the result, and can
post alerts to a Slack or Discord webhook. Runs on Linux (GNU tools) and macOS (BSD tools).

## Features

- CPU usage % plus 1/5/15-minute load averages
- RAM and swap usage %
- Disk usage % for one or more mount points
- Service checks via `systemctl is-active` (systemd) or `pgrep` (everything else, macOS)
- Top 3 CPU and memory consumers, listed whenever an alert fires
- Timestamped, color-coded terminal output; plain-text log file
- Slack/Discord-compatible webhook alerts (URL is passed to `curl` over stdin, not on the command line)
- `--json`, `--quiet` and `--dry-run` modes; cron-friendly exit codes
- Safe config parsing: the config file is read, never executed

## Quick start

```bash
git clone <your-repo-url> sysguard && cd sysguard
cp config/sysguard.conf.example config/sysguard.conf
chmod 600 config/sysguard.conf        # it may hold a webhook secret
./bin/sysguard.sh --dry-run           # try it without logging or notifying
```

System-wide install:

```bash
sudo install -m 0755 bin/sysguard.sh /usr/local/bin/sysguard
sudo install -d /etc/sysguard
sudo install -m 0600 config/sysguard.conf.example /etc/sysguard/sysguard.conf
sysguard --config /etc/sysguard/sysguard.conf
```

Requirements: `bash` 3.2+, `awk`, `sed`, `df`, `ps`, `sort`; `curl` for webhooks.
`pgrep` is used for service checks when systemd is not available.

## Configuration

Config lookup order: `--config <path>` → `$SYSGUARD_CONFIG` → `config/sysguard.conf`
next to the script → `/etc/sysguard/sysguard.conf` → built-in defaults.
An explicitly given config that is missing is an error (exit 2).

| Setting | Default | Description |
|---|---|---|
| `CPU_THRESHOLD` | `80` | Alert when CPU usage is above this % |
| `MEM_THRESHOLD` | `80` | Alert when RAM usage is above this % |
| `SWAP_THRESHOLD` | `50` | Alert when swap usage is above this % |
| `DISK_THRESHOLD` | `85` | Alert when disk usage is above this % |
| `DISK_PATH` | `/` | Mount point(s), comma-separated: `/,/var,/home` |
| `LOG_FILE` | `$TMPDIR/sysguard.log` | Plain-text log (use `/var/log/sysguard.log` for system installs) |
| `WEBHOOK_URL` | empty | Slack/Discord incoming webhook; empty disables notifications |
| `SERVICES_TO_CHECK` | empty | Comma-separated, e.g. `ssh,cron,docker` |
| `CPU_SAMPLE_SECONDS` | `1` | Length of the CPU sampling window |

Format is `KEY=VALUE`; quotes and `# comments` are allowed; unknown keys are rejected.
Service names: with systemd they are unit names (`ssh` on Debian, `sshd` on RHEL);
otherwise they are matched against process names (`pgrep -x name`, then `named`).

## CLI flags

| Flag | Effect |
|---|---|
| `--config <path>` | Use a specific config file |
| `--dry-run` | Print results only: no log writes, no webhook calls |
| `--json` | Emit metrics as JSON on stdout |
| `--quiet`, `-q` | Output (and log) only when an alert triggers |
| `--version` | Print version |
| `--help`, `-h` | Show help |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Healthy |
| `1` | At least one threshold breached or service down |
| `2` | Configuration or runtime error |

## Sample output

```text
$ sysguard --config /etc/sysguard/sysguard.conf
2026-11-17 05:57:27 [INFO ] sysguard 1.0.0 on web-01 (Linux)
2026-11-17 05:57:27 [OK   ] CPU usage 3.2% (threshold 80%)
2026-11-17 05:57:27 [INFO ] Load average (1m/5m/15m): 0.42 0.38 0.30
2026-11-17 05:57:27 [ALERT] Memory usage is 91.4% (threshold 80%)
2026-11-17 05:57:27 [OK   ] Swap usage 0.0% (threshold 50%)
2026-11-17 05:57:27 [OK   ] Disk usage on / 45% (threshold 85%)
2026-11-17 05:57:27 [ALERT] Service 'docker' is not running
2026-11-17 05:57:27 [INFO ] Top CPU #1: node (pid 3564, cpu 12.7%, mem 4.1%)
2026-11-17 05:57:27 [INFO ] Top memory #1: java (pid 65, cpu 3.0%, mem 38.7%)
2026-11-17 05:57:27 [ALERT] 2 alert(s) triggered
```

JSON (`--json`):

```json
{
  "timestamp": "2026-11-17T05:57:27Z",
  "hostname": "web-01",
  "os": "Linux",
  "status": "alert",
  "cpu": {"usage_percent": 3.2, "threshold": 80},
  "load_average": {"1m": 0.42, "5m": 0.38, "15m": 0.3},
  "memory": {"usage_percent": 91.4, "threshold": 80},
  "swap": {"usage_percent": 0.0, "threshold": 50},
  "disks": [
    {"path": "/", "usage_percent": 45, "threshold": 85}
  ],
  "services": [
    {"name": "docker", "status": "down"}
  ],
  "alerts": [
    "Memory usage is 91.4% (threshold 80%)",
    "Service 'docker' is not running"
  ],
  "top_processes": {
    "cpu": [{"pid": 3564, "cpu_percent": 12.7, "mem_percent": 4.1, "command": "node"}],
    "memory": [{"pid": 65, "cpu_percent": 3.0, "mem_percent": 38.7, "command": "java"}]
  }
}
```

## Webhook alerts

Set `WEBHOOK_URL` to a Slack or Discord incoming webhook. On any alert, sysguard POSTs
`{"text": "...", "content": "..."}` (`text` for Slack, `content` for Discord). A failed
delivery is logged as a warning and does not change the exit code.

## Running from cron

```cron
# Every 5 minutes: log and notify only when something is wrong
*/5 * * * * /usr/local/bin/sysguard --config /etc/sysguard/sysguard.conf --quiet >/dev/null 2>&1

# Or keep cron's mail for failures (exit 2) only
*/5 * * * * /usr/local/bin/sysguard --config /etc/sysguard/sysguard.conf --quiet >/dev/null || [ $? -eq 1 ] || echo "sysguard failed"
```

Cron has a minimal `PATH`; if `curl` or `pgrep` live elsewhere, add `PATH=/usr/local/bin:/usr/bin:/bin`
at the top of the crontab. Rotate the log with `logrotate` (e.g. weekly, `rotate 4`, `compress`).

## Testing

```bash
./tests/test_sysguard.sh      # covers flags, JSON validity, dry-run, quiet, thresholds, webhook
shellcheck -x bin/sysguard.sh tests/test_sysguard.sh
```

The tests use temporary configs and a stubbed `curl`, so nothing touches the network.

## License

MIT, see [LICENSE](LICENSE).
