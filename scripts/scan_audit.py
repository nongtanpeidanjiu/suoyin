"""Check both physical scope anchors, path uniqueness and stable system metadata samples."""
import argparse
import json
import mmap
import os
import struct
from pathlib import Path

from oracle import ROOT, ROW, join

DATA = b"/System/Volumes/Data"
SAMPLES = (b"/usr/bin/find", b"/bin/ls", b"/usr/share/firmlinks")
with open("/usr/share/firmlinks", "rb") as f:
    mirrors = {DATA + b"/" + parts[1] for line in f if len(parts := line.rstrip(b"\n").split(b"\t")) == 2}


def audit(snapshot):
    with open(snapshot, "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as data:
        assert data[:8] == b"M1INDEX1"
        version, count, size, volume_bytes = struct.unpack_from("<IIQQ", data, 8)
        flags = 64 + count * ROW.size
        names = flags + count
        volumes = json.loads(data[names + size:names + size + volume_bytes])
        assert version == 1 and names + size + volume_bytes == len(data)
        assert {row["root"] for row in volumes} == {"/", DATA.decode()}
        assert any(row.get("readOnly") is True for row in volumes)
        assert any(row.get("eventLogUUID") for row in volumes if row.get("readOnly") is False)
        active_devices = {row.get("mountedDevice") for row in volumes}
        assert len(active_devices) == 2

        directories, unique, samples = {}, set(), {}
        anchors = {}
        root_membership = bytearray(count)
        total = [0, 0]
        for i in range(count):
            offset, parent, length, modified = ROW.unpack_from(data, 64 + ROW.size * i)
            attr = data[flags + i]
            start = names + offset
            end = data.find(b"\0", start, names + size)
            assert end >= start
            name = data[start:end]
            path = join(directories[parent], name) if parent != ROOT else name
            if attr & 3 == 0:
                assert parent == ROOT and name in (b"/", DATA)
                root_membership[i] = int(name == DATA)
                anchors[name.decode()] = i
            else:
                root_membership[i] = root_membership[parent]
                total[root_membership[i]] += 1
                assert path not in unique, "duplicate visible path in scan"
                unique.add(path)
                assert path not in mirrors, "physical firmlink duplicate"
                if path in SAMPLES:
                    check = os.lstat(path)
                    samples[path.decode()] = check.st_size == length and check.st_mtime_ns == modified
            if attr & 3 in (0, 2):
                directories[i] = path
        assert set(anchors) == {"/", DATA.decode()} and total[1] > 0
        assert len(samples) == len(SAMPLES) and all(samples.values())
        return dict(anchors=anchors, logicalRows=total[0], distinctPhysicalDataRows=total[1],
                    duplicatePaths=count - len(unique) - len(anchors),
                    mirroredPhysicalRootsExcluded=len(mirrors), metadataSamples=samples,
                    volumeStreams=[dict(root=v["root"], readOnly=v.get("readOnly"),
                                        eventLogKnown=bool(v.get("eventLogUUID"))) for v in volumes])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("snapshot", type=Path)
    args = parser.parse_args()
    print(json.dumps(audit(args.snapshot), ensure_ascii=False, indent=2))
