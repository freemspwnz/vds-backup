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
  - Loads configuration from `/etc/backup.conf`.
  - Loads secrets from `/secrets/backup.env`.
  - Creates a temporary directory for DB dumps and cleans it up via `trap` on
    any exit (success, error, or signal).
  - Auto-discovers SQLite databases under `DOCKER_DIR`.
  - Creates logical dumps using `sqlite3 .dump`.
  - Runs `restic backup` against:
    - your `DOCKER_DIR`,
    - the temporary dumps directory,
    - any extra paths configured in `EXTRA_BACKUP_PATHS`.
  - Verifies restic repository accessibility before backup (`restic snapshots --last 1`).

- **Logging**: `lib/logger.sh`
  - Thin wrapper around the `logger` utility with levels:
    - `log_info`, `log_warn`, `log_error`, `log_debug`.
  - All messages are printed to stdout/stderr.
  - Important messages are mirrored to `journald` with tag `backup` (configurable via `LOG_TAG`).
  - Debug messages are sent to journald only when `BACKUP_DEBUG=1`.

- **SQLite discovery/dumps**:
  - `lib/sqlite_discovery.sh`
    - `sqlite_find_databases <root_dir>`:
      - Recursively finds `*.sqlite`, `*.db`, `*.sqlite3` under the given directory.
  - `lib/sqlite_dump.sh`
    - `sqlite_dump_databases <db_list_file_or_dash> <tmp_dir> <timestamp>`:
      - Reads a list of database paths (from file or stdin).
      - Produces logical dumps via `sqlite3 ".dump"` into `tmp_dir`.
      - Prints paths to successfully created dump files.

- **Configuration**:
  - Example: `etc/backup.conf.example`
  - Real file (on the host): `/etc/backup.conf`

- **Secrets**:
  - Real file (on the host): `/secrets/backup.env`
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

2. **Install the main script**:

   ```bash
   sudo cp bin/backup.sh /usr/local/bin/backup.sh
   sudo chmod +x /usr/local/bin/backup.sh
   ```

3. **Install configuration**:

   ```bash
   sudo mkdir -p /etc
   sudo cp etc/backup.conf.example /etc/backup.conf
   sudo chmod 640 /etc/backup.conf
   ```

   Then edit `/etc/backup.conf` to match your environment:

   - `DOCKER_DIR` – root of your docker stack (bind-mounted volumes, configs, etc.).
   - `RESTIC_REPOSITORY` – SFTP URL pointing to router SSD storage, e.g.:

     ```bash
     RESTIC_REPOSITORY="sftp:backup@router:/mnt/ssd/restic/vds"
     ```

   - `BACKUP_TMP_BASE_DIR` – base directory for temporary SQLite dumps.
   - `EXTRA_BACKUP_PATHS` – optional list of additional paths to include.
   - `RESTIC_EXCLUDES` – paths to exclude from restic backup.

4. **Install secrets file**:

   ```bash
   sudo mkdir -p /secrets
   sudo tee /secrets/backup.env >/dev/null <<'EOF'
   # Restic repository password
   RESTIC_PASSWORD="CHANGE_ME"

   # Optional future integration (e.g. Telegram):
   # TG_TOKEN="..."
   # TG_CHAT_ID="..."
   EOF

   sudo chown root:root /secrets/backup.env
   sudo chmod 600 /secrets/backup.env
   ```

---

### systemd Integration

1. **Install units**:

   ```bash
   sudo cp systemd/backup.service /etc/systemd/system/backup.service
   sudo cp systemd/backup.timer   /etc/systemd/system/backup.timer

   sudo systemctl daemon-reload
   ```

2. **Enable and start the timer**:

   ```bash
   sudo systemctl enable --now backup.timer
   ```

3. **Manual run & logs**:

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

---

### How SQLite Discovery and Dumps Work

1. `backup.sh` reads `DOCKER_DIR` from `/etc/backup.conf`.
2. `sqlite_find_databases` scans `DOCKER_DIR` recursively for:
   - `*.sqlite`
   - `*.db`
   - `*.sqlite3`
3. All found database paths are passed to `sqlite_dump_databases`, which:
   - Uses `sqlite3 <db> ".dump"` to produce consistent logical dumps.
   - Names dumps using a timestamp and a path-based safe name.
   - Writes dumps into a dedicated temporary directory (`BACKUP_TMP_DIR`).
4. `BACKUP_TMP_DIR` is included in the `restic backup` targets.
5. `trap` in `backup.sh` ensures `BACKUP_TMP_DIR` is removed on any script exit.

This approach avoids copying live SQLite files directly and keeps the backup
logic decoupled from discovery.

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

   - `RESTIC_REPOSITORY` → `/etc/backup.conf`
   - `RESTIC_PASSWORD`   → `/secrets/backup.env`

After that, `backup.sh` will:

- ensure the repository is accessible (`restic snapshots --last 1`),
- run `restic backup ...` with tags and excludes from `/etc/backup.conf`.

---

### Development Notes

- All scripts use `set -euo pipefail` where appropriate.
- Logging is centralized in `lib/logger.sh`:
  - If you add new modules, prefer calling `log_info/log_warn/log_error/log_debug`.
- No credentials are hard-coded; all secrets must come from `/secrets/backup.env`
  or the environment.

For contributions, keep shell code POSIX-ish where possible, but it is acceptable
to rely on Bash-specific features as the entrypoint is explicitly `bash`.

