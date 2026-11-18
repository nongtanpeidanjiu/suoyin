"""Check the complete warm-tracker startup page from the saved index records."""
import argparse
import heapq
import json
import mmap
import struct
from collections import defaultdict
from pathlib import Path

from oracle import ROOT, ROW, join, key


def first_page(snapshot):
    with snapshot.open("rb") as file, mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as data:
        assert data[:8] == b"M2INDEX2"
        count, names, folded, changed, metadata_size, version = struct.unpack_from("<6I", data, 8)
        flag_start = 64 + count * ROW.size
        pool = flag_start + count
        metadata_start = pool + names + 20 * count + 4 * changed + folded
        assert version == 1 and metadata_start + metadata_size == len(data)
        metadata = json.loads(data[metadata_start:])

        def stored(index):
            offset, parent, size, modified = ROW.unpack_from(data, 64 + ROW.size * index)
            offset += pool
            end = data.find(b"\0", offset, pool + names)
            assert end >= offset
            raw = data[offset:end]
            return raw, parent, size, modified

        def path_to(index):
            components = []
            while index != ROOT:
                raw, index, _, _ = stored(index)
                components.append(raw)
            result = b""
            for part in reversed(components):
                result = join(result, part)
            return result

        def candidates():
            for index in range(count):
                flags = data[flag_start + index]
                if flags & 3 == 0 or flags & 48:
                    continue
                raw, _, size, modified = stored(index)
                folded_name = key(raw)
                if b"a" in folded_name:
                    yield folded_name, raw, index, size, modified, None
            tracking = metadata["tracking"] or {}
            groups = defaultdict(list)
            for path, entry in tracking.get("changes", {}).items():
                parent, _, name = path.rpartition("/")
                if not entry["attribute"] & 48:
                    groups[parent or "/"].append((path, name, entry))
            positions = [0] * 8
            for parent, siblings in sorted(groups.items()):
                hash_value = 2166136261
                for byte in parent.encode():
                    hash_value = ((hash_value ^ byte) * 16777619) & ROOT
                part = hash_value & 7
                positions[part] += 1  # Parent anchor.
                for path, name, entry in sorted(siblings):
                    index = (1 << 31) | (part << 27) | positions[part]
                    positions[part] += 1
                    raw = name.encode()
                    folded_name = key(raw)
                    if b"a" in folded_name:
                        yield folded_name, raw, index, entry["size"], entry["modified"], path.encode()

        return [
            dict(id=index, name=raw.decode("utf-8", "replace"), size=size, modified=modified,
                 path=(path_to(index) if path is None else path).decode("utf-8", "replace"))
            for _, raw, index, size, modified, path in heapq.nsmallest(50, candidates(), key=lambda row: row[:3])
        ]


if __name__ == "__main__":
    args = argparse.ArgumentParser()
    args.add_argument("snapshot", type=Path)
    args.add_argument("startup_records", type=Path)
    options = args.parse_args()
    expected = first_page(options.snapshot)
    with options.startup_records.open() as file:
        data = [json.loads(line) for line in file]
    correct = [entry["rows"] == expected for entry in data]
    print(json.dumps({"expectedRows": len(expected), "independentlyEqual": correct}, indent=2))
    if len(correct) != 7 or not all(correct):
        raise SystemExit(8)
