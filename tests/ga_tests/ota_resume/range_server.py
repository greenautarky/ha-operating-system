#!/usr/bin/env python3
"""HTTPS file server with HTTP Range, ETag/If-Range and fault injection.

Test fixture for tests/ga_tests/ota_resume (Odoo #2136). It plays the OTA store
for the REAL curl inside ga-rauc-install: the store answers 206 + ETag to a
Range request; this server does the same, and can be told to misbehave.

    range_server.py --addr A --port P --root DIR --cert C --key K \
                    --control CONTROL.json --log LOG.jsonl --ready READYFILE

CONTROL.json is re-read on every request (a missing file = no faults):
    {"cut_after": N, "cut_count": K}     send N body bytes, then drop the
                                         connection; for the next K responses
    {"stall_after": N, "stall_s": S,     send N body bytes, then go silent
     "stall_count": K}                   for S seconds, then drop
    {"missing": ["substr", ...]}         404 for paths containing a substr
    {"error": [[code, "substr"], ...]}   that HTTP code for paths containing substr
    {"refuse": ["substr", ...]}          drop the connection without an answer
    {"no_ranges": true}                  ignore Range (always 200, full file)
    {"etag_suffix_after": N}             after N bundle requests the ETag of
                                         every file changes (a re-publish of
                                         the same bytes)
    {"write_file": {"path": P, "content": C, "after_requests": N}}
                                         write a file once N bundle requests
                                         were answered (used to drop a new
                                         request into ga_manager's directory)

LOG.jsonl gets one line per response: path, range, if_range, status, sent
(body bytes actually written), cut. The suite adds up "sent" to measure the
bytes on the wire.
"""

from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import os
import re
import socket
import ssl
import threading
import time
from pathlib import Path

CHUNK = 16 * 1024


class State:
    """Counters shared by all handler threads."""

    lock = threading.Lock()
    cut_done = 0
    stall_done = 0
    bundle_requests = 0
    file_written = False


def load_control(path: str) -> dict:
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}


def etag_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return '"' + h.hexdigest()[:24] + '"'


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ga-range-fixture"

    def log_message(self, *_args) -> None:  # quiet
        return

    def _log(self, **rec) -> None:
        rec["path"] = self.path
        rec["ts"] = time.time()
        with State.lock, open(self.server.log_path, "a") as f:
            f.write(json.dumps(rec) + "\n")

    def _plain(self, code: int, extra: dict | None = None) -> None:
        self.send_response(code)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", "0")
        self.end_headers()
        self._log(status=code, sent=0, range=self.headers.get("Range"),
                  if_range=self.headers.get("If-Range"), cut=False)

    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET(head=True)

    def do_GET(self, head: bool = False) -> None:  # noqa: N802
        ctl = load_control(self.server.control_path)
        rel = self.path.split("?", 1)[0].lstrip("/")
        if any(s in self.path for s in ctl.get("refuse", [])):
            self._log(status=0, sent=0, range=None, if_range=None, cut=True)
            self.connection.shutdown(socket.SHUT_RDWR)
            return
        if any(s in self.path for s in ctl.get("missing", [])):
            self._plain(404)
            return
        for code, sub in ctl.get("error", []):
            if sub in self.path:
                self._plain(int(code))
                return
        f = (self.server.root / rel).resolve()
        if self.server.root not in f.parents or not f.is_file():
            self._plain(404)
            return
        size = f.stat().st_size
        etag = etag_of(f)
        after = ctl.get("etag_suffix_after")
        if after is not None and State.bundle_requests >= int(after):
            etag = etag[:-1] + '-republished"'
        start = 0
        status = 200
        rng = self.headers.get("Range")
        if_range = self.headers.get("If-Range")
        if ctl.get("no_ranges"):
            rng = None
        if rng and (if_range is None or if_range == etag):
            m = re.fullmatch(r"bytes=(\d+)-(\d*)", rng.strip())
            if m:
                start = int(m.group(1))
                if start >= size:
                    self._plain(416, {"Content-Range": f"bytes */{size}", "ETag": etag})
                    return
                status = 206
        length = size - start
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", etag)
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{size - 1}/{size}")
        self.end_headers()
        if head:
            self._log(status=status, sent=0, range=rng, if_range=if_range, cut=False)
            return

        is_bundle = rel.endswith(".raucb")
        limit = None
        stall_s = 0
        with State.lock:
            if is_bundle:
                State.bundle_requests += 1
                if State.cut_done < int(ctl.get("cut_count", 0)):
                    State.cut_done += 1
                    limit = int(ctl.get("cut_after", 0))
                elif State.stall_done < int(ctl.get("stall_count", 0)):
                    State.stall_done += 1
                    limit = int(ctl.get("stall_after", 0))
                    stall_s = float(ctl.get("stall_s", 0))
            wf = ctl.get("write_file")
            if (wf and not State.file_written and is_bundle
                    and State.bundle_requests >= int(wf.get("after_requests", 1))):
                State.file_written = True
                p = Path(wf["path"])
                tmp = p.with_name(p.name + ".tmp")
                tmp.write_text(wf["content"])
                os.replace(tmp, p)

        sent = 0
        cut = False
        try:
            with f.open("rb") as fh:
                fh.seek(start)
                while sent < length:
                    want = min(CHUNK, length - sent)
                    if limit is not None:
                        want = min(want, limit - sent)
                        if want <= 0:
                            cut = True
                            break
                    data = fh.read(want)
                    if not data:
                        break
                    self.wfile.write(data)
                    sent += len(data)
            self.wfile.flush()
            if cut and stall_s:
                time.sleep(stall_s)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            cut = True
        self._log(status=status, sent=sent, range=rng, if_range=if_range, cut=cut)
        if cut:
            self.close_connection = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--addr", required=True)
    ap.add_argument("--port", type=int, default=443)
    ap.add_argument("--root", required=True)
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--control", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--ready", required=True)
    a = ap.parse_args()

    srv = http.server.ThreadingHTTPServer((a.addr, a.port), Handler)
    srv.daemon_threads = True
    srv.root = Path(a.root).resolve()
    srv.control_path = a.control
    srv.log_path = a.log
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(a.cert, a.key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    Path(a.ready).write_text("ready\n")
    srv.serve_forever()


if __name__ == "__main__":
    main()
