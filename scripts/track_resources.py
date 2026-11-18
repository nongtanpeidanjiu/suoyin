"""Full-index overlap latency and five-minute live-resource measurements."""
import argparse
import json
import math
import os
import threading
import time
from pathlib import Path

from track_client import TrackClient, write_summary


def nearest_rank(samples, fraction):
    return sorted(samples)[math.ceil(len(samples) * fraction) - 1] if samples else None


def overlap(tracker, test):
    mutable = test / "mutable"
    stable = test / "controls"
    control = [(str(path), path.stat().st_size, path.stat().st_mtime_ns)
               for path in sorted(stable.iterdir())]
    end = threading.Event()
    errors = []

    def mutate():
        try:
            for i in range(160):
                name = mutable / f"change-{i % 24:02}.txt"
                if name.exists():
                    name.unlink()
                else:
                    name.touch()
                if end.wait(.05):
                    break
        except Exception as error:
            errors.append(error)

    thread = threading.Thread(target=mutate)
    first = tracker.call("status")["status"]
    tracker.call("trace-start")
    thread.start()
    samples = []
    try:
        while thread.is_alive():
            for mode, query in (("name", "m2stablemarker"), ("path", "controls m2stablemarker")):
                result = tracker.call("query", query=query, mode=mode, limit=50)
                comparable = [(row["path"], row["size"], row["modified"]) for row in result["rows"]]
                assert comparable == control
                begin, finish = result["queryStart"], result["queryEnd"]
                status = result["status"]
                samples.append(dict(mode=mode, ms=(finish - begin) / 1e6,
                                    generation=status["generation"], begin=begin, end=finish))
    finally:
        end.set()
        thread.join()
    if errors:
        raise errors[0]
    tracker.call("sync")
    intervals = tracker.call("trace-end")["intervals"]
    for sample in samples:
        sample["overlap"] = any(interval["start"] <= sample["end"] and interval["end"] >= sample["begin"]
                                for interval in intervals)
    last = tracker.call("status")["status"]
    return dict(before=first, after=last, samples=samples, intervals=intervals,
                allP95=nearest_rank([r["ms"] for r in samples], .95),
                overlapP95=nearest_rank([r["ms"] for r in samples if r["overlap"]], .95),
                byMode={m: nearest_rank([r["ms"] for r in samples if r["mode"] == m and r["overlap"]], .95)
                        for m in ("name", "path")})


def idle(tracker, seconds):
    tracker.call("save")
    before = tracker.call("status")
    observations = [dict(load=os.getloadavg(), **before)]
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        time.sleep(min(10, deadline - time.monotonic()))
        observations.append(dict(load=os.getloadavg(), **tracker.call("status")))
    after = observations[-1]
    wall = (after["time"] - before["time"]) / 1e9
    cpu = after["cpu"] - before["cpu"]
    return dict(wallSeconds=wall, cpuSeconds=cpu, singleCorePct=100 * cpu / wall,
                maxResidentBytes=max(r["residentBytes"] for r in observations),
                events=after["status"]["receivedEvents"] - before["status"]["receivedEvents"],
                batches=after["status"]["appliedBatches"] - before["status"]["appliedBatches"],
                observations=observations)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("cli", type=Path)
    parser.add_argument("state", type=Path)
    parser.add_argument("tree", type=Path)
    parser.add_argument("--seconds", type=int, default=300)
    parser.add_argument("--idle-only", action="store_true")
    args = parser.parse_args()
    state = args.state.resolve()
    tree = args.tree.resolve()
    for name in ("controls", "mutable"):
        (tree / name).mkdir(parents=True, exist_ok=True)
    for i in range(40):
        control = tree / "controls" / f"m2stablemarker-{i:02}.txt"
        if not control.exists():
            control.touch()

    with (state / "live-command.json").open("w") as f:
        json.dump(dict(scope="/", state=str(state), tree=str(tree), seconds=args.seconds), f)
    tracker = TrackClient(args.cli, "/", state / "full.snapshot", state, state / "full-transcript.jsonl")
    try:
        ready = tracker.wait("ready", timeout=55)
        tracker.wait("caught-up", timeout=70)
        if not args.idle_only:
            write_summary(state / "overlap.json", overlap(tracker, tree))
        result = idle(tracker, args.seconds)
        result["startup"] = ready
        result["peakMonitoredRSS"] = tracker.maximum
        result["normalExit"] = False
        write_summary(state / "idle.json", result)
        result["peakMonitoredRSS"] = tracker.finish()
        result["normalExit"] = True
        write_summary(state / "idle.json", result)
    finally:
        tracker.terminate_fixture_if_needed()
