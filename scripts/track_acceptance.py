"""Real FSEvents, independently enumerated metadata, and own-process fault injection."""
import argparse
import hashlib
import json
import os
import statistics
import struct
import subprocess
import tempfile
import time
from pathlib import Path

from track_client import TrackClient, write_summary


def tree_rows(root, ignored):
    result = {}
    for parent, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = [name for name in dirs if Path(parent, name) != ignored]
        for name in dirs + files:
            path = Path(parent, name)
            meta = path.lstat()
            result[str(path)] = (meta.st_size, meta.st_mtime_ns)
    return result


def from_search(rows):
    assert len(rows) == len({item["path"] for item in rows})
    return {item["path"]: (item["size"], item["modified"]) for item in rows}


def converge(tracker, expected, timeout=10):
    until = time.monotonic() + timeout
    last = None
    while time.monotonic() < until:
        last = tracker.call("query", limit=max(len(expected) + 100, 200))
        received_at = time.monotonic_ns()
        rows = from_search(last["rows"])
        if rows == expected:
            last["referenceReceivedAt"] = received_at
            return last
        time.sleep(.025)
    differences = [(path, expected.get(path), rows.get(path))
                   for path in rows.keys() | expected.keys() if rows.get(path) != expected.get(path)]
    raise AssertionError(f"did not converge: {len(differences)} differences, sample={differences[:4]}, status={last['status']}")


