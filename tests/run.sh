#!/bin/sh
# shellcheck disable=SC2015,SC2012,SC2086 # ok() never fails; ls only lists what the test made; $TEST_SH is "busybox sh" and the like
# The tests of occulite-backup: the script against tests/stub.py, an HTTPS stand-in for
# openccu-lite's backup API (the prepared backup and the plain GET /backup) with a self-signed
# certificate made here.
#
#   sh tests/run.sh                      the script under sh
#   TEST_SH="busybox sh" sh tests/run.sh the script under busybox's ash
#
# Needs python3, openssl, curl, tar and timeout. Bounded: every run of the script is ended after
# TEST_CASE_TIMEOUT seconds (60), no file the tests write may grow past ~100 MB (ulimit -f), and the
# whole temporary directory is watched: past TEST_LIMIT_KB (100 MB) the suite stops.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HERE/occulite-backup"
TEST_SH=${TEST_SH:-sh}
CASE_TIMEOUT=${TEST_CASE_TIMEOUT:-60}
LIMIT_KB=${TEST_LIMIT_KB:-102400}
ORIG_PATH=$PATH

command -v timeout >/dev/null 2>&1 || { echo "the tests need timeout(1)"; exit 2; }
# no single file beyond ~100 MB (512-byte blocks in POSIX shells; 1 KB blocks in some: then 200 MB)
ulimit -f 204800 2>/dev/null || true

T=$(mktemp -d "${TMPDIR:-/tmp}/occulite-backup-test.XXXXXX") || exit 2
[ -d "$T" ] || exit 2
STUB_PID=
WATCH_PID=
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
  rm -rf "${T:?}"
}
trap cleanup EXIT
trap 'echo "tests: stopped"; exit 3' HUP INT TERM

# the watchdog: the temporary directory never grows unbounded
(
  while kill -0 $$ 2>/dev/null; do
    kb=$(du -sk "$T" 2>/dev/null | cut -f1)
    if [ "${kb:-0}" -gt "$LIMIT_KB" ]; then
      echo "tests: $T holds ${kb} KB, more than $LIMIT_KB KB - stopping" >&2
      kill -TERM $$ 2>/dev/null
      exit 1
    fi
    sleep 2
  done
) &
WATCH_PID=$!

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

# the certificate the stub serves and the one the script trusts with --ca
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" \
  -keyout "$T/key.pem" -out "$T/cert.pem" >/dev/null 2>&1 || { echo "openssl could not make a certificate"; exit 2; }
EV="$T/events"
python3 "$HERE/tests/stub.py" 0 "$T/cert.pem" "$T/key.pem" "$T/port" "$EV" &
STUB_PID=$!
i=0
while [ ! -s "$T/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$T/port" ] || { echo "the stub did not start"; exit 2; }
URL="https://127.0.0.1:$(cat "$T/port")"

# sut [options...]: the script under $TEST_SH, ended after CASE_TIMEOUT seconds
sut() { timeout "$CASE_TIMEOUT" $TEST_SH "$SCRIPT" "$@"; }
# run <token> [options...]: the script with the token in a file; output in $out, status in $rc
run() {
  printf '%s\n' "$1" >"$T/token"
  shift
  : >"$EV"
  out=$(sut --host "$URL" --token-file "$T/token" --ca "$T/cert.pem" --poll 1 "$@" 2>&1)
  rc=$?
}
fresh() { rm -rf "${T:?}/target"; mkdir -p "$T/target"; }
count() { find "$T/target" -type f | wc -l | tr -d ' '; }
no_part() { [ -z "$(find "$T/target" -name '.occulite-backup.*.part')" ]; }
events() { grep -c "$1" "$EV" | tr -d ' '; }

