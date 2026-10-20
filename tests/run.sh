#!/bin/sh
# shellcheck disable=SC2015,SC2012 # ok() never fails; ls only lists what the test made
# The tests of occulite-backup: the script against tests/stub.py, an HTTPS stand-in for
# openccu-lite's GET /api/system/v1/backup with a self-signed certificate made here.
#
#   sh tests/run.sh                      the script under sh
#   TEST_SH="busybox sh" sh tests/run.sh the script under busybox's ash
#
# Needs python3, openssl, curl and tar.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HERE/occulite-backup"
TEST_SH=${TEST_SH:-sh}

T=$(mktemp -d) || exit 2
[ -d "$T" ] || exit 2
STUB_PID=
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  rm -rf "${T:?}"
}
trap cleanup EXIT

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

# the certificate the stub serves and the one the script trusts with --ca
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" \
  -keyout "$T/key.pem" -out "$T/cert.pem" >/dev/null 2>&1 || { echo "openssl could not make a certificate"; exit 2; }
python3 "$HERE/tests/stub.py" 0 "$T/cert.pem" "$T/key.pem" "$T/port" &
STUB_PID=$!
i=0
while [ ! -s "$T/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$T/port" ] || { echo "the stub did not start"; exit 2; }
URL="https://127.0.0.1:$(cat "$T/port")"

# run <token> [options...]: the script with the token in a file; output in $out, status in $rc
run() {
  printf '%s\n' "$1" >"$T/token"
  shift
  out=$($TEST_SH "$SCRIPT" --host "$URL" --token-file "$T/token" --ca "$T/cert.pem" "$@" 2>&1)
  rc=$?
}
fresh() { rm -rf "${T:?}/target"; mkdir -p "$T/target"; }
count() { find "$T/target" -type f | wc -l | tr -d ' '; }
no_part() { [ -z "$(find "$T/target" -name '.occulite-backup.*.part')" ]; }

# --- a plain backup
fresh
run good.ccu-a --target "$T/target"
f=$(find "$T/target" -name 'ccu-a-3.89.11.20260919-2026-10-20-*.sbk')
[ "$rc" = 0 ] && [ -n "$f" ] && tar -tf "$f" | grep -qx usr_local.tar.gz && echo "$out" | grep -q "^ok   $URL: " \
  && ok "a backup: saved under the system's name, a readable archive, exit 0" || bad "plain: rc $rc, $out"
mode=$(ls -l "$f" 2>/dev/null | cut -c1-10)
[ "$mode" = "-rw-------" ] && ok "the backup is readable by its owner only (0600)" || bad "mode: $mode"

