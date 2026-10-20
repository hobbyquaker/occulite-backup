# occulite-backup

[Deutsch](README.de.md)

Downloads the backups of [openccu-lite](https://github.com/hobbyquaker/openccu-lite) systems: one POSIX shell
script, `curl` its only dependency. It runs on a Linux server, on a NAS (Synology, QNAP) and on a router with
busybox, from cron or a systemd timer.

- fetches the current backup (`GET /api/system/v1/backup`) with an API token that may do nothing but backups;
- **checks the download** before anything older is touched: HTTP 200, not empty, as long as the system said, and
  readable - a `.sbk` must open as the CCU's archive (a tar with `usr_local.tar.gz` in it), an encrypted `.sbk.age` must start with the age header. A failed
  download is removed and the run fails;
- saves it under the name the system gives it (`<host>-<version>-<date>-<time>.sbk`); an encrypted backup stays
  encrypted;
- `--keep N` keeps the newest N backups of that system in the target folder and deletes older ones - only after a
  checked new one;
- several systems from one config file, one summary line each;
- exit status 0 only when every backup was saved and checked (1 otherwise, 2 for a usage error), so cron mail and
  monitoring see a failure.

## Install

```sh
curl -fsSLO https://github.com/hobbyquaker/occulite-backup/releases/latest/download/occulite-backup
curl -fsSLO https://github.com/hobbyquaker/occulite-backup/releases/latest/download/occulite-backup.sha256
sha256sum -c occulite-backup.sha256
install -m 0755 occulite-backup /usr/local/bin/occulite-backup
```

It needs `curl` 7.55 or newer (2017), `tar`, and a POSIX shell (`sh`, `dash`, `bash`, busybox `ash`).

## 1. A token that can only make backups

On the openccu-lite system, as an administrator:

1. **System → Remote access → API tokens → New token**.
2. Name: e.g. `nas-backup`.
3. Permissions: tick **Backups** only (not *Full access*). The token can then download backups and nothing else - no
   settings, no devices, no reboot.
4. *Allowed from*: the address of the machine that runs the script (e.g. `192.168.1.20`), so the token is useless
   anywhere else. When the system's name resolves to IPv6 as well, the request may come from the machine's IPv6
   address: add that (or its /64) too, or give `--host` the system's IPv4 address. *Expires*: empty for a token that runs from cron, or a date.
5. **Create token** and copy it now - it is shown once.

Put it into a file only you can read, never on a command line (it would show in the process list and the shell
history):

```sh
install -d -m 0700 /etc/occulite-backup
printf '%s\n' 'PASTE-THE-TOKEN-HERE' > /etc/occulite-backup/ccu.token
chmod 0600 /etc/occulite-backup/ccu.token
```

A backup holds the radio keys of the system. Keep the token and the backups as carefully as the system itself. With
backup encryption switched on (System → Backup) the system hands out `.sbk.age` files that only its own key or the
recovery key opens; occulite-backup stores them as they are.

## 2. The system's certificate

The script talks HTTPS only. A system with a certificate from a public or your own CA needs nothing; one with its
self-signed certificate needs that certificate as `--ca`. Fetch it once and compare its fingerprint with the one on
**System → Certificate** (*Fingerprint (SHA-256)*):

```sh
openssl s_client -connect ccu.example:443 -servername ccu.example </dev/null 2>/dev/null \
  | openssl x509 > /etc/occulite-backup/ccu.pem
openssl x509 -in /etc/occulite-backup/ccu.pem -noout -fingerprint -sha256
```

`--insecure` switches the certificate check off altogether. It is the last resort: anyone between the two machines
could then read the token and the backup. Use `--ca` instead.

## 3. Run it

```sh
occulite-backup --host https://ccu.example --token-file /etc/occulite-backup/ccu.token \
  --ca /etc/occulite-backup/ccu.pem --target /srv/backup/ccu --keep 14
```

```
ok   https://ccu.example: /srv/backup/ccu/ccu-3.89.11.20260919-2026-10-20-0300.sbk (48213760 bytes)
  removed ccu-3.89.11.20260919-2026-10-06-0300.sbk (keeping 14)
```

The token can also come from the environment, `OCCULITE_TOKEN`, instead of `--token-file`. The system builds the
backup when asked; that takes a minute or two on a small board, so the default `--timeout` is 1800 seconds.

| Option | |
| --- | --- |
| `--host URL` | the system, `https://name-or-address[:port]` |
| `--token-file FILE` | the token's file (its first line); else `$OCCULITE_TOKEN` |
| `--ca FILE` | the system's certificate or its CA, PEM |
| `--insecure` | no certificate check (last resort) |
| `--target DIR` | where the backups go (default: the current directory) |
| `--keep N` | keep the newest N backups of this system there (default 0: keep all) |
| `--name NAME` | the system's name in the summary |
| `--timeout SECONDS` | for the whole download (default 1800) |
| `--config FILE` | several systems, see below |

`--keep` counts the files of **this system** only, by the host name at the start of the system's file names
(`<host>-<version>-<date>-<time>.sbk`, newest by time): another system's backups in the same folder and any other
file are left alone. Nothing is deleted when the new download failed.

## Several systems

One line per system, `key=value` settings separated by blanks (no blanks inside a value); `#` starts a comment.
Settings: `name`, `host`, `token_file`, `ca`, `insecure` (`yes`), `target`, `keep`, `timeout`. Options given on the
command line are the defaults for every line.

```
# /etc/occulite-backup/systems.conf
name=house   host=https://ccu-house.lan   token_file=/etc/occulite-backup/house.token   ca=/etc/occulite-backup/house.pem   target=/srv/backup/house   keep=14
name=garage  host=https://ccu-garage.lan  token_file=/etc/occulite-backup/garage.token  ca=/etc/occulite-backup/garage.pem  target=/srv/backup/garage  keep=7
```

```sh
occulite-backup --config /etc/occulite-backup/systems.conf
```

```
ok   house: /srv/backup/house/ccu-house-3.89.11.20260919-2026-10-20-0300.sbk (48213760 bytes)
FAIL garage: HTTP 401: the token is not accepted (wrong, expired or deleted)
1 of 2 backups downloaded and checked
```

Every system is tried; the exit status is 1 when any of them failed.

## Every night

**cron** (`crontab -e` as the user that owns the token files):

```
15 3 * * *  /usr/local/bin/occulite-backup --config /etc/occulite-backup/systems.conf
```

cron mails the output when the machine can send mail; a non-zero exit is what a monitoring check looks at.

**systemd timer:**

```ini
# /etc/systemd/system/occulite-backup.service
[Unit]
Description=Backups of the openccu-lite systems
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/occulite-backup --config /etc/occulite-backup/systems.conf
```

```ini
# /etc/systemd/system/occulite-backup.timer
[Unit]
Description=Backups of the openccu-lite systems, nightly

[Timer]
OnCalendar=*-*-* 03:15
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target
```

```sh
systemctl daemon-reload && systemctl enable --now occulite-backup.timer
journalctl -u occulite-backup.service     # the last runs
```

## NAS

- **Synology DSM:** copy the script to a shared folder (e.g. `/volume1/scripts/occulite-backup`), then *Control
  Panel → Task Scheduler → Create → Scheduled Task → User-defined script*, run as a user who may read the token files
  and write the target, with `sh /volume1/scripts/occulite-backup --config /volume1/scripts/systems.conf`. Tick
  *Send run details by email* and *only when the script terminates abnormally*. DSM's `curl` is recent enough.
- **QNAP QTS:** put the script on a share, add the line above to `/etc/config/crontab` and run
  `crontab /etc/config/crontab && /etc/init.d/crond.sh restart` (QTS rewrites `crontab -e` changes at a reboot).
- **Routers and small boxes with busybox:** `ash` runs the script; install `curl` from the package feed (OpenWrt:
  `opkg install curl`). Busybox's own `wget` cannot replace it.

## When it fails

| Message | |
| --- | --- |
| `HTTP 401: the token is not accepted` | a wrong, expired or deleted token - or one not allowed from the address the request came from (IPv6, see step 1) |
| `HTTP 403` | the token lacks the *Backups* permission |
| `curl 60 … self-signed certificate` | `--ca` is missing or names another certificate (step 2) |
| `curl 16` / `curl 18` / `curl 52` after about six minutes | the system needed longer than its web server waits to build the backup (a large `/usr/local`, big addons); the system's own download in the browser stops the same way |
| `… is not a readable backup archive` | the file is damaged; nothing older was deleted |

The backups are written readable by their owner only (mode 0600): they hold the radio keys.

## Restoring

A downloaded `.sbk` (or `.sbk.age`) is restored on the system under **System → Backup → Restore a backup**, as one
from the system's own download; it also restores on OpenCCU and a CCU3.

## Tests

`sh tests/run.sh` runs the script against `tests/stub.py`, an HTTPS stand-in for the system's backup download (a
token check, the file stream, 401, 403, 500, a truncated download, a broken archive, a tar that is no CCU backup, the encrypted variant, `--keep`,
a config with several systems). It needs `python3`, `openssl`, `curl` and `tar`; `TEST_SH="busybox sh"` runs the
script under busybox. CI runs it under dash, bash and busybox, on Ubuntu and Alpine, and shellcheck.

## Licence

MIT, see [LICENSE](LICENSE).