# --- a plain backup, through the prepared job
fresh
run good.ccu-a --target "$T/target"
f=$(find "$T/target" -name 'ccu-a-3.89.11.20260919-2026-10-20-*.sbk')
[ "$rc" = 0 ] && [ -n "$f" ] && tar -tf "$f" | grep -qx usr_local.tar.gz && echo "$out" | grep -q "^ok   $URL: " \
  && ok "a backup: saved under the system's name, a readable archive, exit 0" || bad "plain: rc $rc, $out"
[ "$(events '^POST /api/system/v1/backup/prepare good')" = 1 ] && [ "$(events '^GET /api/system/v1/backup/prepare/[0-9a-f]* good')" -ge 1 ] \
  && [ "$(events '^GET /api/system/v1/backup good')" = 1 ] && [ "$(events '^DELETE')" = 0 ] \
  && ok "prepared: POST prepare, poll, GET ?prepared, no DELETE" || bad "prepared events: $(cat "$EV")"
mode=$(ls -l "$f" 2>/dev/null | cut -c1-10)
[ "$mode" = "-rw-------" ] && ok "the backup is readable by its owner only (0600)" || bad "mode: $mode"

# --- the job runs for a while first
fresh
run wait.ccu-a --target "$T/target"
[ "$rc" = 0 ] && [ "$(count)" = 1 ] && [ "$(events '^GET /api/system/v1/backup/prepare/')" = 3 ] \
  && ok "a job that runs for three polls: waited for, then downloaded" || bad "wait: rc $rc, $out, $(cat "$EV")"

# --- a system before beta.12: prepare is 404, GET /backup alone over HTTP/1.1
fresh
run legacy.ccu-a --target "$T/target"
[ "$rc" = 0 ] && [ "$(count)" = 1 ] && [ "$(events '^GET /api/system/v1/backup legacy')" = 1 ] && [ "$(events 'prepare/')" = 0 ] \
  && ok "no prepare (404): the plain GET /backup" || bad "legacy: rc $rc, $out, $(cat "$EV")"

# --- the token from the environment
fresh
: >"$EV"
OCCULITE_TOKEN=good.ccu-a
export OCCULITE_TOKEN
out=$(sut --host "$URL" --ca "$T/cert.pem" --poll 1 --target "$T/target" --name ccu-a 2>&1); rc=$?
unset OCCULITE_TOKEN
[ "$rc" = 0 ] && [ "$(count)" = 1 ] && echo "$out" | grep -q '^ok   ccu-a: ' && ok "OCCULITE_TOKEN, --name in the summary" || bad "env token: rc $rc, $out"

# --- encrypted: no Content-Length, the age header, the name kept
fresh
run enc.ccu-a --target "$T/target"
f=$(find "$T/target" -name '*.sbk.age')
[ "$rc" = 0 ] && [ -n "$f" ] && [ "$(head -n 1 "$f")" = age-encryption.org/v1 ] && ok "an encrypted backup stays encrypted (.sbk.age)" || bad "enc: rc $rc, $out"

