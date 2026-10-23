"""Loopback-only proxy fixture; unrelated HTTP and CONNECT requests pass through.

No TLS interception, credentials or unrelated request URLs are logged. This is a
device verification tool, not an application dependency or an open proxy.
"""
from __future__ import annotations

from http.client import HTTPConnection, HTTPException
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import select
import socket
import threading
from urllib.parse import urlsplit
import zipfile


FIXTURE_HOST = "site-lens-proxy.invalid"
HTTPS_FIXTURE_HOST = "raw.githubusercontent.com"
HTTPS_PHASES = ('probe', 'dart', 'nativeTls', 'worker', 'hls')
PLAYLIST = (b"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n"
            b"#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n")
HOP_HEADERS = {"connection", "proxy-connection", "proxy-authorization",
               "keep-alive", "transfer-encoding", "upgrade"}


class ProxyFixture:
    def __init__(self, segment: bytes, *, direct_media: bytes | None = None,
                 connector=socket.create_connection):
        self.segment = segment
        self.direct_media = segment if direct_media is None else direct_media
        self.connector = connector
        self.hits: list[str] = []
        self.forwarded_http = 0
        self.forwarded_connect = 0
        self.https_fixture_connect = 0
        self.https_fixture_sent_bytes = 0
        self.https_fixture_received_bytes = 0
        self.https_checkpoints: list[dict] = []
        self._lock = threading.Lock()
        self._connections: set[socket.socket] = set()
        self._slots = threading.BoundedSemaphore(64)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @classmethod
    def from_repository(cls, root: Path):
        with zipfile.ZipFile(root / "integration_test/fixtures/media3_parity.zip") as archive:
            direct_media = b"".join(
                archive.read("h264_fmp4/" + name)
                for name in ("init.mp4", "seg00.m4s", "seg01.m4s")
            )
            return cls(archive.read("h264_ts/seg00.ts"), direct_media=direct_media)

    @property
    def port(self) -> int:
        return self.server.server_port

    def https_checkpoint(self, phase, edge):
        if phase not in HTTPS_PHASES or edge not in ('before', 'after'):
            raise ValueError('invalid HTTPS checkpoint')
        with self._lock:
            record = {
                'phase': phase, 'edge': edge,
                'connects': self.https_fixture_connect,
                'sentBytes': self.https_fixture_sent_bytes,
                'receivedBytes': self.https_fixture_received_bytes,
            }
            self.https_checkpoints.append(record)
            return record.copy()

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.server.shutdown()
        self.server.server_close()
        with self._lock:
            connections = list(self._connections)
        for connection in connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()
        self.thread.join(timeout=2)

    def _handler(self):
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.0"

            def setup(self):
                super().setup()
                self.connection.settimeout(30)

            def log_message(self, *_):
                pass

            def _body(self, status, body=b"", mime="text/plain", **headers):
                self.send_response(status)
                self.send_header("Content-Type", mime)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                for name, value in headers.items():
                    self.send_header(name, value)
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(body)

            def _fixture(self):
                try:
                    target = urlsplit(self.path)
                    port = target.port
                except ValueError:
                    self._body(400)
                    return True
                if target.hostname != FIXTURE_HOST:
                    return False
                if (target.scheme != "http" or port not in (None, 80)
                        or target.username is not None or target.fragment):
                    self._body(400)
                    return True
                with fixture._lock:
                    fixture.hits.append(target.path)
                if target.path == "/redirect":
                    self._body(302, Location="/landing")
                elif target.path == "/landing":
                    self._body(200, b"proxy-contract-landing")
                elif target.path == "/contract.m3u8":
                    self._body(200, PLAYLIST, "application/vnd.apple.mpegurl")
                elif target.path == "/segment.ts":
                    self._body(200, fixture.segment, "video/mp2t")
                elif target.path == "/direct.mp4":
                    # The proxy contract only needs a stable non-HLS payload
                    # to exercise the Android WorkManager/native download
                    # path. The parity fixture bytes are deterministic and
                    # are checked by the device test after the proxy hop.
                    self._body(200, fixture.direct_media, "video/mp4")
                elif target.path.startswith('/https-checkpoint/'):
                    parts = target.path.split('/')
                    try:
                        if len(parts) != 4:
                            raise ValueError('invalid checkpoint path')
                        checkpoint = fixture.https_checkpoint(parts[2], parts[3])
                    except ValueError:
                        self._body(400)
                        return True
                    self._body(200, json.dumps(checkpoint).encode(), 'application/json')
                else:
                    self._body(404)
                return True

            def _send_body(self, upstream):
                if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                    while True:
                        line = self.rfile.readline(8193)
                        if len(line) > 8192 or not line.endswith(b"\r\n"):
                            raise ValueError("invalid chunk")
                        size = int(line.split(b";", 1)[0], 16)
                        if size < 0:
                            raise ValueError("invalid chunk")
                        upstream.send(line)
                        if size == 0:
                            # Forward bounded trailer lines including their terminator.
                            for _ in range(100):
                                trailer = self.rfile.readline(8193)
                                if len(trailer) > 8192 or not trailer.endswith(b"\r\n"):
                                    raise ValueError("invalid trailer")
                                upstream.send(trailer)
                                if trailer == b"\r\n":
                                    return
                            raise ValueError("too many trailers")
                        self._send_exact(upstream, size)
                        terminator = self.rfile.read(2)
                        if terminator != b"\r\n":
                            raise ValueError("invalid chunk terminator")
                        upstream.send(terminator)
                else:
                    length = int(self.headers.get("Content-Length", "0"))
                    if length < 0:
                        raise ValueError("invalid length")
                    self._send_exact(upstream, length)

            def _send_exact(self, upstream, remaining):
                while remaining:
                    data = self.rfile.read(min(remaining, 64 * 1024))
                    if not data:
                        raise OSError("incomplete request")
                    upstream.send(data)
                    remaining -= len(data)

            def _forward(self):
                if self._fixture():
                    return
                target = urlsplit(self.path)
                if (target.scheme != "http" or not target.hostname
                        or target.username is not None or target.fragment):
                    self._body(400)
                    return
                if not fixture._slots.acquire(blocking=False):
                    self._body(503)
                    return
                upstream = HTTPConnection(target.hostname, target.port or 80, timeout=15)
                upstream_socket = None
                response_started = False
                try:
                    upstream.connect()
                    upstream_socket = upstream.sock
                    with fixture._lock:
                        fixture._connections.add(upstream_socket)
                        fixture.forwarded_http += 1
                    path = target.path or "/"
                    if target.query:
                        path += "?" + target.query
                    upstream.putrequest(self.command, path, skip_host=True, skip_accept_encoding=True)
                    for name, value in self.headers.items():
                        if name.lower() not in HOP_HEADERS:
                            upstream.putheader(name, value)
                    if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                        upstream.putheader("Transfer-Encoding", "chunked")
                    upstream.putheader("Connection", "close")
                    upstream.endheaders()
                    if self.headers.get("Expect", "").lower() == "100-continue":
                        # HTTP/1.0 BaseHTTPRequestHandler does not send this.
                        # A waiting upload client must be released before read().
                        self.wfile.write(b"HTTP/1.1 100 Continue\r\n\r\n")
                        self.wfile.flush()
                    self._send_body(upstream)
                    response = upstream.getresponse()
                    self.send_response_only(response.status, response.reason)
                    for name, value in response.getheaders():
                        if name.lower() not in HOP_HEADERS:
                            self.send_header(name, value)
                    self.send_header("Connection", "close")
                    self.end_headers()
                    response_started = True
                    if self.command != "HEAD":
                        while data := response.read(64 * 1024):
                            self.wfile.write(data)
                except (OSError, ValueError, HTTPException):
                    if not response_started:
                        self._body(502)
                finally:
                    with fixture._lock:
                        fixture._connections.discard(upstream_socket)
                    upstream.close()
                    fixture._slots.release()

            def do_CONNECT(self):
                try:
                    target = urlsplit("//" + self.path)
                    port = target.port
                except ValueError:
                    self._body(400)
                    return
                if (not target.hostname or target.username is not None
                        or target.path or target.query or target.fragment
                        or port is None):
                    self._body(400)
                    return
                if not fixture._slots.acquire(blocking=False):
                    self._body(503)
                    return
                upstream = None
                established = False
                try:
                    upstream = fixture.connector((target.hostname, target.port), timeout=15)
                    upstream.settimeout(15)
                    with fixture._lock:
                        fixture._connections.update((self.connection, upstream))
                        fixture.forwarded_connect += 1
                        # Only a count for our fixed public test fixture. Do
                        # not retain unrelated CONNECT destinations or URLs.
                        if target.hostname == HTTPS_FIXTURE_HOST and target.port == 443:
                            fixture.https_fixture_connect += 1
                    self.send_response(200, "Connection Established")
                    self.end_headers()
                    self.wfile.flush()
                    established = True
                    while True:
                        ready, _, _ = select.select((self.connection, upstream), (), (), 30)
                        if not ready:
                            break
                        for source in ready:
                            data = source.recv(64 * 1024)
                            if not data:
                                return
                            destination = upstream if source is self.connection else self.connection
                            if target.hostname == HTTPS_FIXTURE_HOST and target.port == 443:
                                # Count opaque encrypted traffic, including on
                                # a reused tunnel. Never inspect TLS payloads.
                                with fixture._lock:
                                    if source is self.connection:
                                        fixture.https_fixture_sent_bytes += len(data)
                                    else:
                                        fixture.https_fixture_received_bytes += len(data)
                            destination.sendall(data)
                except (OSError, ValueError):
                    if not established:
                        self._body(502)
                finally:
                    with fixture._lock:
                        fixture._connections.discard(self.connection)
                        fixture._connections.discard(upstream)
                    if upstream is not None:
                        upstream.close()
                    fixture._slots.release()

            do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = do_OPTIONS = do_PATCH = _forward

        return Handler
