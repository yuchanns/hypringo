#!/usr/bin/env python3
"""Exercise late gh login, timeouts, caching and token rotation in a real daemon."""

import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time


binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else "build/bin/hypringo").resolve())
accepted_token = "fixture-token-one"
weather_requests = 0
github_requests = 0


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global weather_requests, github_requests
        status = 200
        if self.path == "/weather":
            weather_requests += 1
            data = {
                "cond": "Sunny", "temp": "20", "loc": "Test",
                "temp_like": "20", "wind": "0", "pressure": "1000", "precip": "0",
            }
        else:
            github_requests += 1
            status = 200 if self.headers.get("Authorization") == "Bearer " + accepted_token else 401
            data = [] if status == 200 else {"message": "Bad credentials"}
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


with tempfile.TemporaryDirectory(prefix="hypringo-auth-") as directory:
    root = Path(directory)
    gh = root / "gh"
    mode = root / "mode"
    calls = root / "calls"
    config = root / "config.lua"
    socket = root / "control.sock"
    log_path = root / "daemon.log"
    mode.write_text("locked")
    gh.write_text("""#!/usr/bin/env python3
import os
from pathlib import Path
import sys
import time
root = Path(os.environ['AUTH_FIXTURE'])
assert sys.argv[1:] == ['auth', 'token', '--hostname', 'github.com']
with (root / 'calls').open('a') as out:
    out.write('called\\n')
mode = (root / 'mode').read_text()
if mode == 'locked':
    sys.exit(1)
if mode == 'hung':
    time.sleep(30)
    sys.exit(1)
if mode == 'partial-failure':
    print('fixture-token-one')
    sys.exit(1)
print(mode)
""")
    gh.chmod(0o755)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]

    def write_config(gh_auth="true"):
        config.write_text(f"""return {{
  runtime = {{ workers = 3, socket_path = "{socket}" }},
  session = {{ enabled = false }},
  sources = {{
    github = {{ enabled = true, gh_auth = {gh_auth},
      token_env = "HYPRINGO_AUTH_TEST_TOKEN", interval_ms = 100,
      retry_min_ms = 100, retry_max_ms = 400,
      url = "http://127.0.0.1:{port}/github" }},
    weather = {{ enabled = true, interval_ms = 100,
      url = "http://127.0.0.1:{port}/weather" }}
  }}
}}
""")

    env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"], AUTH_FIXTURE=str(root))
    env.pop("HYPRINGO_AUTH_TEST_TOKEN", None)
    write_config('"invalid"')
    check = subprocess.run([binary, "--config", str(config), "--check-config"], env=env, capture_output=True)
    assert check.returncode != 0 and b"gh_auth must be a boolean" in check.stderr
    write_config()

    def call_count():
        return len(calls.read_text().splitlines()) if calls.exists() else 0

    with log_path.open("w") as log:
        daemon = subprocess.Popen([binary, "--config", str(config)], env=env, stdout=log, stderr=log)

        def wait_for(predicate, timeout=10):
            deadline = time.monotonic() + timeout
            snapshot = None
            while time.monotonic() < deadline:
                assert daemon.poll() is None, log_path.read_text()
                result = subprocess.run([binary, "status", "--socket", str(socket)], capture_output=True, timeout=2)
                if result.returncode == 0:
                    snapshot = json.loads(result.stdout)["state"]
                    assert "fixture-token" not in result.stdout.decode()
                    if predicate(snapshot):
                        return snapshot
                time.sleep(0.02)
            raise AssertionError(f"state timeout: {snapshot}\n{log_path.read_text()}")

        try:
            waiting = wait_for(lambda s: s["github"]["failures"] >= 3 and s["weather"]["available"])
            assert waiting["runtime"]["ready"] and not waiting["github"]["available"]
            assert waiting["github"]["refresh_in_ms"] == 100
            assert github_requests == 0

            # A process that prints a token but exits unsuccessfully is not authenticated.
            mode.write_text("partial-failure")
            attempts = call_count()
            wait_for(lambda s: call_count() >= attempts + 2)
            assert github_requests == 0

            # A stalled keyring must not stall control or weather. It times out,
            # then the next lookup sees the newly available credential.
            mode.write_text("hung")
            attempts = call_count()
            wait_for(lambda s: call_count() > attempts)
            weather_before = weather_requests
            wait_for(lambda s: weather_requests >= weather_before + 3)
            mode.write_text(accepted_token)
            wait_for(lambda s: s["github"]["available"] and s["github"]["failures"] == 0, timeout=8)
            print("late login and hung-keyring recovery passed; other sources stayed live")

            attempts = call_count()
            requests = github_requests
            wait_for(lambda s: github_requests >= requests + 3)
            assert call_count() == attempts, "successful credentials should be cached"

            # Reject the old credential and simulate a new login without restarting.
            accepted_token = "fixture-token-two"
            mode.write_text(accepted_token)
            wait_for(lambda s: call_count() > attempts and s["github"]["failures"] == 0)
            assert daemon.poll() is None
            print("credential caching and HTTP 401 recovery passed without a daemon restart")

            # Environment credentials still override gh; disabling gh on reload
            # must discard its cache and leave the source unavailable.
            write_config("false")
            subprocess.run([binary, "reload", "--socket", str(socket)], check=True, capture_output=True)
            wait_for(lambda s: "HYPRINGO_AUTH_TEST_TOKEN" in s["github"]["error"])
        finally:
            daemon.terminate()
            daemon.wait(timeout=8)

    # A separate daemon exercises explicit environment precedence.
    write_config()
    attempts = call_count()
    env["HYPRINGO_AUTH_TEST_TOKEN"] = accepted_token
    with log_path.open("a") as log:
        daemon = subprocess.Popen([binary, "--config", str(config)], env=env, stdout=log, stderr=log)
        try:
            wait_for(lambda s: s["github"]["available"])
            assert call_count() == attempts
        finally:
            daemon.terminate()
            daemon.wait(timeout=8)
    server.shutdown()
    assert "fixture-token" not in log_path.read_text()
    print("environment precedence, config validation, reload and credential redaction passed")
