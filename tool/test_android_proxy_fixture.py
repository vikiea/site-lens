"""Loopback network contracts; no ADB, Internet, or system proxy mutation."""
from __future__ import annotations

from contextlib import contextmanager
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import socket
import socketserver
import threading
import unittest
from unittest.mock import patch

from android_proxy_fixture import FIXTURE_HOST, HTTPS_FIXTURE_HOST, PLAYLIST, ProxyFixture
import run_android_acceptance as acceptance


class Origin(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/chunked":
            self.protocol_version = "HTTP/1.1"
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n")
        else:
            self.send_response(404 if self.path == "/missing" else 200)
            self.send_header("Content-Length", "6")
            self.end_headers()
            self.wfile.write(b"origin")

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", "6")
        self.end_headers()

    def do_POST(self):
        if self.headers.get("Transfer-Encoding") == "chunked":
            parts = []
            while size := int(self.rfile.readline().strip(), 16):
                parts.append(self.rfile.read(size))
                assert self.rfile.read(2) == b"\r\n"
            assert self.rfile.read(2) == b"\r\n"
            body = b"".join(parts)
        else:
            body = self.rfile.read(int(self.headers["Content-Length"]))
        leaked = self.headers.get("Proxy-Authorization")
        if leaked:
            body = b"leaked proxy auth"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@contextmanager
def origin():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_port
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


class ProxyTests(unittest.TestCase):
    def request(self, proxy, method, url, body=None, headers=None, **kwargs):
        connection = HTTPConnection("127.0.0.1", proxy.port, timeout=3)
        try:
            connection.request(method, url, body, headers or {}, **kwargs)
            response = connection.getresponse()
            return response.status, response.read(), response.getheaders()
        finally:
            connection.close()

    def test_fixture_redirect_playlist_and_segment_are_exact(self):
        with ProxyFixture(b"segment") as proxy:
            status, _, headers = self.request(proxy, "GET", f"http://{FIXTURE_HOST}/redirect")
            self.assertEqual(status, 302)
            self.assertIn(("Location", "/landing"), headers)
            self.assertEqual(self.request(proxy, "GET", f"http://{FIXTURE_HOST}/contract.m3u8")[1], PLAYLIST)
            self.assertEqual(self.request(proxy, "GET", f"http://{FIXTURE_HOST}/segment.ts")[1], b"segment")
            self.assertEqual(proxy.hits, ["/redirect", "/contract.m3u8", "/segment.ts"])
            self.assertEqual(proxy.forwarded_http, 0)

    def test_fixture_direct_media_payload_is_stable(self):
        with ProxyFixture(b"direct-media") as proxy:
            status, body, headers = self.request(proxy, "GET", f"http://{FIXTURE_HOST}/direct.mp4")
            self.assertEqual(status, 200)
            self.assertEqual(body, b"direct-media")
            self.assertIn(("Content-Type", "video/mp4"), headers)
            self.assertEqual(proxy.hits, ["/direct.mp4"])

    def test_https_checkpoint_has_only_fixed_target_counters_and_closed_phase_names(self):
        with ProxyFixture(b'segment') as proxy:
            status, body, _ = self.request(proxy, 'GET', f'http://{FIXTURE_HOST}/https-checkpoint/probe/before')
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body), {
                'phase': 'probe', 'edge': 'before', 'connects': 0,
                'sentBytes': 0, 'receivedBytes': 0,
            })
            for path in ('/https-checkpoint/unrelated/before', '/https-checkpoint/probe/later',
                         '/https-checkpoint/probe/before/extra'):
                self.assertEqual(self.request(proxy, 'GET', f'http://{FIXTURE_HOST}{path}')[0], 400)
            self.assertEqual(len(proxy.https_checkpoints), 1)

    def test_unrelated_http_head_missing_and_chunked_responses_are_forwarded(self):
        with origin() as port, ProxyFixture(b"segment") as proxy:
            base = f"http://127.0.0.1:{port}"
            self.assertEqual(self.request(proxy, "GET", base + "/normal")[:2], (200, b"origin"))
            self.assertEqual(self.request(proxy, "HEAD", base + "/normal")[:2], (200, b""))
            self.assertEqual(self.request(proxy, "GET", base + "/missing")[:2], (404, b"origin"))
            self.assertEqual(self.request(proxy, "GET", base + "/chunked")[:2], (200, b"abcdefg"))
            self.assertEqual(proxy.hits, [])
            self.assertEqual(proxy.forwarded_http, 4)
            self.assertEqual(proxy._connections, set())

    def test_post_streams_content_and_chunked_upload_without_proxy_credentials(self):
        with origin() as port, ProxyFixture(b"segment") as proxy:
            url = f"http://127.0.0.1:{port}/private-path"
            body = bytes(range(256)) * 700
            headers = {"Proxy-Authorization": "Basic private", "Authorization": "Bearer origin"}
            self.assertEqual(self.request(proxy, "POST", url, body, headers)[:2], (200, body))
            self.assertEqual(self.request(proxy, "POST", url, iter([b"abc", b"def"]),
                                          headers, encode_chunked=True)[:2], (200, b"abcdef"))
            self.assertEqual(proxy.hits, [])

    def test_connect_is_an_opaque_binary_tunnel(self):
        class Echo(socketserver.BaseRequestHandler):
            def handle(self):
                while data := self.request.recv(8192):
                    self.request.sendall(data)

        with socketserver.ThreadingTCPServer(("127.0.0.1", 0), Echo) as echo:
            echo.daemon_threads = True
            thread = threading.Thread(target=echo.serve_forever, daemon=True)
            thread.start()
            try:
                def connect_local(destination, timeout):
                    return socket.create_connection(echo.server_address, timeout=timeout)

                with ProxyFixture(b"segment", connector=connect_local) as proxy:
                    for index, (host, port) in enumerate((
                        ("unrelated.invalid", 443), (HTTPS_FIXTURE_HOST, 8443),
                        (HTTPS_FIXTURE_HOST, 443),
                    )):
                        connection = HTTPConnection("127.0.0.1", proxy.port, timeout=3)
                        connection.set_tunnel(host, port)
                        connection.connect()
                        try:
                            before = proxy.https_checkpoint('nativeTls', 'before')
                            data = bytes(range(256)) * 512
                            connection.sock.sendall(data)
                            received = bytearray()
                            while len(received) < len(data):
                                received.extend(connection.sock.recv(8192))
                            self.assertEqual(bytes(received), data)
                            self.assertEqual(proxy.forwarded_connect, index + 1)
                            self.assertEqual(proxy.https_fixture_connect, 1 if index == 2 else 0)
                            after = proxy.https_checkpoint('nativeTls', 'after')
                            delta = len(data) if index == 2 else 0
                            self.assertEqual(after['sentBytes'] - before['sentBytes'], delta)
                            self.assertEqual(after['receivedBytes'] - before['receivedBytes'], delta)
                            self.assertEqual(proxy.hits, [])
                        finally:
                            connection.close()
            finally:
                echo.shutdown()
                thread.join(timeout=2)

    def test_expect_continue_client_is_released_before_upload(self):
        with origin() as port, ProxyFixture(b"segment") as proxy:
            with socket.create_connection(("127.0.0.1", proxy.port), timeout=3) as client:
                client.sendall((f"POST http://127.0.0.1:{port}/upload HTTP/1.1\r\n"
                                f"Host: 127.0.0.1:{port}\r\nContent-Length: 7\r\n"
                                "Expect: 100-continue\r\n\r\n").encode())
                reader = client.makefile("rb")
                self.assertEqual(reader.readline(), b"HTTP/1.1 100 Continue\r\n")
                self.assertEqual(reader.readline(), b"\r\n")
                client.sendall(b"payload")
                self.assertIn(b"200", reader.readline())
                while reader.readline() != b"\r\n":
                    pass
                self.assertEqual(reader.read(7), b"payload")
                reader.close()

    def test_failed_connect_never_claims_a_tunnel(self):
        def unavailable(*_, **__):
            raise OSError("unavailable")

        with ProxyFixture(b"segment", connector=unavailable) as proxy:
            result = self.request(proxy, "CONNECT", f"{HTTPS_FIXTURE_HOST}:443")
            self.assertEqual(result[0], 502)
            self.assertEqual(proxy.forwarded_connect, 0)
            self.assertEqual(proxy.https_fixture_connect, 0)

    def test_invalid_absolute_urls_and_connect_ports_are_rejected(self):
        with ProxyFixture(b"segment") as proxy:
            for method, url in [("GET", "http://host:invalid/"),
                                ("GET", "/relative"),
                                ("CONNECT", "host:invalid"),
                                ("CONNECT", "host:70000"),
                                ("CONNECT", "user:secret@host:443")]:
                with self.subTest(method=method, url=url):
                    self.assertEqual(self.request(proxy, method, url)[0], 400)


class EndpointGuardTests(unittest.TestCase):
    def test_unavailable_endpoint_never_recovers_when_disabled(self):
        with patch.object(acceptance, "device_online", return_value=False), \
                patch.object(acceptance, "restart_adb_server") as restart:
            with self.assertRaises(SystemExit):
                acceptance.require_device("192.0.2.1:5555", allow_recovery=False)
            restart.assert_not_called()


if __name__ == "__main__":
    unittest.main()
