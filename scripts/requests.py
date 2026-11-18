"""Write the fixed replay matrix for the real or million-hit corpus."""
import argparse
import json
from pathlib import Path

COLUMNS = ("name", "path", "size", "modified")
DIRECTIONS = ("ascending", "descending")


def request(label, query, mode="name", column="name", direction="ascending", offset=0):
    return dict(label=label, query=query, mode=mode, column=column,
                direction=direction, showAll=True, offset=offset)


def matrix(kind):
    if kind == "direct":
        return [
            request("direct-name", "文"),
            request("direct-path", "质量 2026", "path"),
            request("direct-slash", "/usr/bin/find", "path"),
        ]
    if kind == "direct-million":
        return [request("direct-million", "a", column="size")]
    sort_query = "a"
    rows = []
    if kind == "real":
        groups = (
            ("char1", "name", ("文", "药", "中")),
            ("char2", "name", ("质量", "系统", "记录")),
            ("english", "name", ("report", "README", "index")),
            ("name-words", "name", ("test json", "read me", "质量 记录")),
            ("path-one", "path", ("质量", "README", "iCloud")),
            ("path-words", "path", ("质量 2026", "Library Caches", "Users report")),
            ("path-slash", "path", ("System/Library", "Library/Caches README", "/usr/bin/find")),
            ("absent-name", "name", ("qz_no_file_aa72e183",)),
            ("absent-path", "path", ("并无此项_00bdeb2c", "_a98d1b24_nomatch")),
        )
        for label, mode, queries in groups:
            rows.extend(request(f"{label}:{i}", q, mode) for i, q in enumerate(queries))
    else:
        rows.append(request("million:0", "a"))
    for column in COLUMNS:
        for direction in DIRECTIONS:
            for offset in (0, 50):
                rows.append(request(f"sort:{column}:{direction}:{offset}", sort_query,
                                    column=column, direction=direction, offset=offset))
                if kind == "real":
                    rows.append(request(f"rare-sort:{column}:{direction}:{offset}", "质量 记录",
                                        column=column, direction=direction, offset=offset))
    return rows


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=("real", "million", "direct", "direct-million"))
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_text(json.dumps(matrix(args.kind), ensure_ascii=False) + "\n")
