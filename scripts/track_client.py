"""Monitor only the child tracker launched by this local harness."""
import json
import os
import selectors
import subprocess
import threading
import time
from pathlib import Path

from measure import RSS_LIMIT, STALL_SECONDS


class TrackClient:
    def __init__(self, cli, root, snapshot, own, log, gate=False, record_query_rows=True):
        self.started = time.monotonic_ns()
        self.record_query_rows = record_query_rows
        self.log = open(log, "a", encoding="utf-8")
        self.errors = open(str(log) + ".stderr", "ab")
        environment = dict(os.environ)
        if gate:
            environment["M2_HOLD_PARTIAL"] = "1"
        self.process = subprocess.Popen(
            [str(cli), "track", str(root), str(snapshot), str(own)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors,
            bufsize=0, env=environment,
        )
        self.maximum = 0
        self.window_rss = None
        self.stop_reason = None
        self.buffer = bytearray()
        self.monitor = threading.Thread(target=self.watch, daemon=True)
        self.monitor.start()

    def watch(self):
        previous = time.monotonic()
        while self.process.poll() is None:
            try:
                ps = subprocess.run(
                    ["/bin/ps", "-o", "rss=", "-p", str(self.process.pid)],
                    capture_output=True, timeout=STALL_SECONDS,
                )
                elapsed = time.monotonic() - previous
                previous = time.monotonic()
                value = ps.stdout.strip()
                if value:
                    rss = int(value) * 1024
                    self.maximum = max(self.maximum, rss)
                    window = self.window_rss
                    if window is not None:
                        self.window_rss = max(window, rss)
                if elapsed <= STALL_SECONDS and self.maximum <= RSS_LIMIT:
                    time.sleep(.1)
                    continue
                self.stop_reason = "RSS limit" if self.maximum > RSS_LIMIT else "system response stalled"
            except subprocess.TimeoutExpired:
                self.stop_reason = "system response stalled"
            self.process.kill()
            return

    def line(self, timeout=35):
        until = time.monotonic() + timeout
        with selectors.DefaultSelector() as stream:
            stream.register(self.process.stdout, selectors.EVENT_READ)
            while b"\n" not in self.buffer:
                remaining = until - time.monotonic()
                if remaining <= 0 or not stream.select(remaining):
                    raise RuntimeError(f"tracker timed out, exit={self.process.poll()}, stop={self.stop_reason}")
                chunk = os.read(self.process.stdout.fileno(), 131072)
                if not chunk:
                    raise RuntimeError(f"tracker closed stream, exit={self.process.poll()}, stop={self.stop_reason}")
                self.buffer.extend(chunk)
        end = self.buffer.index(10)
        row = json.loads(self.buffer[:end])
        del self.buffer[:end + 1]
        if not self.record_query_rows and row["event"] == "query":
            logged = {key: value for key, value in row.items() if key != "rows"}
            logged["rowsCount"] = len(row["rows"])
        else:
            logged = row
        self.log.write(json.dumps(logged, ensure_ascii=False) + "\n")
        self.log.flush()
        if row["event"] == "error":
            raise RuntimeError(row["status"]["error"])
        return row

    def wait(self, event, timeout=40):
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            row = self.line(max(.01, until - time.monotonic()))
            if row["event"] == event:
                return row
        raise RuntimeError(f"phase missing: {event}")

    def call(self, op, expected=None, **args):
        data = json.dumps(dict(op=op, **args), ensure_ascii=False).encode() + b"\n"
        self.process.stdin.write(data)
        return self.wait(expected or op)

    def finish(self, kill=False):
        try:
            if self.process.poll() is None:
                if kill:
                    self.process.kill()
                else:
                    self.call("quit")
            self.process.wait(timeout=15)
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.monitor.join(timeout=5)
            self.errors.close()
            self.log.close()
        if self.stop_reason:
            raise RuntimeError(self.stop_reason)
        if not kill and self.process.returncode:
            raise RuntimeError(f"tracker exit={self.process.returncode}")
        return self.maximum

    def terminate_fixture_if_needed(self):
        if not self.log.closed:
            self.finish(kill=True)


def write_summary(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
