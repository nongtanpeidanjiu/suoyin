"""Own-directory full-index recovery, compaction, and long-journal probes."""
import argparse
import hashlib
import json
import os
import struct
import subprocess
import tempfile
import time
from pathlib import Path

from track_client import TrackClient, write_summary


def folded_metadata(rows):
    return {Path(row["path"]): (row["size"], row["modified"]) for row in rows}


def reference(directory):
    return {path: (info.st_size, info.st_mtime_ns) for path in directory.iterdir()
            if (info := path.lstat())}


def clone(source, destination):
    assert source.is_file() and source.stat().st_size < 500_000_000
    subprocess.run(["/bin/cp", "-c", str(source), str(destination)], check=True)


def start(args, snapshot, folder, label):
    return TrackClient(args.cli, "/", snapshot, folder, folder / f"{label}-transcript.tmp")


def rebuild(args, state, probe):
    snapshot = state / "rebuild-index.tmp"
    clone(args.base, snapshot)
    marker = probe / "rebuild-search-proof.tmp"
    marker.touch()
    run = start(args, snapshot, state, "rebuild")
    try:
        boot = run.wait("ready", timeout=70)
        rebuilt = run.wait("rebuilt", timeout=90)
        run.wait("caught-up", timeout=30)
        observed = run.call("query", query=marker.name)["rows"]
        assert folded_metadata(observed) == reference(probe)
        settled = run.call("status")
        sampled_peak = run.finish()
        return dict(startup=boot, rebuilt=rebuilt, settled=settled, peakRSS=sampled_peak,
                    equalsIndependent=True, fixture=str(probe), snapshot=str(snapshot))
    finally:
        run.terminate_fixture_if_needed()


def compaction(args, state, probe):
    snapshot = state / "compaction-index.tmp"
    clone(args.base, snapshot)
    run = start(args, snapshot, state, "compaction")
    try:
        run.wait("ready", timeout=60)
        run.wait("caught-up", timeout=90)
        initial = run.call("status")
        target = 33_000
        for total in range(0, target, 5_500):
            for i in range(total, total + 5_500):
                (probe / f"mergeproof-{i:05}.tmp").touch()
            run.call("sync")
        until = time.monotonic() + 45
        samples = []
        changed_while_busy = False
        late = probe / "mergeproof-late.tmp"
        while time.monotonic() < until:
            result = run.call("query", query="mergeproof-0000")
            status = result["status"]
            assert result["rows"] and all(Path(row["path"]).is_relative_to(probe) for row in result["rows"])
            samples.append(dict(status=status, rss=result["residentBytes"],
                                elapsedMS=(result["queryEnd"] - result["queryStart"]) / 1e6))
            if status["compacting"] and not changed_while_busy:
                late.touch()
                (probe / "mergeproof-00000.tmp").write_bytes(b"late update")
                changed_while_busy = True
            if status["compactions"] > initial["status"]["compactions"]:
                break
        assert changed_while_busy and status["compactions"] > initial["status"]["compactions"]
        expected = reference(probe)
        until = time.monotonic() + 12
        while time.monotonic() < until:
            rows = run.call("query", query="mergeproof-", limit=target + 50)["rows"]
            if folded_metadata(rows) == expected and len(rows) == len(expected):
                break
            time.sleep(.1)
        assert folded_metadata(rows) == expected and len(rows) == len(expected)
        final = run.call("status")
        peak = run.finish()
        return dict(original=target, intervalSamples=samples, final=final, peakRSS=peak,
                    concurrentEdit=True, equal=True, fixture=str(probe), snapshot=str(snapshot))
    finally:
        run.terminate_fixture_if_needed()


def write_long_journal(source, rows):
    with source.open("rb") as handle:
        header = handle.read(64)
        metadata_length = struct.unpack_from("<I", header, 24)[0]
        handle.seek(-metadata_length, os.SEEK_END)
        metadata = json.loads(handle.read(metadata_length))
    assert header[:8] == b"M2INDEX2"
    journal = Path(str(source) + ".changes")
    positions = {entry["root"]: entry["appliedEvent"] for entry in metadata["volumes"]
                 if entry.get("appliedEvent")}
    assert positions
    positional = bytearray(struct.pack("<III", 0, 0, len(positions)))
    for root, position in positions.items():
        data = os.fsencode(root)
        positional.extend(struct.pack("<I", len(data)) + data + struct.pack("<Q", position))
    # Old updates repeat a few hundred valid paths; the final batch matches real metadata.
    def payload(prior_offset):
        result = bytearray(struct.pack("<I", len(rows)))
        for path, (size, modified) in rows.items():
            value = os.fsencode(path)
            result.extend(struct.pack("<I", len(value)))
            result.extend(value)
            result.extend(struct.pack("<BBqq", 1, 1, size, modified - prior_offset))
        result.extend(positional)
        return result

    def put(handle, data):
        length = struct.pack("<I", len(data))
        checksum = hashlib.sha256()
        checksum.update(length)
        checksum.update(data)
        handle.write(length + checksum.digest())
        handle.write(data)

    older = payload(100)
    repeats = (24 * 1024 * 1024) // (len(older) + 36)
    with journal.open("xb") as handle:
        handle.write(b"M2DELTA1" + struct.pack("<I", 1) + header[32:64])
        for _ in range(repeats):
            put(handle, older)
        put(handle, payload(0))
    return journal.stat().st_size, repeats + 1


def long_journal(args, state, probe):
    snapshot = state / "long-journal-index.tmp"
    clone(args.base, snapshot)
    for i in range(512):
        (probe / f"longjournalproof-{i:04}.tmp").write_bytes(bytes(i % 31))
    expected = reference(probe)
    size, frames = write_long_journal(snapshot, expected)
    trials = []
    for _ in range(7):
        run = start(args, snapshot, state, "long")
        try:
            cached = run.wait("ready", timeout=60)
            ready_ms = (time.monotonic_ns() - run.started) / 1e6
            rows = run.call("query", query="longjournalproof-", limit=600)["rows"]
            assert folded_metadata(rows) == expected
            assert cached["status"]["journalRestoredFrames"] == frames
            trials.append(dict(milliseconds=ready_ms, correct=True, ready=cached["status"]))
            run.finish(kill=True)
        finally:
            run.terminate_fixture_if_needed()
    return dict(bytes=size, frames=frames, recordsPerFrame=len(expected), trials=trials,
                fixture=str(probe), snapshot=str(snapshot), generated=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("case", choices=("rebuild", "compaction", "long"))
    parser.add_argument("cli", type=Path)
    parser.add_argument("base", type=Path)
    parser.add_argument("state", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    scratch = Path(".m2-tmp").resolve()
    state = args.state.resolve()
    assert state.is_relative_to(scratch)
    probe = Path(tempfile.mkdtemp(prefix=f"rework-{args.case}-", dir=scratch)).resolve()
    result = {"rebuild": rebuild, "compaction": compaction, "long": long_journal}[args.case](args, state, probe)
    write_summary(args.output, result)
