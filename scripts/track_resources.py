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
    marker = "r6stable-" + test.name
    control = [(str(path), path.stat().st_size, path.stat().st_mtime_ns)
               for path in sorted(stable.glob(marker + "-*"))]
    assert len(control) == 40
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
            for mode, query in (("name", marker), ("path", "controls " + marker)):
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


def file_bytes(snapshot):
    related = [snapshot, Path(str(snapshot) + ".changes")]
    return {path.name: path.stat().st_size if path.is_file() else 0 for path in related}


def window(first, last):
    wall = (last["time"] - first["time"]) / 1e9
    start, stop = first["status"], last["status"]
    growth = sum(last["files"].values()) - sum(first["files"].values())
    disk = last["processMetrics"]["processWrittenBytes"] - first["processMetrics"]["processWrittenBytes"]
    return dict(wallSeconds=wall, cpuSeconds=last["cpu"] - first["cpu"],
                singleCorePct=100 * (last["cpu"] - first["cpu"]) / wall,
                baseWrites=stop["baseWrites"] - start["baseWrites"],
                baseWrittenBytes=stop["baseWrittenBytes"] - start["baseWrittenBytes"],
                journalFrames=stop["journalFrames"] - start["journalFrames"],
                journalWrittenBytes=stop["journalWrittenBytes"] - start["journalWrittenBytes"],
                processWrittenBytes=disk, persistentNetGrowth=growth,
                extrapolatedProcessBytesPerDay=disk * 86400 / wall,
                extrapolatedNetGrowthPerDay=growth * 86400 / wall,
                events=stop["receivedEvents"] - start["receivedEvents"],
                batches=stop["appliedBatches"] - start["appliedBatches"],
                rebuilds=stop.get("rebuilds", 0) - start.get("rebuilds", 0),
                outOfOrderBatches=stop.get("outOfOrderBatches", 0) - start.get("outOfOrderBatches", 0),
                maximumEventRegression=stop.get("maximumEventRegression", 0))


def idle(tracker, seconds, snapshot, write_cap):
    tracker.call("save")
    before = dict(load=os.getloadavg(), files=file_bytes(snapshot), **tracker.call("status"))
    if before["processMetrics"]["processWrittenBytes"] >= write_cap:
        raise RuntimeError("Startup approached the measurement write limit")
    tracker.window_rss = before["residentBytes"]
    observations = [before]
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        time.sleep(min(10, deadline - time.monotonic()))
        row = dict(load=os.getloadavg(), files=file_bytes(snapshot), **tracker.call("status"))
        observations.append(row)
        if row["processMetrics"]["processWrittenBytes"] >= write_cap:
            raise RuntimeError("Stopped before approaching the measurement write limit")

    def summarized(rows):
        return dict(**window(rows[0], rows[-1]),
                    maxResidentBytes=max(r["residentBytes"] for r in rows),
                    maxPhysicalFootprint=max(r["processMetrics"]["physicalFootprint"] for r in rows))

    result = summarized(observations)
    if seconds >= 300:
        cutoff = next(i for i, row in enumerate(observations)
                      if row["time"] - before["time"] >= 300_000_000_000)
        result["firstFiveMinutes"] = summarized(observations[:cutoff + 1])
    result["maxResidentBytesWatched"] = tracker.window_rss
    tracker.window_rss = None
    result["observations"] = observations
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("cli", type=Path)
    parser.add_argument("state", type=Path)
    parser.add_argument("tree", type=Path)
    parser.add_argument("--seconds", type=int, default=300)
    parser.add_argument("--idle-only", action="store_true")
    parser.add_argument("--snapshot", type=Path)
    parser.add_argument("--write-cap", type=int, default=4_500_000_000)
    parser.add_argument("--caught-up-timeout", type=int, default=70)
    args = parser.parse_args()
    state = args.state.resolve()
    tree = args.tree.resolve()
    if not args.idle_only:
        for name in ("controls", "mutable"):
            (tree / name).mkdir(parents=True, exist_ok=True)
        for i in range(40):
            control = tree / "controls" / f"r6stable-{tree.name}-{i:02}.tmp"
            if not control.exists():
                control.touch()

    with (state / "live-command.json").open("w") as f:
        json.dump(dict(scope="/", state=str(state), tree=str(tree), seconds=args.seconds), f)
    snapshot = args.snapshot.resolve() if args.snapshot else state / "full.snapshot"
    tracker = TrackClient(args.cli, "/", snapshot, state, state / "full-transcript.tmp")
    try:
        ready = tracker.wait("ready", timeout=55)
        tracker.wait("caught-up", timeout=args.caught_up_timeout)
        if not args.idle_only:
            write_summary(state / "overlap.json", overlap(tracker, tree))
        result = idle(tracker, args.seconds, snapshot, args.write_cap)
        result["startup"] = ready
        result["peakMonitoredRSS"] = tracker.maximum
        result["normalExit"] = False
        write_summary(state / "idle.json", result)
        result["peakMonitoredRSS"] = tracker.finish()
        result["normalExit"] = True
        write_summary(state / "idle.json", result)
    finally:
        tracker.terminate_fixture_if_needed()
