#!/usr/bin/env python3

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class State:
    def __init__(self, log_path):
        self.counts = {}
        self.lock = threading.Lock()
        self.log_path = log_path

    def record(self, handler):
        with self.lock:
            path = handler.path.split("?", 1)[0]
            count = self.counts.get(path, 0) + 1
            self.counts[path] = count
            entry = {
                "authorization": handler.headers.get("Authorization", ""),
                "count": count,
                "if_none_match": handler.headers.get("If-None-Match", ""),
                "path": path,
            }
            with open(self.log_path, "a", encoding="utf-8") as log_file:
                log_file.write(json.dumps(entry, separators=(",", ":")) + "\n")
            return path, count


class Handler(BaseHTTPRequestHandler):
    server_version = "HypringoRemoteMock/1"

    def log_message(self, _format, *_args):
        return

    def send_json(self, status, value, headers=None):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        path, count = self.server.state.record(self)
        if path == "/weather-redirect":
            self.send_json(
                302,
                {"redirect": "intermediate"},
                {
                    "ETag": '"intermediate"',
                    "Location": "/weather",
                    "Retry-After": "30",
                    "X-Poll-Interval": "30",
                },
            )
            return
        if path == "/weather":
            self.handle_weather(count)
            return
        if path == "/github":
            self.handle_github(count)
            return
        self.send_json(404, {"error": "not found"})

    def handle_weather(self, count):
        if count == 1:
            self.send_json(
                200,
                {
                    "cond": "Sunny",
                    "loc": "Shenzhen",
                    "precip": "0.0mm",
                    "pressure": "1012hPa",
                    "temp": "+30C",
                    "temp_like": "+32C",
                    "wind": "8km/h",
                },
            )
            return
        if count == 2:
            time.sleep(0.2)
            self.send_json(200, {"cond": "too late"})
            return
        if count == 3:
            body = b"x" * 2048
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        self.send_json(
            200,
            {
                "cond": "Cloudy",
                "loc": "Shenzhen",
                "precip": "0.1mm",
                "pressure": "1010hPa",
                "temp": "+28C",
                "temp_like": "+29C",
                "wind": "12km/h",
            },
        )

    def handle_github(self, count):
        if self.headers.get("Authorization") != "Bearer test-token":
            self.send_json(401, {"message": "bad token"})
            return
        if count == 1:
            self.send_json(
                200,
                [
                    {
                        "id": "1",
                        "reason": "mention",
                        "repository": {
                            "full_name": "owner/repo",
                            "html_url": "https://github.com/owner/repo",
                        },
                        "subject": {
                            "title": "First notification",
                            "type": "Issue",
                            "url": "https://api.github.com/repos/owner/repo/issues/1",
                        },
                        "unread": True,
                        "updated_at": "2026-07-27T00:00:00Z",
                    },
                    {
                        "id": "2",
                        "reason": "subscribed",
                        "repository": {
                            "full_name": "owner/repo",
                            "html_url": "https://github.com/owner/repo",
                        },
                        "subject": {
                            "title": "Second notification",
                            "type": "PullRequest",
                        },
                        "unread": True,
                        "updated_at": "2026-07-27T00:01:00Z",
                    },
                ],
                {"ETag": '"v1"'},
            )
            return
        if count == 2 and self.headers.get("If-None-Match") == '"v1"':
            self.send_response(304)
            self.send_header("ETag", '"v1"')
            self.end_headers()
            return
        if count == 3:
            self.send_json(429, {"message": "slow down"}, {"Retry-After": "1"})
            return
        self.send_json(
            200,
            [
                {
                    "id": "3",
                    "reason": "review_requested",
                    "repository": {
                        "full_name": "owner/repo",
                        "html_url": "https://github.com/owner/repo",
                    },
                    "subject": {
                        "title": "Recovered notification",
                        "type": "PullRequest",
                        "url": "https://api.github.com/repos/owner/repo/pulls/3",
                    },
                    "unread": True,
                    "updated_at": "2026-07-27T00:02:00Z",
                }
            ],
            {"ETag": '"v2"'},
        )


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, _request, _client_address):
        return


def main():
    port_path, log_path = sys.argv[1:3]
    server = Server(("127.0.0.1", 0), Handler)
    server.state = State(log_path)
    with open(port_path, "w", encoding="utf-8") as port_file:
        port_file.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
