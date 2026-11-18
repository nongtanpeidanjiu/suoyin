"""Exercise the CLI's actual rebuild route with an owned test directory."""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path


def run(cli, *args):
    result = subprocess.run([str(cli), *map(str, args)], check=True, capture_output=True, text=True)
    return [json.loads(line) for line in result.stdout.splitlines()]


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("cli", type=Path)
    parser.add_argument("scratch", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="recovery-", dir=args.scratch) as directory:
        root = Path(directory)
        tree = root / "tree"
        tree.mkdir()
        (tree / "a-file.txt").write_text("fixture")
        snap = root / "actual.snapshot"
        missing = run(args.cli, "verify-recovery", snap, tree)[0]
        assert missing == dict(rebuilt=True, searchable=True)
        raw = snap.read_bytes()
        corrupt = bytearray(raw)
        corrupt[-1] ^= 1
        for mode, data in (("bad-checksum", corrupt), ("truncated", raw[:-1])):
            snap.write_bytes(data)
            result = run(args.cli, "verify-recovery", snap, tree)[0]
            assert result == dict(rebuilt=True, searchable=True)
            ready = run(args.cli, "ready", snap)
            assert [row["name"] for row in ready[1]] == ["a-file.txt"]
            print(json.dumps(dict(mode=mode, **result)))
        healthy = run(args.cli, "verify-recovery", snap, tree)[0]
        assert healthy == dict(rebuilt=False, searchable=True)
        print(json.dumps(dict(mode="healthy", **healthy)))
