#!/bin/bash
# Zip package/ into a distributable .plasmoid (a plain zip of the package directory).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 - "$ROOT" <<'PY'
import json, pathlib, sys, zipfile

root = pathlib.Path(sys.argv[1])
src = root / "package"
meta = json.loads((src / "metadata.json").read_text())["KPlugin"]
out = root / "porthole.plasmoid"
out.unlink(missing_ok=True)

files = sorted(p for p in src.rglob("*") if p.is_file())
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in files:
        z.write(f, f.relative_to(src).as_posix())
    # MIT: every copy carries the notice
    z.write(root / "LICENSE", "LICENSE")

print(f"Built {out.name}  ({meta['Id']}, version {meta['Version']})")
for f in files:
    print(f"  {f.relative_to(src).as_posix()}  ({f.stat().st_size} bytes)")
PY
