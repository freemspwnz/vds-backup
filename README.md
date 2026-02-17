## vds-backup

**vds-backup** is a small, production-ready backup system for a single VDS host.
It uses **restic** with an **SFTP repository on a router SSD**, performs
automatic SQLite discovery/dumps from your `docker/` stack, and integrates
cleanly with `systemd` and `journald`.

The project is designed to be:

- **Safe**: only logical dumps of SQLite, repository is checked before backup.
- **Observable**: structured logging with `logger`, visible via `journalctl`.
- **Simple to operate**: one main script, config + secrets files, `systemd` timer.

---

### Architecture Overview

- **Main script**: `bin/backup.sh`
  - Loads configuration from `/usr/local/etc/backup.conf`.
  - Loads secrets from `/usr/local/secrets/.backup.env`.
  - Creates a temporary directory for DB dumps and cleans it up via `trap` on
    any exit (success, error, or signal).
  - Auto-discovers SQLite databases under `DOCKER_DIR`.
  - Creates logical dumps using `sqlite3 .dump`.
  - Runs `restic backup` against:
    - your `DOCKER_DIR`,
    - the temporary dumps directory,
    - any extra paths configured in `EXTRA_BACKUP_PATHS`.
  - Verifies restic repository accessibility before backup (`restic snapshots --last 1`).

- **Logging**: `/usr/local/lib/logger.sh`
  - Thin wrapper around the `logger` utility with levels:
    - `log_info`, `log_warn`, `log_error`, `log_debug`.
  - All messages are printed to stdout/stderr.
  - Important messages are mirrored to `journald` with tag `backup` (configurable via `LOG_TAG`).
  - Debug messages are sent to journald only when `BACKUP_DEBUG=1`.

- **SQLite and PostgreSQL dumps**:
  - `/usr/local/lib/backup/sqlite_discovery.sh`
    - `sqlite_find_databases <root_dir>`:
      - Recursively finds `*.sqlite`, `*.db`, `*.sqlite3` under the given directory.
  - `/usr/local/lib/backup/sqlite_dump.sh`
    - `sqlite_dump_databases <db_list_file_or_dash> <tmp_dir> <timestamp>`:
      - Reads a list of database paths (from file or stdin).
      - Produces logical dumps via `sqlite3 ".dump"` into `tmp_dir`.
      - Prints paths to successfully created dump files.
  - `/usr/local/lib/backup/postgres_dump.sh`
    - `backup_postgres_dump`:
      - Optionally creates a logical PostgreSQL dump from a Docker container using `pg_dumpall`.

- **Configuration**:
  - Example: `etc/backup.conf.example` (in the repo)
  - Real file (on the host): `/usr/local/etc/backup.conf`

- **Secrets**:
  - Real file (on the host): `/usr/local/secrets/.backup.env`
  - Used for `RESTIC_PASSWORD` and other sensitive values.

- **systemd units**:
  - `systemd/backup.service`
    - Runs `backup.sh` as a oneshot service.
    - `StandardOutput=journal`, `StandardError=journal`.
  - `systemd/backup.timer`
    - Schedules `backup.service` (e.g. daily at 03:00).

---

### Requirements

- Linux host (systemd based).
- `bash` (for the backup script and libraries).
- `restic` installed on the VDS.
- `sqlite3` for SQLite dumps.
- `logger` (usually provided by `util-linux` or equivalent).
- Passwordless SSH/SFTP key-based access from the VDS to the router.

---

### Installation

1. **Clone the repository** (on your VDS):

   ```bash
   git clone https://github.com/you/vds-backup.git
   cd vds-backup
   ```

2. **Run the install script** (deploys to `/usr/local` and systemd; does not overwrite existing config or secrets):

   ```bash
   sudo ./install.sh
   sudo systemctl daemon-reload
   ```

   The script installs:
   - `bin/backup.sh` → `/usr/local/bin/backup.sh`
   - `lib/logger.sh`, `lib/telegram.sh` → `/usr/local/lib/`
   - `lib/backup/*.sh` → `/usr/local/lib/backup/`
   - `systemd/backup.service`, `backup.timer` → `/etc/systemd/system/`
   - If `/usr/local/etc/backup.conf` does not exist, it is created from `etc/backup.conf.example`. Existing config and `/usr/local/secrets/.backup.env` are never overwritten.

3. **Configure** `/usr/local/etc/backup.conf`:

   - `DOCKER_DIR` – root of your docker stack (bind-mounted volumes, configs, etc.).
   - `RESTIC_REPOSITORY` – SFTP URL pointing to router SSD storage, e.g.:

     ```bash
     RESTIC_REPOSITORY="sftp:backup@router:/mnt/ssd/restic/vds"
     ```

   - `BACKUP_TMP_BASE_DIR` – base directory for temporary database dumps.
   - Optional PostgreSQL: `POSTGRES_DOCKER_CONTAINER`, `POSTGRES_DUMP_USER`, `POSTGRES_DUMP_ENABLED`.
   - `EXTRA_BACKUP_PATHS`, `RESTIC_EXCLUDES` – optional lists.

