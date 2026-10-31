#!/usr/bin/env python3
"""A stand-in for openccu-lite's backup API, for the tests (tests/run.sh).

HTTPS on 127.0.0.1 with the certificate given. It answers

  POST   /api/system/v1/backup/prepare        a backup job (202 new, 200 joined), 409 backup-busy
  GET    /api/system/v1/backup/prepare/{id}   the job: running, ready, failed (error), downloaded
  DELETE /api/system/v1/backup/prepare/{id}   204, the job cancelled
  GET    /api/system/v1/backup?prepared={id}  the prepared file (409 running, 410 gone, 404 unknown)
  GET    /api/system/v1/backup                the file at once (a system before 1.0.0-beta.12)
  POST   /api/auth/v1/pairing/request         client pairing: the request (see below)
  GET    /api/auth/v1/pairing/request/{id}    its poll, Authorization: Pairing <poll>
  DELETE /api/auth/v1/pairing/request/{id}    withdrawn, 204

and writes every request as "<METHOD> <path> <token mode>" to the events file. The token picks
what it answers:

  good.<host>     200, a real .sbk (a tar around usr_local.tar.gz), Content-Length,
                  <host>-3.89.11.20260919-<date>-<time>.sbk; the job is ready at the first poll
  enc.<host>      an .sbk.age (age header), chunked without Content-Length (as the system streams it)
  trunc.<host>    a Content-Length larger than what follows, then the connection closes
  corrupt.<host>  a .sbk that is not a tar
  notccu.<host>   a tar without usr_local.tar.gz
  noname.<host>   a good .sbk but no Content-Disposition
  wait.<host>     a good .sbk; the job runs for three polls first
  legacy.<host>   no prepare (404, a system before beta.12); GET /backup gives a good .sbk
  busy.<host>     the first prepare is 409 backup-busy, the next one starts the job
  stuck.<host>    every prepare is 409 backup-busy
  slow.<host>     the job never gets ready (the script gives up and cancels it)
  joined.<host>   prepare answers 200 with a job somebody else started, which never gets ready
  jobfail.<host>  the job fails (createBackup.sh)
  expired.<host>  the job fails with "expired" (nobody fetched it within 30 minutes)
  gone.<host>     the job is ready, the download answers 410 backup-gone
  blip.<host>     two polls answer 503, then the job is ready
  forgot.<host>   a poll answers 404 unknown-backup (the system restarted)
  e500.<host>     500 for prepare and for GET /backup
  noscope.<host>  403
  anything else   401
The pairing request's instance picks what the pairing answers; the code the system would show goes to
the events file as "PAIRCODE <code>":

  approve    approved at the second poll, with the token good.paired-host
  now        approved at the first poll
  slowdown   the first poll is 429 slow_down, then approved
  blip       two polls answer 503, then approved
  reject     rejected        expire    expired     gone      404 at the first poll
  wait       pending for ever (a poll takes a second)
  badtoken   approved, with a token that holds a blank
  off        403 pairing-off     notlocal  403 not-local    limit  429 limit
  old        422 (a system whose pairing has no backup area)        none   404
  proxy      answers the fingerprint of another certificate
Every answer's backup name carries a minute that counts up per request, so names differ.
"""
import hashlib
import io
import json
import ssl
import sys
import tarfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

P = "/api/system/v1/backup"
lock = threading.Lock()
state = {"n": 0, "jobs": {}, "busy": set(), "events": None, "cert": b"", "pairs": {}}
PAIR = "/api/auth/v1/pairing/request"
# the system's half of the code, with the bytes a shell loses most easily: NUL, newline, %, backslash, quotes
PAIR_NONCE = "00ff0a0d25275c22000102030405060a"