# --- the token from the environment
fresh
out=$(OCCULITE_TOKEN=good.ccu-a $TEST_SH "$SCRIPT" --host "$URL" --ca "$T/cert.pem" --target "$T/target" --name ccu-a 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(count)" = 1 ] && echo "$out" | grep -q '^ok   ccu-a: ' && ok "OCCULITE_TOKEN, --name in the summary" || bad "env token: rc $rc, $out"

# --- encrypted: no Content-Length, the age header, the name kept
fresh
run enc.ccu-a --target "$T/target"
f=$(find "$T/target" -name '*.sbk.age')
[ "$rc" = 0 ] && [ -n "$f" ] && [ "$(head -n 1 "$f")" = age-encryption.org/v1 ] && ok "an encrypted backup stays encrypted (.sbk.age)" || bad "enc: rc $rc, $out"

# --- failures: nothing left behind, exit 1, the reason named
for c in "bad.ccu-a|HTTP 401" "noscope.ccu-a|HTTP 403" "e500.ccu-a|HTTP 500" "trunc.ccu-a|download failed" \
         "corrupt.ccu-a|not a readable backup archive" "notccu.ccu-a|holds no usr_local.tar.gz" "noname.ccu-a|named no backup file"; do
  tok=${c%%|*}; want=${c#*|}
  fresh
  run "$tok" --target "$T/target"
  [ "$rc" = 1 ] && [ "$(count)" = 0 ] && no_part && echo "$out" | grep -q "^FAIL .*$want" \
    && ok "$tok: refused ($want), nothing left" || bad "$tok: rc $rc, files $(count), $out"
done

# --- the certificate: unknown without --ca, accepted with --insecure
fresh
printf 'good.ccu-a\n' >"$T/token"
out=$($TEST_SH "$SCRIPT" --host "$URL" --token-file "$T/token" --target "$T/target" 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(count)" = 0 ] && ok "a self-signed certificate without --ca: refused" || bad "no --ca: rc $rc, $out"
out=$($TEST_SH "$SCRIPT" --host "$URL" --token-file "$T/token" --target "$T/target" --insecure 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(count)" = 1 ] && ok "--insecure: accepted" || bad "--insecure: rc $rc, $out"

# --- refused before anything is sent
out=$($TEST_SH "$SCRIPT" --host "http://127.0.0.1:1" --token-file "$T/token" 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "not https://" && ok "http:// is refused" || bad "http: rc $rc, $out"
out=$($TEST_SH "$SCRIPT" --host "$URL" --token good 2>&1); rc=$?
[ "$rc" = 2 ] && echo "$out" | grep -q "process list" && ok "--token on the command line is refused" || bad "--token: rc $rc, $out"
out=$($TEST_SH "$SCRIPT" --host "$URL" --keep x 2>&1); rc=$?
[ "$rc" = 2 ] && ok "--keep x: a usage error" || bad "--keep x: rc $rc"
out=$($TEST_SH "$SCRIPT" 2>&1); rc=$?
[ "$rc" = 2 ] && echo "$out" | grep -q '^Usage:' && ok "no host: the usage, exit 2" || bad "no host: rc $rc"
out=$($TEST_SH "$SCRIPT" --version); [ "$out" = "occulite-backup 1.0.0" ] && ok "--version" || bad "--version: $out"
fresh
: >"$T/empty"
out=$($TEST_SH "$SCRIPT" --host "$URL" --token-file "$T/empty" --ca "$T/cert.pem" --target "$T/target" 2>&1); rc=$?
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
printf 'good.ccu-a\n' >"$T/tok-a"; printf 'e500.ccu-b\n' >"$T/tok-b"; printf 'enc.ccu-c\n' >"$T/tok-c"
cat >"$T/systems.conf" <<CONF
# two systems and an encrypted one
name=ccu-a host=$URL token_file=$T/tok-a ca=$T/cert.pem target=$T/target/a keep=3
name=ccu-b host=$URL token_file=$T/tok-b ca=$T/cert.pem target=$T/target/b   # fails: HTTP 500

  name=ccu-c host=$URL token_file=$T/tok-c insecure=yes target=$T/target/b
CONF
out=$($TEST_SH "$SCRIPT" --config "$T/systems.conf" 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q '^ok   ccu-a: ' && echo "$out" | grep -q '^FAIL ccu-b: HTTP 500' \
  && echo "$out" | grep -q '^ok   ccu-c: ' && echo "$out" | grep -q '^2 of 3 backups downloaded and checked$' \
  && [ "$(find "$T/target/a" -name '*.sbk' | wc -l | tr -d ' ')" = 1 ] && [ "$(find "$T/target/b" -name '*.sbk.age' | wc -l | tr -d ' ')" = 1 ] \
  && ok "a config with three systems: two saved, one failed, exit 1, the summary" || bad "config: rc $rc, $out"
sed -i.bak '/ccu-b/d' "$T/systems.conf"
out=$($TEST_SH "$SCRIPT" --config "$T/systems.conf" 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q '^2 of 2 backups' && ok "every system saved: exit 0" || bad "config ok: rc $rc, $out"
printf 'name=x host=%s colour=blue\n' "$URL" >"$T/bad.conf"
out=$($TEST_SH "$SCRIPT" --config "$T/bad.conf" 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "unknown setting 'colour=blue'" && ok "an unknown setting fails that line" || bad "bad config: rc $rc, $out"
printf '# nothing\n\n' >"$T/none.conf"
out=$($TEST_SH "$SCRIPT" --config "$T/none.conf" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "a config without systems: a usage error" || bad "empty config: rc $rc, $out"

# --- the token never reaches curl's command line
REAL_CURL=$(command -v curl)
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/argv"\nexec "%s" "$@"\n' "$T" "$REAL_CURL" >"$T/curl"
chmod 755 "$T/curl"
mkdir -p "$T/bin"; mv "$T/curl" "$T/bin/curl"
fresh
printf 'good.secret-host\n' >"$T/token"
PATH="$T/bin:$PATH" $TEST_SH "$SCRIPT" --host "$URL" --token-file "$T/token" --ca "$T/cert.pem" --target "$T/target" >/dev/null 2>&1
[ -s "$T/argv" ] && ! grep -q 'good.secret-host' "$T/argv" && ok "the token is not on curl's command line" || bad "argv: $(cat "$T/argv" 2>/dev/null)"

if [ "$fails" = 0 ]; then echo "occulite-backup tests ($TEST_SH): all passed"; else echo "occulite-backup tests ($TEST_SH): $fails failed"; exit 1; fi
