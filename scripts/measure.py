"""Run one measurement, abort for an RSS breach or prolonged system stall."""
import argparse
import json
import subprocess
import time
from pathlib import Path

RSS_LIMIT = 1_500_000_000
STALL_SECONDS = 4.0


def run(command, destination, log):
    start = previous = time.monotonic()
    rss_peak = 0
    max_gap = 0
    stop = None
    with open(destination, "wb") as output, open(str(destination) + ".stderr", "wb") as errors:
        process = subprocess.Popen(command, stdout=output, stderr=errors)
        try:
            while process.poll() is None:
                ps = subprocess.run(
                    ["/bin/ps", "-o", "rss=", "-p", str(process.pid)],
                    capture_output=True, timeout=STALL_SECONDS,
                )
                raw = ps.stdout.strip()
                if raw:
                    rss_peak = max(rss_peak, int(raw) * 1024)
                now = time.monotonic()
                max_gap = max(max_gap, now - previous)
                previous = now
                if rss_peak > RSS_LIMIT or max_gap > STALL_SECONDS:
                    stop = "RSS limit" if rss_peak > RSS_LIMIT else "system response stalled"
                    process.kill()
                    break
                time.sleep(0.1)
        except (KeyboardInterrupt, subprocess.TimeoutExpired):
            stop = "interrupted or system response stalled"
            process.kill()
        status = process.wait()
    with open(log, "a") as monitor:
        print(json.dumps(dict(command=command, rssMax=rss_peak, maxGapSeconds=max_gap,
                              status=status, stop=stop, seconds=time.monotonic()-start)), file=monitor)
    if stop:
        raise SystemExit(stop)
    if status:
        raise SystemExit(status)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("monitor", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    run(args.command, args.output, args.monitor)