4. **Create secrets file** if not already present:

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

6. **Manual run & logs** (optional):

   ```bash
   # Manual run
   sudo systemctl start backup.service

   # Service logs
   sudo journalctl -u backup.service -f

   # All logs with tag "backup"
   sudo journalctl -t backup -f
   ```

You can adjust the schedule by editing `systemd/backup.timer` (`OnCalendar=...`)
before installing it or by overriding it in `/etc/systemd/system/backup.timer.d/`.

**Manual installation** (without `install.sh`): copy `bin/backup.sh` to `/usr/local/bin/`, `lib/*.sh` to `/usr/local/lib/`, `lib/backup/*.sh` to `/usr/local/lib/backup/`, and `systemd/*` to `/etc/systemd/system/`. Create `/usr/local/etc/backup.conf` and `/usr/local/secrets/.backup.env` as in steps 3–4 above.

---

### How Database Dumps Work (SQLite and PostgreSQL)

1. `backup.sh` reads `DOCKER_DIR` from `/usr/local/etc/backup.conf`.
2. SQLite:
   - `sqlite_find_databases` scans `DOCKER_DIR` recursively for:
     - `*.sqlite`
     - `*.db`
     - `*.sqlite3`
   - All found database paths are passed to `sqlite_dump_databases`, which:
     - Uses `sqlite3 <db> ".dump"` to produce consistent logical dumps.
     - Names dumps using a timestamp and a path-based safe name.
     - Writes dumps into a dedicated temporary directory (`BACKUP_TMP_DIR`).
3. PostgreSQL (optional):
   - If `POSTGRES_DOCKER_CONTAINER` is set and Docker is available,
     `backup_postgres_dump` runs:
     - `docker exec <container> pg_dumpall -c -U <user> > postgres_all_<timestamp>.sql`
     - The dump is also written into `BACKUP_TMP_DIR`.
4. `BACKUP_TMP_DIR` is included in the `restic backup` targets.
5. `trap` in the backup orchestrator ensures `BACKUP_TMP_DIR` is removed on any script exit.

This approach avoids copying live database files directly and keeps the backup
logic decoupled from database engines and runtime state.

---

### Telegram Notifications

If `TG_TOKEN` and `TG_CHAT_ID` are set in `/usr/local/secrets/.backup.env`, `backup.sh`
will send an HTML-formatted summary message to Telegram at the end of each run
(both on success and on failure).

The message includes:

- Hostname
- Disk checkup status (`[OK]` / `[FAIL]` / `[UNKNOWN]`)
- Restic repository name and backup status (`[OK]` / `[FAIL]`)
- Extracted restic statistics (`Files`, `Dirs`, `Added to the repository`)

Example message:

```html
<b>Host:</b> VDS
<b>Disk checkup:</b> [OK]
<b>Repo 'vds' backup:</b> [OK]
<b>Stats:</b>
<pre>Files:           0 new,     0 changed,    37 unmodified
Dirs:            0 new,     0 changed,    23 unmodified
Added to the repository: 0 B   (0 B   stored)</pre>
Backup completed successfully.
```

---

### SSH Key Setup for Router (SFTP Backend)

On the VDS host:

1. **Generate a key pair** (if you don’t have one yet):

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -C "vds-backup"
   ```

2. **Copy the public key to the router** (user and host example: `backup@router`):

   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub backup@router
   ```

   Or append the content of `~/.ssh/id_ed25519.pub` manually to the
   `authorized_keys` file for the `backup` user on the router.

3. **Verify SSH/SFTP access**:

   ```bash
   ssh  backup@router "echo ok"
   sftp backup@router:/mnt/ssd
   ```

   There should be no password prompts; otherwise restic may hang or fail.

---

### Restic Repository Initialization (SFTP on Router SSD)

On the VDS host:

1. **Export environment variables for initial setup**:

   ```bash
   export RESTIC_PASSWORD='CHANGE_ME'
   export RESTIC_REPOSITORY='sftp:backup@router:/mnt/ssd/restic/vds'
   ```

2. **Initialize the repository**:

   ```bash
   restic init
   ```

3. **Move values into configuration files**:

   - `RESTIC_REPOSITORY` → `/usr/local/etc/backup.conf`
   - `RESTIC_PASSWORD`   → `/usr/local/secrets/.backup.env`

After that, `backup.sh` will:

- ensure the repository is accessible (`restic snapshots --last 1`),
- run `restic backup ...` with tags and excludes from `usr/local/etc/backup.conf`.

---

### Development Notes

- All scripts use `set -euo pipefail` where appropriate.
- Logging is centralized in `/usr/local/lib/logger.sh`:
  - If you add new modules, prefer calling `log_info/log_warn/log_error/log_debug`.
- No credentials are hard-coded; all secrets must come from `/usr/local/secrets/.backup.env`
  or the environment.

For contributions, keep shell code POSIX-ish where possible, but it is acceptable
to rely on Bash-specific features as the entrypoint is explicitly `bash`.

