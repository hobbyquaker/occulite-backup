#!/usr/bin/env python3
"""A stand-in for openccu-lite's GET /api/system/v1/backup, for the tests (tests/run.sh).

HTTPS on 127.0.0.1 with the certificate given; the token picks what it answers:

  good.<host>     200, a real .sbk (a tar around usr_local.tar.gz), Content-Length, <host>-3.89.11.20260919-<date>-<time>.sbk
  enc.<host>      200, an .sbk.age (age header), no Content-Length (as the system streams it)
  trunc.<host>    200 with a Content-Length larger than what follows, then the connection closes
  corrupt.<host>  200, a .sbk that is not a tar
  notccu.<host>   200, a tar without usr_local.tar.gz
  noname.<host>   200, a good .sbk but no Content-Disposition
  e500.<host>     500
  noscope.<host>  403
  anything else   401
Every answer's backup name carries a minute that counts up per request, so names differ.
"""
import io
import ssl
import sys
import tarfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

counter = {"n": 0}
lock = threading.Lock()


def sbk(host):
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

    def do_GET(self):
        if self.path != "/api/system/v1/backup":
            return self.send(404, b'{"error":"not_found"}')
        auth = self.headers.get("Authorization", "")
        token = auth[len("Bearer "):] if auth.startswith("Bearer ") else ""
        mode, _, host = token.partition(".")
        host = host or "ccu"
        with lock:
            counter["n"] += 1
            n = counter["n"]
        name = f"{host}-3.89.11.20260919-2026-10-20-{n:04d}.sbk"
        disp = {"Content-Type": "application/octet-stream", "Content-Disposition": f'attachment; filename="{name}"'}
        if mode == "good":
            return self.send(200, sbk(host), disp)
        if mode == "noname":
            return self.send(200, sbk(host), {"Content-Type": "application/octet-stream"})
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
            body = sbk(host)
            self.send_response(200)
            for k, v in disp.items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body) * 4))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            self.close_connection = True
            return
        if mode == "e500":
            return self.send(500, b'{"error":"backup","message":"createBackup.sh failed"}')
        if mode == "noscope":
            return self.send(403, b'{"error":"forbidden","message":"this needs the backup scope"}')
        return self.send(401, b'{"error":"unauthorized"}')


def main():
    port, cert, key, portfile = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    with open(portfile, "w") as f:
        f.write(str(srv.server_address[1]))
    srv.serve_forever()


if __name__ == "__main__":
    main()
