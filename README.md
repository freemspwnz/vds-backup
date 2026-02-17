# vds-backup

**VDS backup to Keenetic router via Restic over SFTP.** Automated, observable, and safe: logical SQLite/PostgreSQL dumps, repository checks, systemd timer, and structured logging to journald.

---

## Overview

vds-backup backs up a single VDS host to an **SFTP repository** (typically on a **Keenetic** router with SSD storage). It uses **[restic](https://restic.net)** for deduplicated, encrypted backups, **systemd** for scheduling, and **Bash** with modular libraries for configuration and execution.

- **Source:** Docker stack directory (configs, bind-mounted data), optional extra paths.
- **Databases:** Auto-discovered SQLite (`*.sqlite`, `*.db`, `*.sqlite3`) and optional PostgreSQL via Docker; logical dumps only (no raw DB file backup).
- **Destination:** `sftp:user@router:/path/to/repo` (restic repo on router).
- **Automation:** systemd oneshot service + timer (e.g. daily at 04:00).

---

## Key Features

| Feature | Description |
|--------|-------------|
| **Restic** | Deduplication, encryption, SFTP backend; repository checked before each run (`restic snapshots --last 1`). |
| **systemd** | `backup.service` (oneshot) + `backup.timer`; install to `/etc/systemd/system`, `systemctl daemon-reload` after changes. |
| **Structured logging** | Level-based logging (INFO, WARN, ERROR, DEBUG) with priority-style prefixes; stderr captured by journald; `SyslogIdentifier=backup` for filtering. |
| **journald** | All output via `StandardOutput=journal` / `StandardError=journal`; view with `journalctl -u backup.service` or `journalctl -t backup`. |
| **Bash arrays** | `EXTRA_BACKUP_PATHS` and `RESTIC_EXCLUDES` are Bash arrays in `/usr/local/etc/backup.conf` for flexible paths and exclude rules. |
| **Safe DB backup** | SQLite: `sqlite3 .dump`; PostgreSQL: `pg_dumpall` in container; dumps in a temp dir, included in restic, cleaned up on exit via `trap`. |
| **Optional Telegram** | HTML report after each run (success/failure) if `TG_TOKEN` and `TG_CHAT_ID` are set in secrets. |

---

## Project Structure

| Path (in repo) | Installed to | Purpose |
|----------------|--------------|---------|
| `bin/backup.sh` | `/usr/local/bin/backup.sh` | Entrypoint; uses `/usr/bin/env bash`, sources libs from `LIB_ROOT` (default `/usr/local/lib`). |
| `lib/logger.sh` | `/usr/local/lib/logger.sh` | Logging: `log_info`, `log_warn`, `log_error`, `log_debug`; level prefixes; DEBUG only when `BACKUP_DEBUG=1`. |
| `lib/telegram.sh` | `/usr/local/lib/telegram.sh` | `tg_send_html` for Telegram Bot API. |
| `lib/backup/config.sh` | `/usr/local/lib/backup/config.sh` | Loads `/usr/local/etc/backup.conf` and `/usr/local/secrets/.backup.env`; ensures array vars. |
| `lib/backup/main.sh` | `/usr/local/lib/backup/main.sh` | Orchestration: disk check, SQLite discovery/dump, optional PostgreSQL dump, restic backup, Telegram report. |
| `lib/backup/restic.sh` | `/usr/local/lib/backup/restic.sh` | `backup_check_repository`, `backup_run_restic_backup`, `backup_extract_restic_stats`. |
| `lib/backup/disk_check.sh` | `/usr/local/lib/backup/disk_check.sh` | Validates `DOCKER_DIR` (exists, readable, has dirs); sets `DISK_STATUS` [OK]/[FAIL]. |
| `lib/backup/report.sh` | `/usr/local/lib/backup/report.sh` | Builds and sends Telegram HTML report (host, disk status, repo, restic stats). |
| `lib/backup/sqlite_discovery.sh` | `/usr/local/lib/backup/sqlite_discovery.sh` | `sqlite_find_databases <root_dir>` — finds `*.sqlite`, `*.db`, `*.sqlite3`. |
| `lib/backup/sqlite_dump.sh` | `/usr/local/lib/backup/sqlite_dump.sh` | `sqlite_dump_databases` — logical dumps into temp dir. |
| `lib/backup/postgres_dump.sh` | `/usr/local/lib/backup/postgres_dump.sh` | `backup_postgres_dump` — optional `docker exec … pg_dumpall`. |
| `etc/backup.conf.example` | — | Example config; copied to `/usr/local/etc/backup.conf` by install only if missing. |
| — | `/usr/local/etc/backup.conf` | **Your** config (paths, repo, arrays); not overwritten by install. |
| — | `/usr/local/secrets/.backup.env` | **Secrets** (e.g. `RESTIC_PASSWORD`, `TG_TOKEN`, `TG_CHAT_ID`); never touched by install. |
| `systemd/backup.service` | `/etc/systemd/system/backup.service` | Oneshot; `ExecStart=/usr/bin/env bash /usr/local/bin/backup.sh`; env for config/secrets paths; journal + `SyslogIdentifier=backup`. |
| `systemd/backup.timer` | `/etc/systemd/system/backup.timer` | Schedules `backup.service` (e.g. `OnCalendar=*-*-* 04:00:00`). |
| `install.sh` | — | Deploys files to `/usr/local` and systemd; does not overwrite existing config or secrets. |

---

## Prerequisites

- **Linux** host with **systemd**.
- **Bash 4+** (for arrays and `mapfile` in backup scripts).
- **restic** installed on the VDS (in `PATH` or set `RESTIC_BIN` in config).
- **sqlite3** for SQLite logical dumps.
- **SSH key-based access** from VDS to the router (passwordless SFTP); no agent on router required beyond SSH/SFTP.
- **Router (e.g. Keenetic):** SSH/SFTP server; if using **Entware**, ensure `openssh-sftp-server` or equivalent is available so restic can use SFTP.

Optional:

- **Docker** (for PostgreSQL dumps).
- **curl** (for Telegram notifications).

---

## Installation & Setup

1. **Clone the repository** (on the VDS):

   ```bash
   git clone https://github.com/you/vds-backup.git
   cd vds-backup
   ```

2. **Run the installer** (deploys to `/usr/local` and systemd; does not overwrite existing `/usr/local/etc/backup.conf` or `/usr/local/secrets/.backup.env`):

   ```bash
   sudo ./install.sh
   sudo systemctl daemon-reload
   ```

   The script installs:

   - `bin/backup.sh` → `/usr/local/bin/backup.sh`
   - `lib/*.sh` → `/usr/local/lib/`
   - `lib/backup/*.sh` → `/usr/local/lib/backup/`
   - `systemd/backup.service` and `backup.timer` → `/etc/systemd/system/`
   - If `/usr/local/etc/backup.conf` does not exist, it is created from `etc/backup.conf.example`.

3. **Configure** `/usr/local/etc/backup.conf` (see [Configuration](#configuration)).

4. **Create secrets** (if not present):

   ```bash
   sudo mkdir -p /usr/local/secrets
   sudo tee /usr/local/secrets/.backup.env >/dev/null <<'EOF'
   RESTIC_PASSWORD="CHANGE_ME"
   # TG_TOKEN="..."
   # TG_CHAT_ID="..."
   EOF
   sudo chown root:root /usr/local/secrets/.backup.env
   sudo chmod 600 /usr/local/secrets/.backup.env
   ```

5. **Enable and start the timer**:

   ```bash
   sudo systemctl enable --now backup.timer
   ```

To change the schedule, edit the timer before install or add an override, e.g. `/etc/systemd/system/backup.timer.d/override.conf` with `OnCalendar=...`.

---

## Configuration

Config is a Bash script: `/usr/local/etc/backup.conf`. Required and optional variables:

| Variable | Required | Description |
|----------|----------|-------------|
| `DOCKER_DIR` | Yes | Root of the Docker stack (bind mounts, configs, data) to back up. |
| `RESTIC_REPOSITORY` | Yes | Restic repo URL, e.g. `sftp:backup@router:/mnt/ssd/restic/vds`. |
| `BACKUP_TMP_BASE_DIR` | No | Base directory for temporary DB dumps (default: `/tmp`). |
| `RESTIC_TAGS` | No | Tag string for restic (e.g. `scheduled,vds`). |
| `RESTIC_HOST` | No | Host name for restic snapshots (e.g. `$(hostname)`). |
| `RESTIC_BIN` | No | Path to restic (default: `restic`). |
| `EXTRA_BACKUP_PATHS` | No | Bash array of additional paths to back up. |
| `RESTIC_EXCLUDES` | No | Bash array of paths to exclude from backup. |
| `POSTGRES_DOCKER_CONTAINER` | No | PostgreSQL container name; if unset, PG dump is skipped. |
| `POSTGRES_DUMP_USER` | No | User for `pg_dumpall` (default: `postgres`). |
| `POSTGRES_DUMP_ENABLED` | No | Set to `false` to disable PostgreSQL dump. |

**Example** `/usr/local/etc/backup.conf`:

```bash
DOCKER_DIR="/root/docker"
RESTIC_REPOSITORY="sftp:backup@router:/mnt/ssd/restic/vds"
RESTIC_TAGS="scheduled,vds"
RESTIC_HOST="$(hostname)"
BACKUP_TMP_BASE_DIR="/tmp"

EXTRA_BACKUP_PATHS=()
RESTIC_EXCLUDES=(
  "${DOCKER_DIR}/monitoring/loki/data"
  "${DOCKER_DIR}/data/postgres/data"
)

# Optional PostgreSQL
# POSTGRES_DOCKER_CONTAINER="postgres"
# POSTGRES_DUMP_USER="postgres"
# POSTGRES_DUMP_ENABLED=true
```

Secrets in `/usr/local/secrets/.backup.env` (sourced by config loader):

- `RESTIC_PASSWORD` — required for restic.
- `TG_TOKEN`, `TG_CHAT_ID` — optional; enable Telegram reports.

---

## Logging & Monitoring

- The service runs with **`StandardOutput=journal`** and **`StandardError=journal`**, so all script output is in journald.
- **`SyslogIdentifier=backup`** is set in `backup.service`; use it to filter logs by tag.

**View logs:**

```bash
# Last run and follow
sudo journalctl -u backup.service -f

# By syslog identifier (tag "backup")
sudo journalctl -t backup -f

# Last 100 lines
sudo journalctl -u backup.service -n 100
```

Debug lines are only emitted when **`BACKUP_DEBUG=1`** (e.g. in the service override or environment).

---

## SSH Key Setup (SFTP to Router)

On the VDS:

1. Generate a key (if needed):

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -C "vds"
   ```

2. Copy the public key to the router (e.g. user `vds`, host `router`):

   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub vds@router
   ```

3. Verify passwordless access:

   ```bash
   ssh vds@router "echo ok"
   sftp vds@router:tmp/mnt/ssd
   ```

---

## Restic Repository (SFTP on Router)

On the VDS, one-time init:

```bash
export RESTIC_PASSWORD='CHANGE_ME'
export RESTIC_REPOSITORY='sftp:vds@router:/tmp/mnt/ssd/vds'
restic init
```

Then put `RESTIC_REPOSITORY` in `/usr/local/etc/backup.conf` and `RESTIC_PASSWORD` in `/usr/local/secrets/.backup.env`. Each run checks the repo with `restic snapshots --last 1` before backing up.

---

## Telegram Notifications

If `TG_TOKEN` and `TG_CHAT_ID` are set in `/usr/local/secrets/.backup.env`, a short HTML report is sent after each run (success or failure): hostname, disk check status, repo name, backup status, and restic stats (files/dirs/added).

---

## Manual Run

```bash
sudo systemctl start backup.service
sudo journalctl -u backup.service -f
```

---

## Development Notes

- Scripts use `set -euo pipefail` where appropriate.
- Entrypoint is explicitly **Bash** (`/usr/bin/env bash`); Bash-specific features (arrays, `mapfile`) are used.
- Config paths are overridable via environment: `BACKUP_CONF_PATH`, `BACKUP_SECRETS_PATH` (and in the service unit, `LIB_ROOT` if needed).
- No credentials in code; all secrets from `/usr/local/secrets/.backup.env` or environment.