def sbk():
    buf = io.BytesIO()
    # as createBackup.sh makes it: a plain tar (not compressed) around usr_local.tar.gz and the rest
    with tarfile.open(fileobj=buf, mode="w") as t:
        for name, data in (("usr_local.tar.gz", b"x" * 4096), ("signature", b"sig"), ("signature.sha256", b"sum"),
                           ("key_index", b"0"), ("firmware_version", b"VERSION=3.89.11.20260919\n")):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))
    return buf.getvalue()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send(self, code, body=b"", headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, code, obj):
        self.send(code, json.dumps(obj, separators=(",", ":")).encode(), {"Content-Type": "application/json"})

    def auth(self):
        """The token's mode and host, or None after answering 401/403."""
        a = self.headers.get("Authorization", "")
        token = a[len("Bearer "):] if a.startswith("Bearer ") else ""
        mode, _, host = token.partition(".")
        with lock:
            with open(state["events"], "a") as f:
                f.write(f"{self.command} {urlsplit(self.path).path} {mode or '-'}\n")
        if mode == "noscope":
            self.send_json(403, {"error": "forbidden", "message": "this needs the backup scope"})
            return None
        if mode not in MODES:
            self.send_json(401, {"error": "unauthorized"})
            return None
        return mode, host or "ccu"

    def event(self, text):
        with lock:
            with open(state["events"], "a") as f:
                f.write(text + "\n")

    def pair_ask(self):
        ask = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        mode = ask.get("instance", "")
        self.event(f"POST {PAIR} {mode} {self.headers.get('Content-Type')}")
        refuse = {"off": (403, "pairing-off"), "notlocal": (403, "not-local"), "limit": (429, "limit"),
                  "old": (422, "invalid"), "none": (404, "not_found")}.get(mode)
        if refuse:
            head = {"Retry-After": "60"} if refuse[0] == 429 else {}
            return self.send(refuse[0], json.dumps({"error": refuse[1], "message": "the stub says no"}).encode(), head)
        if ask.get("app") != "occulite-backup" or ask.get("access") != {"backup": "download"} or len(ask.get("commit", "")) != 64:
            return self.send_json(422, {"error": "invalid", "message": "a wrong ask"})
        with lock:
            state["n"] += 1
            rid = "%016x" % state["n"]
            state["pairs"][rid] = {"mode": mode, "commit": ask["commit"], "polls": 0, "revealed": False}
        fp = hashlib.sha256(state["cert"]).hexdigest()
        self.send_json(202, {"id": rid, "poll": "poll-" + rid, "nonce": PAIR_NONCE, "expires_in": 300, "interval": 2,
                             "fingerprint": "ab" * 32 if mode == "proxy" else fp})

    def pair_poll(self, rid, q):
        with lock:
            r = state["pairs"].get(rid)
        if r is None:
            return self.send_json(404, {"error": "not_found"})
        self.event(f"GET {PAIR}/{{id}} {r['mode']}")
        if self.headers.get("Authorization") != "Pairing poll-" + rid:
            return self.send_json(403, {"error": "forbidden"})
        cn = q.get("client_nonce", [""])[0]
        if not r["revealed"]:
            if len(cn) < 32 or hashlib.sha256(bytes.fromhex(cn)).hexdigest() != r["commit"]:
                return self.send_json(422, {"error": "invalid", "message": "client_nonce does not match the commitment"})
            r["revealed"] = True
            d = hashlib.sha256(bytes.fromhex(PAIR_NONCE) + bytes.fromhex(cn) + hashlib.sha256(state["cert"]).digest()).digest()
            self.event("PAIRCODE %06d" % (int.from_bytes(d[:4], "big") % 1000000))
        r["polls"] += 1
        mode, n = r["mode"], r["polls"]
        ok = {"state": "approved", "token": "good.paired-host", "name": "occulite-backup-" + mode, "scopes": ["backup"],
              "access": {"backup": "download"}, "ips": ["127.0.0.1/32"]}
        if mode == "wait" or (mode == "approve" and n < 2):
            time.sleep(1 if mode == "wait" else 0)
            return self.send_json(200, {"state": "pending"})
        if mode == "slowdown" and n == 1:
            return self.send(429, b'{"error":"slow_down"}', {"Retry-After": "1"})
        if mode == "blip" and n <= 2:
            return self.send_json(503, {"error": "unavailable"})
        if mode in ("reject", "expire"):
            return self.send_json(200, {"state": {"reject": "rejected", "expire": "expired"}[mode]})
        if mode == "gone":
            return self.send_json(404, {"error": "not_found"})
        if mode == "badtoken":
            ok["token"] = "not a token"
        return self.send_json(200, ok)

    def do_POST(self):
        url = urlsplit(self.path)
        if url.path == PAIR:
            return self.pair_ask()
        if url.path != P + "/prepare":
            return self.send_json(404, {"error": "not_found"})
        who = self.auth()
        if who is None:
            return
        mode, host = who
        if mode == "legacy":
            return self.send_json(404, {"error": "not_found"})
        if mode == "e500":
            return self.send_json(500, {"error": "internal", "message": "boom"})
        with lock:
            if mode == "stuck" or (mode == "busy" and host not in state["busy"]):
                state["busy"].add(host)
                return self.send_json(409, {"error": "backup-busy", "message": "a cancelled backup is still finishing"})
            state["n"] += 1
            jid = "%032x" % (0xabc000 + state["n"])
            job = {"id": jid, "state": "running", "started": "2026-10-21T10:00:00Z", "mode": mode, "host": host, "polls": 0}
            state["jobs"][jid] = job
        return self.send_json(200 if mode == "joined" else 202, public(job))

    def do_DELETE(self):
        url = urlsplit(self.path)
        if url.path.startswith(PAIR + "/"):
            with lock:
                r = state["pairs"].pop(url.path.rsplit("/", 1)[1], None)
            self.event(f"DELETE {PAIR}/{{id}} {r['mode'] if r else '-'}")
            self.send_response(204)
            self.end_headers()
            return
        if not url.path.startswith(P + "/prepare/"):
            return self.send_json(404, {"error": "not_found"})
        if self.auth() is None:
            return
        with lock:
            job = state["jobs"].get(url.path.rsplit("/", 1)[1])
            if job is None:
                return self.send_json(404, {"error": "unknown-backup"})
            if job["state"] in ("running", "ready"):
                job["state"], job["error"] = "failed", "cancelled"
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path.startswith(PAIR + "/"):
            return self.pair_poll(url.path.rsplit("/", 1)[1], parse_qs(url.query))
        if url.path.startswith(P + "/prepare/"):
            return self.poll(url.path.rsplit("/", 1)[1])
        if url.path != P:
            return self.send_json(404, {"error": "not_found"})
        who = self.auth()
        if who is None:
            return
        mode, host = who
        prepared = parse_qs(url.query).get("prepared", [None])[0]
        if prepared is not None:
            with lock:
                job = state["jobs"].get(prepared)
                if job is None:
                    return self.send_json(404, {"error": "unknown-backup"})
                if job["state"] == "running":
                    return self.send_json(409, {"error": "backup-running"})
                if job["state"] != "ready" or job["mode"] == "gone":
                    return self.send_json(410, {"error": "backup-gone"})
                job["state"] = "downloaded"
                mode, host = job["mode"], job["host"]
        elif mode == "e500":
            return self.send_json(500, {"error": "backup", "message": "createBackup.sh failed"})
        self.backup(mode, host)

    def poll(self, jid):
        if self.auth() is None:
            return
        with lock:
            job = state["jobs"].get(jid)
            if job is None:
                return self.send_json(404, {"error": "unknown-backup"})
            job["polls"] += 1
            m, p = job["mode"], job["polls"]
            if m == "forgot":
                return self.send_json(404, {"error": "unknown-backup"})
            if m == "blip" and p <= 2:
                return self.send_json(503, {"error": "unavailable"})
            if job["state"] == "running":
                if m == "jobfail":
                    job["state"], job["error"] = "failed", "createBackup.sh: exit status 1"
                elif m == "expired":
                    job["state"], job["error"] = "failed", "expired"
                elif m in ("slow", "joined") or (m == "wait" and p < 3):
                    pass
                else:
                    job["state"], job["size"] = "ready", 10240
            return self.send_json(200, public(job))

    def backup(self, mode, host):
        with lock:
            state["n"] += 1
            n = state["n"]
        name = f"{host}-3.89.11.20260919-2026-10-20-{n:04d}.sbk"
        disp = {"Content-Type": "application/octet-stream", "Content-Disposition": f'attachment; filename="{name}"'}
        if mode == "noname":
            return self.send(200, sbk(), {"Content-Type": "application/octet-stream"})
        if mode == "notccu":
            buf = io.BytesIO()
            with tarfile.open(fileobj=buf, mode="w") as t:
                info = tarfile.TarInfo("hello.txt")
                info.size = 2
                t.addfile(info, io.BytesIO(b"hi"))
            return self.send(200, buf.getvalue(), disp)
        if mode == "corrupt":
            return self.send(200, b"this is not a backup\n" * 20, disp)
        if mode == "enc":
            # streamed as the system does it: chunked, no Content-Length
            disp["Content-Disposition"] = f'attachment; filename="{name}.age"'
            body = b"age-encryption.org/v1\n-> X25519 abc\n" + b"\x00" * 512
            self.send_response(200)
            for k, v in disp.items():
                self.send_header(k, v)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i in range(0, len(body), 100):
                c = body[i:i + 100]
                self.wfile.write(b"%x\r\n" % len(c) + c + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
            return
        if mode == "trunc":
            body = sbk()
            self.send_response(200)
            for k, v in disp.items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body) * 4))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            self.close_connection = True
            return
        return self.send(200, sbk(), disp)


MODES = {"good", "enc", "trunc", "corrupt", "notccu", "noname", "wait", "legacy", "busy", "stuck", "slow",
         "joined", "jobfail", "expired", "gone", "blip", "forgot", "e500"}


def public(job):
    return {k: v for k, v in job.items() if k in ("id", "state", "started", "finished", "size", "error")}


def main():
    port, cert, key, portfile, events = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
    state["events"] = events
    with open(cert) as f:
        state["cert"] = ssl.PEM_cert_to_DER_cert(f.read())
    open(events, "w").close()
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.daemon_threads = True
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    with open(portfile, "w") as f:
        f.write(str(srv.server_address[1]))
    srv.serve_forever()


if __name__ == "__main__":
    main()