def inspect(cli, snapshot):
    raw = subprocess.check_output([str(cli), "inspect-cache", str(snapshot)], text=True)
    volumes, rows = map(json.loads, raw.splitlines())
    return {v["root"]: v["appliedEvent"] for v in volumes if "appliedEvent" in v}, from_search(rows)


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def exercise(cli, directory):
    tree = directory / "tree"
    tree.mkdir()
    store = tree / "owned-index"
    store.mkdir()
    snap = store / "index.tmp"
    journal = Path(str(snap) + ".changes")
    (tree / "a").mkdir()
    (tree / "b").mkdir()
    (tree / "a" / "ready.tmp").touch()
    for i in range(2100):
        (tree / f"seed-{i:05}.tmp").touch()
    summary = {"iterations": []}
    log = directory / "transcript.tmp"
    tracker = TrackClient(cli, tree, snap, store, log, gate=True)
    maximums = []
    try:
        partial = tracker.wait("scan-partial")
        expected_partial = tree_rows(tree, store)
        published = from_search(tracker.call("query", limit=len(expected_partial) + 100)["rows"])
        assert published and published.items() <= expected_partial.items()
        (tree / "seed-00000.tmp").rename(tree / "observed-during-scan.tmp")
        tracker.call("continue-scan")
        first = tracker.wait("ready")
        aligned = tracker.wait("caught-up")
        expected_aligned = tree_rows(tree, store)
        first_query = tracker.call("query", limit=len(expected_aligned) + 100)
        assert from_search(first_query["rows"]) == expected_aligned
        summary["duringScan"] = dict(partial=partial["time"], ready=first["time"],
                                     partialRows=len(published), applied=aligned["status"]["appliedEvents"],
                                     caughtUp=aligned["time"], firstQueryEqual=True, equal=True)

        def measure(kind, mutate):
            start = time.monotonic_ns()
            count = mutate()
            end = time.monotonic_ns()
            expected = tree_rows(tree, store)
            row = converge(tracker, expected)
            query_end = row["referenceReceivedAt"]
            elapsed = (query_end - end) / 1e6
            total = (query_end - start) / 1e6
            summary["iterations"].append(dict(kind=kind, changed=count, equivalent=len(expected),
                                               visibleMS=elapsed, totalMS=total,
                                               generation=row["status"]["generation"]))

        def touch(path):
            path.touch()
            return 1

        def remove(path):
            path.unlink()
            return 1

        def move(src, dst):
            src.rename(dst)
            return 1

        for i in range(3):
            at = tree / "a" / f"m{i}.tmp"
            renamed = tree / "a" / f"renamed-{i}.tmp"
            destination = tree / "b" / f"relocated-{i}.tmp"
            measure("create", lambda: touch(at))
            measure("rename", lambda: move(at, renamed))
            measure("cross", lambda: move(renamed, destination))
            measure("delete", lambda: remove(destination))
            source = tree / "a" / f"folder-{i}"
            source.mkdir()
            (source / "deep.tmp").touch()
            converge(tracker, tree_rows(tree, store))
            measure("move-directory", lambda: move(source, tree / "b" / source.name))

        def bulk():
            folder = tree / "batch"
            folder.mkdir()
            for i in range(10000):
                (folder / f"row-{i:05}.tmp").touch()
            return 10000

        measure("bulk", bulk)
        current = tracker.call("save")["status"]
        saved = current["appliedEvents"]
        assert saved and current["durableGeneration"] == current["generation"] and tracker.process.poll() is None
        durable, archive = inspect(cli, snap)
        assert durable == current["durableEvents"] and archive == tree_rows(tree, store)
        assert all(durable[volume] <= saved[volume] for volume in durable)
        summary["incremental"] = dict(alive=True, applied=saved, durable=durable, equal=True,
                                      baseWrites=current["baseWrites"], frames=current["journalFrames"])
        assert current["baseWrites"] == 1 and current["journalFrames"] >= 1

        before = tracker.call("status")["status"]["appliedEvents"]
        tracker.call("hold")
        pending = tree / "pending.tmp"
        pending.touch()
        run = tracker.call("sync")
        until = time.monotonic() + 3
        run = tracker.call("queued-event", query=str(pending))
        pending_id = run.get("queuedEvent")
        while pending_id is None and time.monotonic() < until:
            time.sleep(.03)
            tracker.call("sync")
            run = tracker.call("queued-event", query=str(pending))
            pending_id = run.get("queuedEvent")
        assert run["status"]["bufferedEvents"] > 0 and pending_id is not None and pending_id > before[str(tree)]
        assert run["status"]["appliedEvents"] == before
        tracker.call("save")
        durable, archive = inspect(cli, snap)
        assert durable and all(durable[volume] <= before[volume] for volume in durable)
        assert durable[str(tree)] < pending_id
        assert str(pending) not in archive
        fingerprint_at_hold = fingerprint(snap)
        maximums.append(tracker.finish(kill=True))
        assert fingerprint(snap) == fingerprint_at_hold
        time.sleep(.25)
        tracker = TrackClient(cli, tree, snap, store, log)
        checkpoint_ready = tracker.wait("ready")
        assert checkpoint_ready["status"]["recovery"] == "replay"
        tracker.wait("caught-up")
        recovered_pending = converge(tracker, tree_rows(tree, store))
        summary["pendingCheckpoint"] = dict(before=before, durable=durable,
                                             queued=run["status"]["bufferedEvents"], pendingID=pending_id,
                                             recoveredAt=recovered_pending["status"]["appliedEvents"],
                                             withheld=True, restartedFromSameFile=True, replayEqual=True)
        maximums.append(tracker.finish())

        (tree / "ready-offline.tmp").touch()
        (tree / "a" / "ready.tmp").rename(tree / "b" / "offline-renamed.tmp")
        time.sleep(.25)
        tracker = TrackClient(cli, tree, snap, store, log)
        cached = tracker.wait("ready")
        tracker.wait("caught-up")
        recovered = converge(tracker, tree_rows(tree, store))
        assert cached["status"]["recovery"] == "replay"
        summary["offline"] = dict(route=cached["status"]["recovery"], equal=True,
                                  searchTime=cached["time"], verifiedTime=recovered["time"])

        tracker.call("save")
        old_archive = fingerprint(snap)
        (tree / "atomic-survivor.tmp").touch()
        converge(tracker, tree_rows(tree, store))
        tracker.call("pause-before-replace", expected="before-replace")
        maximums.append(tracker.finish(kill=True))
        assert fingerprint(snap) == old_archive
        tracker = TrackClient(cli, tree, snap, store, log)
        tracker.wait("ready")
        tracker.wait("caught-up")
        converge(tracker, tree_rows(tree, store))
        summary["crashBeforeReplace"] = dict(oldIntact=True, replayEqual=True)

        tracker.call("save")
        old_archive = fingerprint(snap)
        old_journal = fingerprint(journal)
        (tree / "after-swap.tmp").touch()
        converge(tracker, tree_rows(tree, store))
        tracker.call("pause-after-replace", expected="after-replace")
        maximums.append(tracker.finish(kill=True))
        assert fingerprint(snap) != old_archive and fingerprint(journal) == old_journal
        tracker = TrackClient(cli, tree, snap, store, log)
        ready = tracker.wait("ready")
        tracker.wait("caught-up")
        converge(tracker, tree_rows(tree, store))
        assert ready["status"]["journalRecovery"] == "identity-or-version"
        summary["crashAfterReplace"] = dict(newBase=True, oldJournalIgnored=True, replayEqual=True)

        high_frequency = tree / "hot.tmp"
        high_frequency.write_bytes(b"a")
        converge(tracker, tree_rows(tree, store))
        before_hot = tracker.call("save")["status"]
        for i in range(240):
            high_frequency.write_bytes(bytes(i % 32))
        converge(tracker, tree_rows(tree, store))
        after_hot = tracker.call("save")["status"]
        assert after_hot["journalFrames"] - before_hot["journalFrames"] == 1
        summary["hotPath"] = dict(updates=240, frames=1,
                                  bytes=after_hot["journalWrittenBytes"] - before_hot["journalWrittenBytes"])

        for i in range(3):
            (tree / f"journal-edit-{i}.tmp").touch()
            converge(tracker, tree_rows(tree, store))
            tracker.call("save")
        maximums.append(tracker.finish())
        base = snap.read_bytes()
        valid = journal.read_bytes()
        offsets = []
        at = 44
        while at + 36 <= len(valid):
            offsets.append(at)
            at += 36 + struct.unpack_from("<I", valid, at)[0]
        assert at == len(valid) and len(offsets) >= 3
        damaged = bytearray(valid)
        damaged[offsets[1] + 4] ^= 1
        mismatch = bytearray(valid)
        mismatch[12] ^= 1
        summary["journalFaults"] = {}
        for name, payload, behavior, restored in (
            ("tail", valid[:-3], "discarded-suffix", len(offsets) - 1),
            ("middle", damaged, "discarded-suffix", 1),
            ("mismatch", mismatch, "identity-or-version", 0),
            ("missing", None, "missing", 0),
        ):
            snap.write_bytes(base)
            if payload is None:
                journal.unlink()
            else:
                journal.write_bytes(payload)
            tracker = TrackClient(cli, tree, snap, store, log)
            ready = tracker.wait("ready")
            tracker.wait("caught-up")
            converge(tracker, tree_rows(tree, store))
            assert ready["status"]["journalRecovery"] == behavior
            assert ready["status"]["journalRestoredFrames"] == restored
            assert ready["status"]["recovery"] == "replay"
            summary["journalFaults"][name] = dict(recovery=behavior, validPrefix=restored, replayEqual=True)
            maximums.append(tracker.finish())

        tracker = TrackClient(cli, tree, snap, store, log)
        tracker.wait("ready")
        tracker.wait("caught-up")
        tracker.call("hold")
        (tree / "dropped.tmp").touch()
        tracker.call("sync")
        tracker.call("invalidate-history", expected="invalidated")
        tracker.call("resume")
        row = converge(tracker, tree_rows(tree, store))
        assert row["status"]["recovery"] == "history-invalid"
        summary["invalidHistory"] = dict(route=row["status"]["recovery"], equal=True)
        tracker.wait("caught-up") if row["status"]["phase"] != "caught-up" else None
        initial_rebuilds = tracker.call("status")["status"]["rebuilds"]
        tracker.call("invalidate-history", expected="invalidated")
        degraded = tracker.call("status")["status"]
        assert degraded["degradedVolumes"] and degraded["rebuilds"] == initial_rebuilds
        summary["rebuildThrottle"] = dict(degraded=True, rebuilds=degraded["rebuilds"])
        maximums.append(tracker.finish())

        data = bytearray(snap.read_bytes())
        data[-1] ^= 1
        snap.write_bytes(data)
        tracker = TrackClient(cli, tree, snap, store, log)
        corrupted = tracker.wait("ready")
        tracker.wait("caught-up")
        assert corrupted["status"]["recovery"] == "corrupt"
        converge(tracker, tree_rows(tree, store))
        summary["corrupt"] = dict(route=corrupted["status"]["recovery"], equal=True)
        tracker.call("save")
        maximums.append(tracker.finish())

        offline_tree = tree / "offline-many"
        offline_tree.mkdir()
        for i in range(12000):
            (offline_tree / f"entry-{i:05}.tmp").touch()
        expected = tree_rows(tree, store)
        tracker = TrackClient(cli, tree, snap, store, log)
        initialized = tracker.wait("ready")
        caught = tracker.wait("caught-up")
        converge(tracker, expected)
        summary["longReplay"] = dict(created=12000, route=initialized["status"]["recovery"],
            delivered=caught["status"]["receivedEvents"], replayMilliseconds=(caught["time"] - initialized["time"]) / 1e6,
            equal=True)
        assert summary["longReplay"]["route"] == "replay"
        maximums.append(tracker.finish())

        for name in {item["kind"] for item in summary["iterations"]}:
            rows = [item for item in summary["iterations"] if item["kind"] == name]
            summary.setdefault("timings", {})[name] = dict(
                medianMS=statistics.median(r["visibleMS"] for r in rows),
                maxMS=max(r["visibleMS"] for r in rows), maxTotalMS=max(r["totalMS"] for r in rows),
                repetitions=len(rows))
        summary["peakRSS"] = max(maximums)
        return summary
    finally:
        tracker.terminate_fixture_if_needed()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("cli", type=Path)
    parser.add_argument("scratch", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    test = Path(tempfile.mkdtemp(prefix="functional-", dir=args.scratch)).resolve()
    try:
        write_summary(args.output, exercise(args.cli, test))
    except Exception:
        print(f"Retained local transcript at {test}", flush=True)
        raise
