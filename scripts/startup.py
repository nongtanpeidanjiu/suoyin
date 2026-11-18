"""Measure seven new processes to the first completed-query marker."""
import argparse
import json
import subprocess
import threading
import time
from pathlib import Path

from measure import RSS_LIMIT, STALL_SECONDS


def trial(cli, snapshot):
    start = time.monotonic()
    process = subprocess.Popen([str(cli), "ready", str(snapshot)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    peak = 0
    stop = None

    def monitor():
        nonlocal peak, stop
        while process.poll() is None:
            try:
                ps = subprocess.run(["/bin/ps", "-o", "rss=", "-p", str(process.pid)],
                                    capture_output=True, timeout=STALL_SECONDS)
            except subprocess.TimeoutExpired:
                stop = "system response stalled"
                process.kill()
                return
            raw = ps.stdout.strip()
            if raw:
                peak = max(peak, int(raw) * 1024)
            if peak > RSS_LIMIT:
                stop = "RSS limit"
                process.kill()
                return
            time.sleep(0.02)

    thread = threading.Thread(target=monitor)
    thread.start()
    line = process.stdout.readline()
    elapsed = (time.monotonic() - start) * 1000
    rest, errors = process.communicate()
    thread.join()
    if stop or process.returncode:
        raise SystemExit(stop or errors.decode("utf-8", "replace"))
    metrics = json.loads(line)
    return dict(externalMilliseconds=elapsed, rssMax=peak,
                metrics=metrics, rows=json.loads(rest))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("cli", type=Path)
    parser.add_argument("snapshot", type=Path)
    opts = parser.parse_args()
    for sample in range(7):
        print(json.dumps(dict(sequence=sample + 1, **trial(opts.cli, opts.snapshot)), ensure_ascii=False),
              flush=True)
