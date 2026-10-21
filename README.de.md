# occulite-backup

[English](README.md)

Lädt die Sicherungen von [openccu-lite](https://github.com/hobbyquaker/openccu-lite)-Systemen herunter: ein
POSIX-Shell-Skript, einzige Abhängigkeit `curl`. Es läuft auf einem Linux-Server, einem NAS (Synology, QNAP) und
einem Router mit busybox, per cron oder systemd-Timer.

- lässt das System eine frische Sicherung erstellen und lädt sie herunter, mit einem API-Token, das nichts anderes
  darf als Sicherungen: es startet die Sicherung (`POST /api/system/v1/backup/prepare`), wartet, bis sie fertig ist,
  und holt dann die Datei (`GET /api/system/v1/backup?prepared=<id>`); ein System vor openccu-lite 1.0.0-beta.12
  bekommt das einfache `GET /api/system/v1/backup` über HTTP/1.1;
- **prüft den Download**, bevor etwas Älteres angefasst wird: HTTP 200, nicht leer, so lang wie vom System
  angekündigt und lesbar - eine `.sbk` muss sich als CCU-Archiv öffnen lassen (ein tar mit `usr_local.tar.gz` darin), eine verschlüsselte `.sbk.age` mit dem
  age-Kopf beginnen. Ein fehlgeschlagener Download wird gelöscht und der Lauf schlägt fehl;
- speichert sie unter dem Namen, den das System vergibt (`<host>-<version>-<datum>-<uhrzeit>.sbk`); eine
  verschlüsselte Sicherung bleibt verschlüsselt;
- `--keep N` behält die neuesten N Sicherungen dieses Systems im Zielordner und löscht ältere - erst nach einer
  geprüften neuen;
- mehrere Systeme aus einer Konfigurationsdatei, je System eine Zeile in der Zusammenfassung;
- Exit-Status 0 nur, wenn jede Sicherung gespeichert und geprüft wurde (sonst 1, 2 bei falschem Aufruf), damit
  cron-Mail und Monitoring einen Fehler sehen.

## Installation

```sh
curl -fsSLO https://github.com/hobbyquaker/occulite-backup/releases/latest/download/occulite-backup
curl -fsSLO https://github.com/hobbyquaker/occulite-backup/releases/latest/download/occulite-backup.sha256
sha256sum -c occulite-backup.sha256
install -m 0755 occulite-backup /usr/local/bin/occulite-backup
```

Nötig sind `curl` ab 7.55 (2017), `tar` und eine POSIX-Shell (`sh`, `dash`, `bash`, busybox `ash`).

## 1. Ein Token, das nur Sicherungen darf

Auf dem openccu-lite-System, als Administrator:

1. **System → Fernzugriff → API-Tokens → Neues Token**.
2. Name: z. B. `nas-sicherung`.
3. Berechtigungen: nur **Sicherungen** ankreuzen (nicht *Vollzugriff*). Das Token kann dann Sicherungen
   herunterladen und sonst nichts - keine Einstellungen, keine Geräte, kein Neustart.
4. *Erlaubt von*: die Adresse des Rechners, auf dem das Skript läuft (z. B. `192.168.1.20`); anderswo ist das Token
   dann nutzlos. Löst der Name des Systems auch zu IPv6 auf, kann die Anfrage von der IPv6-Adresse des Rechners
   kommen: diese (oder ihr /64) ebenfalls eintragen, oder `--host` die IPv4-Adresse des Systems geben. *Läuft ab*: leer für ein Token, das aus cron läuft, oder ein Datum.
5. **Token erstellen** und es sofort kopieren - es wird nur einmal angezeigt.

Das Token gehört in eine Datei, die nur der eigene Benutzer lesen kann, nie auf eine Befehlszeile (dort stünde es in
der Prozessliste und im Shell-Verlauf):

```sh
install -d -m 0700 /etc/occulite-backup
printf '%s\n' 'HIER-DAS-TOKEN-EINFÜGEN' > /etc/occulite-backup/ccu.token
chmod 0600 /etc/occulite-backup/ccu.token
```

Eine Sicherung enthält die Funkschlüssel des Systems. Token und Sicherungen verdienen dieselbe Sorgfalt wie das
System selbst. Ist die Verschlüsselung der Sicherungen eingeschaltet (System → Sicherung), gibt das System
`.sbk.age`-Dateien heraus, die nur sein eigener Schlüssel oder der Wiederherstellungsschlüssel öffnet;
occulite-backup speichert sie unverändert.

## 2. Das Zertifikat des Systems

Das Skript spricht nur HTTPS. Ein System mit einem Zertifikat einer öffentlichen oder eigenen CA braucht nichts
weiter; eines mit seinem selbstsignierten Zertifikat braucht dieses als `--ca`. Einmal abholen und den
Fingerabdruck mit dem unter **System → Zertifikat** (*Fingerabdruck (SHA-256)*) vergleichen:

```sh
openssl s_client -connect ccu.example:443 -servername ccu.example </dev/null 2>/dev/null \
  | openssl x509 > /etc/occulite-backup/ccu.pem
openssl x509 -in /etc/occulite-backup/ccu.pem -noout -fingerprint -sha256
```

`--insecure` schaltet die Prüfung des Zertifikats ganz ab. Das ist der letzte Ausweg: Jeder zwischen den beiden
Rechnern könnte dann Token und Sicherung mitlesen. Besser `--ca`.

## 3. Aufruf

```sh
occulite-backup --host https://ccu.example --token-file /etc/occulite-backup/ccu.token \
  --ca /etc/occulite-backup/ccu.pem --target /srv/backup/ccu --keep 14
```

```
ok   https://ccu.example: /srv/backup/ccu/ccu-3.89.11.20260919-2026-10-20-0300.sbk (48213760 bytes)
  removed ccu-3.89.11.20260919-2026-10-06-0300.sbk (keeping 14)
```

Statt `--token-file` geht auch die Umgebungsvariable `OCCULITE_TOKEN`. Das System erstellt die Sicherung erst auf
Anfrage; auf einer kleinen Platine dauert das ein, zwei Minuten, mit einem großen `/usr/local` (große Addons) zehn
Minuten und mehr, deshalb ist `--timeout` standardmäßig 1800 Sekunden - für das Erstellen und noch einmal für den
Download. Das Skript fragt alle `--poll` Sekunden (5), ob sie fertig ist. Wird es angehalten, während das System die
Sicherung erstellt (Strg-C, `SIGTERM`, der Timeout), bricht es diese Sicherung auf dem System ab, damit ihre Datei
dort nicht liegen bleibt.

**Für große Sicherungen wird openccu-lite 1.0.0-beta.12 oder neuer empfohlen.** Ab dieser Version erstellt das
System die Sicherung zuerst und gibt sie heraus, wenn sie vollständig ist. Ein älteres System erstellt sie, während
der Download wartet; das Skript nimmt dann HTTP/1.1, das für jede Größe funktioniert, solange nichts zwischen den
beiden Rechnern (ein Reverse-Proxy) das lange Warten abbricht.

| Option | |
| --- | --- |
| `--host URL` | das System, `https://name-oder-adresse[:port]` |
| `--token-file DATEI` | die Datei mit dem Token (erste Zeile); sonst `$OCCULITE_TOKEN` |
| `--ca DATEI` | das Zertifikat des Systems oder seine CA, PEM |
| `--insecure` | keine Prüfung des Zertifikats (letzter Ausweg) |
| `--target ORDNER` | wohin die Sicherungen kommen (Standard: das aktuelle Verzeichnis) |
| `--keep N` | die neuesten N Sicherungen dieses Systems dort behalten (Standard 0: alle) |
| `--name NAME` | der Name des Systems in der Zusammenfassung |
| `--timeout SEKUNDEN` | für das Erstellen der Sicherung und noch einmal für ihren Download (Standard 1800) |
| `--poll SEKUNDEN` | wie oft gefragt wird, ob die Sicherung fertig ist (Standard 5) |
| `--config DATEI` | mehrere Systeme, siehe unten |

`--keep` zählt nur die Dateien **dieses Systems**, am Hostnamen am Anfang der Dateinamen des Systems
(`<host>-<version>-<datum>-<uhrzeit>.sbk`, die neuesten nach Zeit): Sicherungen anderer Systeme im selben Ordner
und alle anderen Dateien bleiben unberührt. Schlägt der neue Download fehl, wird nichts gelöscht.

## Mehrere Systeme

Eine Zeile je System, Einstellungen als `schlüssel=wert` durch Leerzeichen getrennt (keine Leerzeichen in einem
Wert); `#` beginnt einen Kommentar. Einstellungen: `name`, `host`, `token_file`, `ca`, `insecure` (`yes`),
`target`, `keep`, `timeout`, `poll`. Optionen auf der Befehlszeile gelten als Vorgabe für jede Zeile.

```
# /etc/occulite-backup/systems.conf
name=haus    host=https://ccu-haus.lan    token_file=/etc/occulite-backup/haus.token    ca=/etc/occulite-backup/haus.pem    target=/srv/backup/haus    keep=14
name=garage  host=https://ccu-garage.lan  token_file=/etc/occulite-backup/garage.token  ca=/etc/occulite-backup/garage.pem  target=/srv/backup/garage  keep=7
```

```sh
occulite-backup --config /etc/occulite-backup/systems.conf
```

```
ok   haus: /srv/backup/haus/ccu-haus-3.89.11.20260919-2026-10-20-0300.sbk (48213760 bytes)
FAIL garage: HTTP 401: the token is not accepted (wrong, expired or deleted)
1 of 2 backups downloaded and checked
```

Jedes System wird versucht; der Exit-Status ist 1, wenn eines davon fehlschlug. Die Meldungen des Skripts sind
englisch.

## Jede Nacht

**cron** (`crontab -e` als der Benutzer, dem die Token-Dateien gehören):

```
15 3 * * *  /usr/local/bin/occulite-backup --config /etc/occulite-backup/systems.conf
```

cron schickt die Ausgabe per Mail, wenn der Rechner Mail versenden kann; ein Exit-Status ungleich 0 ist das, worauf
eine Monitoring-Prüfung schaut.

**systemd-Timer:**

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
journalctl -u occulite-backup.service     # die letzten Läufe
```

## NAS

- **Synology DSM:** das Skript in einen freigegebenen Ordner kopieren (z. B. `/volume1/scripts/occulite-backup`),
  dann *Systemsteuerung → Aufgabenplaner → Erstellen → Geplante Aufgabe → Benutzerdefiniertes Script*, als ein
  Benutzer, der die Token-Dateien lesen und ins Ziel schreiben darf, mit
  `sh /volume1/scripts/occulite-backup --config /volume1/scripts/systems.conf`. *Ausführungsdetails per E-Mail
  senden* und *nur wenn das Script nicht normal beendet wird* ankreuzen. Das `curl` von DSM ist neu genug.
- **QNAP QTS:** das Skript auf eine Freigabe legen, die Zeile von oben in `/etc/config/crontab` eintragen und
  `crontab /etc/config/crontab && /etc/init.d/crond.sh restart` ausführen (QTS überschreibt Änderungen per
  `crontab -e` beim Neustart).
- **Router und kleine Geräte mit busybox:** `ash` führt das Skript aus; `curl` aus dem Paket-Feed installieren
  (OpenWrt: `opkg install curl`). Das `wget` von busybox ersetzt es nicht.

## Wenn es fehlschlägt

| Meldung | |
| --- | --- |
| `HTTP 401: the token is not accepted` | ein falsches, abgelaufenes oder gelöschtes Token - oder eines, das von der Adresse der Anfrage nicht erlaubt ist (IPv6, siehe Schritt 1) |
| `HTTP 403` | dem Token fehlt die Berechtigung *Sicherungen* |
| `curl 60 … self-signed certificate` | `--ca` fehlt oder nennt ein anderes Zertifikat (Schritt 2) |
| `the system had not finished the backup after … s (cancelled)` | ein großes `/usr/local`: `--timeout` erhöhen |
| `the system was still finishing a cancelled backup` (HTTP 409) | eine vorher abgebrochene Sicherung läuft auf dem System noch zu Ende; der nächste Lauf klappt |
| `the prepared backup expired before its download` / `HTTP 410` | die fertige Sicherung hat länger als 30 Minuten gewartet, oder jemand hat sie auf der Sicherungsseite des Systems abgebrochen |
| `curl 16` / `curl 18` / `curl 52` nach etwa sechs Minuten | ein System vor 1.0.0-beta.12 hinter einem Proxy, der das Warten abbricht: das System aktualisieren oder direkt verbinden |
| `… is not a readable backup archive` | die Datei ist beschädigt; nichts Älteres wurde gelöscht |

Die Sicherungen werden nur für ihren Besitzer lesbar geschrieben (Modus 0600): Sie enthalten die Funkschlüssel.

## Wiederherstellen

Eine heruntergeladene `.sbk` (oder `.sbk.age`) wird auf dem System unter **System → Sicherung → Sicherung
einspielen** eingespielt, wie eine aus dem Download des Systems selbst; sie lässt sich auch auf OpenCCU und einer
CCU3 einspielen.

## Tests

`sh tests/run.sh` lässt das Skript gegen `tests/stub.py` laufen, einen HTTPS-Ersatz für die Sicherungs-API des
Systems (Token-Prüfung, die vorbereitete Sicherung mit ihrem Abfragen, ein beschäftigtes System, eine Sicherung, die
fehlschlägt, verfällt oder nie fertig wird und dann abgebrochen wird, der Abbruch bei `SIGTERM`, der einfache Download
eines älteren Systems über HTTP/1.1, Datei-Stream, 401, 403, 500, abgebrochener Download, kaputtes Archiv, ein tar
ohne CCU-Sicherung, die verschlüsselte Variante, `--keep`, eine Konfiguration mit mehreren Systemen). Nötig sind
`python3`, `openssl`, `curl`, `tar` und `timeout`; `TEST_SH="busybox sh"` führt das Skript unter busybox aus. Jeder
Lauf des Skripts darin wird nach 60 Sekunden beendet, und die Tests brechen ab, wenn ihr temporäres Verzeichnis
über 100 MB wächst. Die CI lässt es unter dash, bash und busybox laufen, auf Ubuntu und Alpine, dazu shellcheck.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
