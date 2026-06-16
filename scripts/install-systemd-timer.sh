#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_ID="${BACKUP_HOST:-$(hostname -s)}"
TIMER_NAME="encrypted-github-backup"

sudo tee "/etc/systemd/system/${TIMER_NAME}.service" >/dev/null <<SERVICE
[Unit]
Description=Create encrypted GitHub backup for ${HOST_ID}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${REPO_DIR}
Environment=BACKUP_HOST=${HOST_ID}
Environment=BACKUP_PUSH=1
EnvironmentFile=-/etc/encrypted-github-backup.env
ExecStart=${REPO_DIR}/scripts/backup.sh
Nice=10
IOSchedulingClass=best-effort
SERVICE

sudo tee "/etc/systemd/system/${TIMER_NAME}.timer" >/dev/null <<TIMER
[Unit]
Description=Run encrypted GitHub backup daily

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
TIMER

sudo systemctl daemon-reload
sudo systemctl enable --now "${TIMER_NAME}.timer"
printf 'Installed %s.timer. Put GITHUB_TOKEN in /etc/encrypted-github-backup.env with mode 600.\n' "$TIMER_NAME"
