# backup-utils

Linux client for [restic](https://restic.net/) backups over SFTP to a remote host. One machine can run several **jobs** (separate repos, paths, dumps, passwords). The client itself runs backup, forget/prune, check, and optional Telegram reports.

```text
[Linux host]
  jobs.d/*.conf
    dumps → restic backup -r sftp:user@remote:path
    forget / prune / check (same host)
    Telegram
  systemd timer (daily)
```

## Requirements

- bash, restic, openssh-client, curl (Telegram)
- `sqlite3` if SQLite dumps enabled
- `docker` if Postgres dump via container enabled
- systemd (for packaged timer)

## Install

```bash
cd /usr/local/src/backup-utils   # or any stable path
sudo bash install.sh
```

Symlink: `/usr/local/bin/backup.sh` → checkout. Config and secrets under `/usr/local/etc/backup/`. Update: `git pull` in the checkout. Remove: `sudo ./uninstall.sh`.

## Configuration

| File | Purpose |
|------|---------|
| `/usr/local/etc/backup/backup.conf` | Shared defaults (SFTP, retention, `CHECK_WEEKDAY`) |
| `/usr/local/etc/backup/jobs.d/*.conf` | One job = one restic repo + paths + dumps |
| `/usr/local/etc/backup/.env` | Default `RESTIC_PASSWORD`, optional `TG_*` |

Per-job password (optional): `RESTIC_PASSWORD=...` or `RESTIC_PASSWORD_FILE=/path` in the job file.

## Commands

```bash
backup.sh run [--job=NAME] [--no-forget] [--no-check]
backup.sh dump|forget|check|maintenance|init|status [--job=NAME]
```

- **run** (daily timer 04:00): dumps → backup → forget if enabled → check if `DO_CHECK_AFTER_BACKUP=1` or today is `CHECK_WEEKDAY` (default Sunday) → TG  
- **maintenance**: manual forget + check → TG (no separate timer)

## Security notes

- `backup.conf`, `jobs.d/*.conf`, and `.env` are **sourced as bash** — that is arbitrary code execution. Install only files you trust; prefer `root:root` and mode `640`/`600`.
- Key-only SFTP to the remote host; dedicated user; prefer restricted shell / chroot on the store side.
- Do not commit `.env` or real `*.conf`.
- When SQLite/Postgres dumps are enabled, dump failures abort the job (fail-closed).

## License

See [LICENSE](LICENSE).
