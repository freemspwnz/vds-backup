# backup-utils

Linux client for [restic](https://restic.net/) backups to a remote store over **SFTP** or **REST server**. One machine can run several **jobs** (separate repos, paths, dumps, passwords). The client runs backup, forget/prune, check, and optional Telegram reports.

```text
[Linux host]
  jobs.d/*.conf
    dumps → restic backup -r sftp:…  or  rest:https://…
    forget / prune / check (same host)
    Telegram
  systemd timer (daily)
```

## Requirements

- bash ≥ 4.1 (associative arrays, `{fd}` redirects; not macOS `/bin/bash` 3.2)
- restic, curl (Telegram), `flock` (util-linux)
- `openssh-client` when using `BACKEND=sftp`
- `sqlite3` if SQLite dumps enabled
- `docker` if Postgres dump via container enabled
- systemd (for packaged timer)

## Install

```bash
cd /usr/local/src/backup-utils   # or any stable path
sudo bash install.sh
```

Symlink: `/usr/local/bin/backup.sh` → checkout. Config and secrets under `/usr/local/etc/backup/`. Update: `git pull` in the checkout. Remove: `sudo ./uninstall.sh` (prompts before deleting secrets; `sudo ./uninstall.sh --yes` to skip).

## Configuration

| File | Purpose |
|------|---------|
| `/usr/local/etc/backup/backup.conf` | Shared defaults (`BACKEND`, SFTP/REST, retention, `CHECK_WEEKDAY`) |
| `/usr/local/etc/backup/jobs.d/*.conf` | One job = one restic repo + paths + dumps |
| `/usr/local/etc/backup/.env` | Default `RESTIC_PASSWORD`, optional `REST_USER`/`REST_PASS`, `TG_*` |

`BACKEND=sftp` (default) or `BACKEND=rest`. Jobs may override `BACKEND` and host fields. If `RESTIC_REPOSITORY` is set explicitly, it is used as-is and the scheme (`sftp:` / `rest:`) selects the transport.

Per-job password (optional): `RESTIC_PASSWORD=...` or `RESTIC_PASSWORD_FILE=/path` in the job file. For rest-server HTTP auth, set `REST_USER` / `REST_PASS` in `.env` (or the job).

## Commands

```bash
backup.sh run [--job=NAME] [--no-forget] [--no-check]
backup.sh dump|forget|check|maintenance|init|status [--job=NAME]
```

- **run** (daily timer 04:00): dumps → backup → forget if enabled → check if `DO_CHECK_AFTER_BACKUP=1` or today is `CHECK_WEEKDAY` (default Sunday) → TG  
- **maintenance**: manual forget + check → TG (no separate timer)

### Per-job locks (busy policy)

Each job uses a flock under `LOCK_DIR_BASE` so two processes cannot mutate the same repo at once. When the lock is **busy** (another run already holds it), behavior is intentional and differs by command:

| Command | Lock busy | Why |
|---------|-----------|-----|
| `run`, `maintenance` | Soft-skip that job (exit 0 for that job; continue) | Timer/overlap-safe: a concurrent backup is enough; do not fail the whole schedule |
| `forget`, `check`, `init` | Fail the command (non-zero exit) | Explicit/manual ops must not silently no-op |

Lock **errors** (permissions, missing `flock`, etc.) always fail the command.

## Security notes

- `backup.conf`, `jobs.d/*.conf`, and `.env` are **sourced as bash** — that is arbitrary code execution. Install only files you trust; prefer `root:root` and mode `640`/`600`.
- SFTP: key-only access; dedicated user; prefer restricted shell / chroot on the store side.
- REST: prefer HTTPS + HTTP auth (`REST_USER` / `REST_PASS`); use `RESTIC_CACERT` for a private CA.
- Do not commit `.env` or real `*.conf`.
- When SQLite/Postgres dumps are enabled, dump failures abort the job (fail-closed).

## License

See [LICENSE](LICENSE).