# --- failures: nothing left behind, exit 1, the reason named
for c in "bad.ccu-a|HTTP 401" "noscope.ccu-a|HTTP 403" "e500.ccu-a|HTTP 500" "trunc.ccu-a|download failed" \
         "corrupt.ccu-a|not a readable backup archive" "notccu.ccu-a|holds no usr_local.tar.gz" "noname.ccu-a|named no backup file" \
         "jobfail.ccu-a|could not make the backup (createBackup.sh: exit status 1)" "expired.ccu-a|expired before its download" \
         "gone.ccu-a|HTTP 410" "forgot.ccu-a|no longer knows the backup job"; do
  tok=${c%%|*}; want=${c#*|}
  fresh
  run "$tok" --target "$T/target"
  [ "$rc" = 1 ] && [ "$(count)" = 0 ] && no_part && echo "$out" | grep -qF "$want" && echo "$out" | grep -q "^FAIL " \
    && ok "$tok: refused ($want), nothing left" || bad "$tok: rc $rc, files $(count), $out"
done

# --- a busy system (a cancelled backup still finishing): asked again; given up at the timeout
fresh
run busy.ccu-a --target "$T/target"
[ "$rc" = 0 ] && [ "$(count)" = 1 ] && [ "$(events '^POST .* busy')" = 2 ] && ok "409 backup-busy: asked again, then downloaded" || bad "busy: rc $rc, $out, $(cat "$EV")"
fresh
run stuck.ccu-a --target "$T/target" --timeout 2
[ "$rc" = 1 ] && [ "$(count)" = 0 ] && echo "$out" | grep -q "still finishing a cancelled backup" \
  && ok "always 409: given up after --timeout" || bad "stuck: rc $rc, $out"

# --- a job that never gets ready: cancelled on the system at the timeout
fresh
run slow.ccu-a --target "$T/target" --timeout 3
[ "$rc" = 1 ] && [ "$(count)" = 0 ] && echo "$out" | grep -q "had not finished the backup after 3 s" && [ "$(events '^DELETE /api/system/v1/backup/prepare/[0-9a-f]* slow')" = 1 ] \
  && ok "never ready: DELETE of the job at the timeout, exit 1" || bad "slow: rc $rc, $out, $(cat "$EV")"
# one somebody else started (200, joined) is not cancelled by this run
fresh
run joined.ccu-a --target "$T/target" --timeout 2
[ "$rc" = 1 ] && [ "$(events '^DELETE')" = 0 ] && ok "a joined job (200) is left alone at the timeout" || bad "joined: rc $rc, $out, $(cat "$EV")"
# two failed polls are a blip
fresh
run blip.ccu-a --target "$T/target"
[ "$rc" = 0 ] && [ "$(count)" = 1 ] && ok "two polls with 503: asked again, downloaded" || bad "blip: rc $rc, $out, $(cat "$EV")"

# --- interrupted while the system builds it: the job is cancelled there
fresh
: >"$EV"
printf 'slow.ccu-a\n' >"$T/token"
$TEST_SH "$SCRIPT" --host "$URL" --token-file "$T/token" --ca "$T/cert.pem" --poll 1 --timeout 30 --target "$T/target" >"$T/sig.out" 2>&1 &
pid=$!
i=0
while [ "$(events '^GET /api/system/v1/backup/prepare/')" = 0 ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
kill -TERM "$pid" 2>/dev/null
wait "$pid"; rc=$?
[ "$rc" != 0 ] && [ "$(events '^DELETE /api/system/v1/backup/prepare/[0-9a-f]* slow')" = 1 ] && no_part \
  && ok "SIGTERM while the backup is made: the job is cancelled (DELETE)" || bad "signal: rc $rc, $(cat "$T/sig.out"), $(cat "$EV")"

# --- the certificate: unknown without --ca, accepted with --insecure
fresh
printf 'good.ccu-a\n' >"$T/token"
out=$(sut --host "$URL" --token-file "$T/token" --target "$T/target" 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(count)" = 0 ] && ok "a self-signed certificate without --ca: refused" || bad "no --ca: rc $rc, $out"
out=$(sut --host "$URL" --token-file "$T/token" --target "$T/target" --poll 1 --insecure 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(count)" = 1 ] && ok "--insecure: accepted" || bad "--insecure: rc $rc, $out"

# --- refused before anything is sent
out=$(sut --host "http://127.0.0.1:1" --token-file "$T/token" 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "not https://" && ok "http:// is refused" || bad "http: rc $rc, $out"
out=$(sut --host "$URL" --token good 2>&1); rc=$?
[ "$rc" = 2 ] && echo "$out" | grep -q "process list" && ok "--token on the command line is refused" || bad "--token: rc $rc, $out"
out=$(sut --host "$URL" --keep x 2>&1); rc=$?
[ "$rc" = 2 ] && ok "--keep x: a usage error" || bad "--keep x: rc $rc"
out=$(sut --host "$URL" --poll 0 2>&1); rc=$?
[ "$rc" = 2 ] && ok "--poll 0: a usage error" || bad "--poll 0: rc $rc"
out=$(sut 2>&1); rc=$?
[ "$rc" = 2 ] && echo "$out" | grep -q '^Usage:' && ok "no host: the usage, exit 2" || bad "no host: rc $rc"
out=$(sut --version); [ "$out" = "occulite-backup 1.0.0" ] && ok "--version" || bad "--version: $out"
fresh
: >"$T/empty"
out=$(sut --host "$URL" --token-file "$T/empty" --ca "$T/cert.pem" --target "$T/target" 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "no token" && ok "an empty token file: refused" || bad "empty token: rc $rc, $out"

# --- --keep: the newest N of that system stay; another system's files and foreign files are not touched
fresh
for d in 11 12 13; do
  : >"$T/target/ccu-a-3.89.10.20260801-2026-10-$d-1200.sbk"
  touch -t "202610${d}0000" "$T/target/ccu-a-3.89.10.20260801-2026-10-$d-1200.sbk"
done
: >"$T/target/ccu-b-3.89.11.20260919-2026-10-01-1200.sbk"; touch -t 202601010000 "$T/target/ccu-b-3.89.11.20260919-2026-10-01-1200.sbk"
: >"$T/target/ccu-a-notes.txt"; touch -t 202601010000 "$T/target/ccu-a-notes.txt"
: >"$T/target/ccu-a.sbk"; touch -t 202601010000 "$T/target/ccu-a.sbk"
run good.ccu-a --target "$T/target" --keep 2
left=$(cd "$T/target" && ls | LC_ALL=C sort | tr '\n' ' ')
[ "$rc" = 0 ] && [ ! -e "$T/target/ccu-a-3.89.10.20260801-2026-10-11-1200.sbk" ] && [ ! -e "$T/target/ccu-a-3.89.10.20260801-2026-10-12-1200.sbk" ] \
  && [ -e "$T/target/ccu-a-3.89.10.20260801-2026-10-13-1200.sbk" ] && [ -e "$T/target/ccu-b-3.89.11.20260919-2026-10-01-1200.sbk" ] \
  && [ -e "$T/target/ccu-a-notes.txt" ] && [ -e "$T/target/ccu-a.sbk" ] && [ "$(count)" = 5 ] \
  && echo "$out" | grep -q "removed ccu-a-3.89.10.20260801-2026-10-11-1200.sbk (keeping 2)" \
  && ok "--keep 2: the new one and the newest older one of ccu-a stay; ccu-b and foreign files untouched" || bad "keep: rc $rc, left: $left, $out"
# a failed download deletes nothing
before=$(count)
run e500.ccu-a --target "$T/target" --keep 1
[ "$rc" = 1 ] && [ "$(count)" = "$before" ] && ok "a failed download prunes nothing" || bad "keep after a failure: rc $rc, $(count) files"

# --- several systems from a config file: each line, the summary, exit 1 when one failed
fresh
mkdir -p "$T/target/a" "$T/target/b"
printf 'good.ccu-a\n' >"$T/tok-a"; printf 'e500.ccu-b\n' >"$T/tok-b"; printf 'enc.ccu-c\n' >"$T/tok-c"; printf 'legacy.ccu-d\n' >"$T/tok-d"
cat >"$T/systems.conf" <<CONF
# two systems, an encrypted one and one before beta.12
name=ccu-a host=$URL token_file=$T/tok-a ca=$T/cert.pem target=$T/target/a keep=3 poll=1
name=ccu-b host=$URL token_file=$T/tok-b ca=$T/cert.pem target=$T/target/b   # fails: HTTP 500

  name=ccu-c host=$URL token_file=$T/tok-c insecure=yes target=$T/target/b poll=1
name=ccu-d host=$URL token_file=$T/tok-d ca=$T/cert.pem target=$T/target/a
CONF
out=$(sut --config "$T/systems.conf" 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q '^ok   ccu-a: ' && echo "$out" | grep -q '^FAIL ccu-b: HTTP 500' \
  && echo "$out" | grep -q '^ok   ccu-c: ' && echo "$out" | grep -q '^ok   ccu-d: ' && echo "$out" | grep -q '^3 of 4 backups downloaded and checked$' \
  && [ "$(find "$T/target/a" -name '*.sbk' | wc -l | tr -d ' ')" = 2 ] && [ "$(find "$T/target/b" -name '*.sbk.age' | wc -l | tr -d ' ')" = 1 ] \
  && ok "a config with four systems: three saved, one failed, exit 1, the summary" || bad "config: rc $rc, $out"
sed -i.bak '/ccu-b/d' "$T/systems.conf"
out=$(sut --config "$T/systems.conf" 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q '^3 of 3 backups' && ok "every system saved: exit 0" || bad "config ok: rc $rc, $out"
printf 'name=x host=%s colour=blue\n' "$URL" >"$T/bad.conf"
out=$(sut --config "$T/bad.conf" 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "unknown setting 'colour=blue'" && ok "an unknown setting fails that line" || bad "bad config: rc $rc, $out"
printf '# nothing\n\n' >"$T/none.conf"
out=$(sut --config "$T/none.conf" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "a config without systems: a usage error" || bad "empty config: rc $rc, $out"

# --- curl's command lines, seen through a recording stand-in: the token never on them, and
# HTTP/1.1 for the plain GET /backup. The stand-in runs the real curl with the original PATH (so a
# real curl that is itself a wrapper cannot call the stand-in again), refuses to be called from
# itself, and records at most 64 KB.
REAL_CURL=$(command -v curl)
case "$REAL_CURL" in /*) ;; *) echo "curl is not a file here ($REAL_CURL)"; exit 2 ;; esac
case "$REAL_CURL" in "$T"/*) echo "curl resolves into the test directory"; exit 2 ;; esac
mkdir -p "$T/bin"
: >"$T/argv"
cat >"$T/bin/curl" <<STUB
#!/bin/sh
if [ -n "\${OB_TEST_CURL:-}" ]; then echo "the recording curl was called from itself" >&2; exit 97; fi
OB_TEST_CURL=1; export OB_TEST_CURL
PATH='$ORIG_PATH'; export PATH
if [ "\$(wc -c <'$T/argv')" -lt 65536 ]; then printf '%s\n' "\$*" >>'$T/argv'; fi
exec '$REAL_CURL' "\$@"
STUB
chmod 755 "$T/bin/curl"
fresh
printf 'good.secret-host\n' >"$T/token"
PATH="$T/bin:$PATH" timeout "$CASE_TIMEOUT" $TEST_SH "$SCRIPT" --host "$URL" --token-file "$T/token" --ca "$T/cert.pem" --poll 1 --target "$T/target" >/dev/null 2>&1
[ -s "$T/argv" ] && [ "$(wc -l <"$T/argv" | tr -d ' ')" -ge 3 ] && ! grep -q 'secret-host' "$T/argv" \
  && ok "the token is on none of curl's command lines (prepare, poll, download)" || bad "argv: $(cat "$T/argv")"
: >"$T/argv"
printf 'legacy.ccu-a\n' >"$T/token"
PATH="$T/bin:$PATH" timeout "$CASE_TIMEOUT" $TEST_SH "$SCRIPT" --host "$URL" --token-file "$T/token" --ca "$T/cert.pem" --target "$T/target" >/dev/null 2>&1
grep -- '--http1.1' "$T/argv" | grep -q '/api/system/v1/backup$' && ok "the plain GET /backup goes over HTTP/1.1" || bad "http1.1: $(cat "$T/argv")"

if [ "$fails" = 0 ]; then echo "occulite-backup tests ($TEST_SH): all passed"; else echo "occulite-backup tests ($TEST_SH): $fails failed"; exit 1; fi
