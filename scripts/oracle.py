"""Independent index-reader and exact slow reference, runs offline on local snapshots."""
import argparse
import heapq
import json
import math
import mmap
import struct
import unicodedata
from array import array
from pathlib import Path

ROW = struct.Struct("<IIqq")
ROOT = 0xffffffff


def key(raw):
    if raw.isascii():
        return raw.lower()
    return unicodedata.normalize("NFC", raw.decode("utf-8", "replace")).encode().lower()


def join(parent, name):
    return parent + name if parent.endswith(b"/") else parent + b"/" + name if parent else name


class Corpus:
    def __init__(self, file):
        self.file = open(file, "rb")
        self.data = mmap.mmap(self.file.fileno(), 0, access=mmap.ACCESS_READ)
        view = self.data
        assert view[:8] == b"M1INDEX1"
        version, self.count, name_bytes, volumes = struct.unpack_from("<IIQQ", view, 8)
        assert version == 1
        flag_start = 64 + ROW.size * self.count
        pool = flag_start + self.count
        assert pool + name_bytes + volumes == len(view)
        self.flags = view[flag_start:pool]
        self.names, self.keys = [], []
        self.parents = array("I")
        self.sizes, self.modified = array("q"), array("q")
        self.directory_names = {}
        for i in range(self.count):
            offset, parent, size, modified = ROW.unpack_from(view, 64 + ROW.size * i)
            start = pool + offset
            end = view.find(b"\0", start, pool + name_bytes)
            assert end >= start
            nm = view[start:end]
            self.names.append(nm)
            self.keys.append(key(nm))
            self.parents.append(parent)
            self.sizes.append(size)
            self.modified.append(modified)
            if self.flags[i] & 3 in (0, 2):
                self.directory_names[i] = join(self.directory(i), nm)
        self.directory_keys = {i: key(path) for i, path in self.directory_names.items()}

    def directory(self, i):
        return self.directory_names.get(self.parents[i], b"")

    def lookup(self, args):
        spec = {(r["query"], r["mode"], r["showAll"]) for r in args}
        tests = {
            rule: tuple(key(x.encode()) for x in rule[0].split(" ") if x)
            for rule in spec
        }
        name_tests = [(rule, words) for rule, words in tests.items() if rule[1] == "name"]
        path_tests = [(rule, words) for rule, words in tests.items() if rule[1] == "path"]
        hits = {r: array("I") for r in tests}
        for i, flags in enumerate(self.flags):
            if flags & 3 == 0 or flags & 16:
                continue
            nm = self.keys[i]
            for rule, words in name_tests:
                if (rule[2] or not flags & 4) and all(w in nm for w in words):
                    hits[rule].append(i)
            if path_tests:
                raw_path = join(self.directory_keys.get(self.parents[i], b""), nm)
                for rule, words in path_tests:
                    if (rule[2] or not flags & 4) and all(w in raw_path for w in words):
                        hits[rule].append(i)
        return hits

    def rows(self, matches, request, limit):
        col = request["column"]
        def ordering(i):
            first = 0
            if col == "path":
                first = self.directory_keys.get(self.parents[i], b"")
            elif col == "size":
                first = self.sizes[i]
            elif col == "modified":
                first = self.modified[i]
            return first, self.keys[i], self.names[i], i
        offset = request["offset"]
        select = heapq.nsmallest if request["direction"] == "ascending" else heapq.nlargest
        return [
            dict(id=i, name=self.names[i].decode("utf-8", "replace"),
                 path=join(self.directory(i), self.names[i]).decode("utf-8", "replace"),
                 size=self.sizes[i], modified=self.modified[i])
            for i in select(offset+limit, matches, key=ordering)[offset:]
        ]


def summarize(values, fraction):
    return sorted(values)[math.ceil(len(values) * fraction) - 1]


def verify(corpus, requests, observed):
    found = corpus.lookup(requests)
    checks = []
    assert len(requests) == len(observed)
    for request, trial in zip(requests, observed):
        assert trial["label"] == request["label"] and trial["consistent"]
        key_parts = request["query"], request["mode"], request["showAll"]
        matches = found[key_parts]
        expected_rows = corpus.rows(matches, request, 50)
        times = trial["milliseconds"]
        checks.append(dict(label=request["label"], correct=expected_rows == trial["rows"],
                           matches=len(matches), repetitions=len(times),
                           p50=summarize(times, 0.5), p95=summarize(times, 0.95),
                           expectedIds=[row["id"] for row in expected_rows],
                           actualIds=[row["id"] for row in trial["rows"]]))
    return checks


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("requests", type=Path)
    parser.add_argument("measurements", type=Path)
    parser.add_argument("--phase", choices=("partial", "local_complete"))
    args = parser.parse_args()
    corpus = Corpus(args.snapshot)
    log = [json.loads(line) for line in args.measurements.read_text().splitlines()]
    if args.phase:
        row = next(r for r in log if r["mark"]["phase"] == args.phase)
        requests = [dict(label=args.phase, query="a", mode="name", showAll=True,
                         column="name", direction="ascending", offset=0)]
        trials = [dict(label=args.phase, rows=row["returned"], consistent=True,
                       milliseconds=[row["elapsedMilliseconds"]])]
    else:
        requests = json.loads(args.requests.read_text())
        trials = [row for row in log if "label" in row]
    checks = verify(corpus, requests, trials)
    print(json.dumps(checks, ensure_ascii=False, indent=2))
    if not all(c["correct"] for c in checks):
        raise SystemExit(8)


if __name__ == "__main__":
    main()
