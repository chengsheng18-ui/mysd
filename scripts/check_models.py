#!/usr/bin/env python3
"""Verify every model URL in App/ModelManifest.swift resolves and has the
declared byte size. Catches typos in repo/path and silent re-quantisation.

Usage:  python3 scripts/check_models.py [--write-expected]
"""
from __future__ import annotations

import json
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "App" / "ModelManifest.swift"
HOST = "https://hf-mirror.com"

entry = re.compile(
    r'ModelFile\(filename:\s*"([^"]+)",\s*'
    r'repo:\s*"([^"]+)",\s*'
    r'remotePath:\s*"([^"]+)",\s*'
    r'bytes:\s*([0-9_]+)',
    re.S,
)


def api(repo: str) -> dict:
    url = f"{HOST}/api/models/{repo}?blobs=true"
    req = urllib.request.Request(url, headers={"User-Agent": "curl/8.5.0"})
    with urllib.request.urlopen(req, timeout=45) as fh:
        return json.load(fh)


def main() -> int:
    text = MANIFEST.read_text()
    entries = entry.findall(text)
    if not entries:
        print("no ModelFile entries found")
        return 1

    cache: dict[str, dict] = {}
    bad = 0
    for filename, repo, remote, declared in entries:
        declared = int(declared.replace("_", ""))
        if repo not in cache:
            try:
                cache[repo] = api(repo)
            except Exception as exc:  # noqa: BLE001
                print(f"FAIL {repo}: {exc}")
                bad += 1
                continue
        sizes = {s["rfilename"]: (s.get("size") or 0) for s in cache[repo].get("siblings", [])}
        if remote not in sizes:
            print(f"FAIL {repo}/{remote}: 404 (not in repo)")
            bad += 1
            continue
        actual = sizes[remote]
        drift = abs(actual - declared) / max(1, declared)
        flag = "ok  " if drift < 0.02 else "WARN"
        if drift >= 0.02:
            bad += 1
        print(f"{flag} {filename:44} declared={declared/1048576:8.1f}MB "
              f"actual={actual/1048576:8.1f}MB drift={drift*100:5.1f}%  ({repo})")
    print()
    if bad:
        print(f"{bad} entr(ies) need attention")
        return 1
    print("all model URLs resolve with expected sizes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
