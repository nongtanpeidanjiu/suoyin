"""Observe saved placeholder examples using metadata only."""
import json
import os
import sys
from pathlib import Path


def sample(recorded):
    rows = json.loads(Path(recorded).read_text())
    return {
        row["path"]: dict(ino=info.st_ino, flags=info.st_flags, blocks=info.st_blocks, size=info.st_size)
        for row in rows
        if row.get("dataless") and row.get("regular")
        for info in [os.lstat(row["path"])]
    }


if __name__ == "__main__":
    print(json.dumps(sample(sys.argv[1]), ensure_ascii=False, sort_keys=True))
