#!/usr/bin/env python3
"""A stand-in for openccu-lite's backup API, for the tests (tests/run.sh).

HTTPS on 127.0.0.1 with the certificate given. It answers

  POST   /api/system/v1/backup/prepare        a backup job (202 new, 200 joined), 409 backup-busy
  GET    /api/system/v1/backup/prepare/{id}   the job: running, ready, failed (error), downloaded
  DELETE /api/system/v1/backup/prepare/{id}   204, the job cancelled
  GET    /api/system/v1/backup?prepared={id}  the prepared file (409 running, 410 gone, 404 unknown)
  GET    /api/system/v1/backup                the file at once (a system before 1.0.0-beta.12)

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
Every answer's backup name carries a minute that counts up per request, so names differ.
"""
import io
import json
import ssl
import sys
import tarfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

P = "/api/system/v1/backup"
lock = threading.Lock()
state = {"n": 0, "jobs": {}, "busy": set(), "events": None}


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

    def do_POST(self):
        url = urlsplit(self.path)
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
