"""Check the complete warm-tracker startup page from the saved index records."""
import argparse
import hashlib
import heapq
import json
import mmap
import struct
from collections import defaultdict
from pathlib import Path

from oracle import ROOT, ROW, join, key


def journal_changes(snapshot, identity, metadata):
    tracking = metadata.get("tracking") or {}
    overlay = dict(tracking.get("changes", {}))
    masks = {}
    path = Path(str(snapshot) + ".changes")
    if not path.is_file():
        return overlay, masks
    with path.open("rb") as source:
        if source.read(44) != b"M2DELTA1" + struct.pack("<I", 1) + identity:
            return overlay, masks
        while prefix := source.read(4):
            if len(prefix) != 4:
                break
            length = struct.unpack("<I", prefix)[0]
            if length > 32 * 1024 * 1024:
                break
            digest = source.read(32)
            body = source.read(length)
            if len(body) != length or hashlib.sha256(prefix + body).digest() != digest:
                break
            at = 0

            def integer(code):
                nonlocal at
                value = struct.unpack_from("<" + code, body, at)[0]
                at += struct.calcsize(code)
                return value

            for _ in range(integer("I")):
                width = integer("I")
                name = body[at:at + width].decode()
                at += width
                if integer("B"):
                    overlay[name] = dict(attribute=integer("B"), size=integer("q"), modified=integer("q"))
                else:
                    overlay.pop(name, None)
            for _ in range(integer("I")):
                row = integer("I")
                masks[row] = bool(integer("B"))
    return overlay, masks


def first_page(snapshot):
    with snapshot.open("rb") as file, mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as data:
        assert data[:8] == b"M2INDEX2"
        count, names, folded, changed, metadata_size, version = struct.unpack_from("<6I", data, 8)
        flag_start = 64 + count * ROW.size
        pool = flag_start + count
        metadata_start = pool + names + 20 * count + 4 * changed + folded
        assert version == 1 and metadata_start + metadata_size == len(data)
        metadata = json.loads(data[metadata_start:])
        overlay, masks = journal_changes(snapshot, data[32:64], metadata)

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
                if flags & 3 == 0 or flags & 16 or masks.get(index, bool(flags & 32)):
                    continue
                raw, _, size, modified = stored(index)
                folded_name = key(raw)
                if b"a" in folded_name:
                    yield folded_name, raw, index, size, modified, None
            groups = defaultdict(list)
            for path, entry in overlay.items():
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
