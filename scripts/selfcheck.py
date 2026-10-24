#!/usr/bin/env python3
"""Offline sanity checks that don't need a Mac.

Verifies:
  * the vendored C header matches the xcframework's own header
  * every `mirage_*` function the Swift layer calls is declared in that header
  * every declared function actually exists in the shipped static library
  * the two memory entitlements are present and true
  * project.yml / workflow YAML parse
"""
from __future__ import annotations

import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
XCF = ROOT / "Frameworks" / "sdcpp.xcframework" / "ios-arm64"
VENDORED_H = ROOT / "Sources" / "CMirage" / "include" / "MirageC.h"
SWIFT = ROOT / "Sources" / "Mirage" / "Mirage.swift"
LIB = XCF / "libmirage-sdcpp.a"

fails: list[str] = []


def check(cond: bool, msg: str) -> None:
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        fails.append(msg)


print("1. xcframework present")
check(XCF.exists(), "ios-arm64 slice exists")
check(LIB.exists(), "libmirage-sdcpp.a exists")
if not LIB.exists():
    sys.exit("\n".join(fails))

print("2. vendored header matches xcframework header")
ship_h = (XCF / "Headers" / "MirageC.h").read_text()
check(VENDORED_H.read_text() == ship_h,
      "Sources/CMirage/include/MirageC.h is byte-identical to the shipped header")

print("3. Swift -> C calls are declared")
called = set(re.findall(r"\b(mirage_[a-z_]+)\(", SWIFT.read_text()))
declared = set(re.findall(r"\b(mirage_[a-z_]+)\s*\(", ship_h))
types = {"mirage_model_paths", "mirage_gen_params", "mirage_video_params",
         "mirage_image", "mirage_video"}
undeclared = sorted(called - declared - types)
check(not undeclared, f"no undeclared calls (found: {undeclared or 'none'})")

print("4. declared functions exist in the binary")
blob = LIB.read_bytes()
missing = [fn for fn in sorted(declared) if fn.encode() not in blob]
check(not missing, f"all {len(declared)} declared symbols present (missing: {missing or 'none'})")

print("5. entitlements")
ent = plistlib.loads((ROOT / "App" / "App.entitlements").read_bytes())
for key in ("com.apple.developer.kernel.increased-memory-limit",
            "com.apple.developer.kernel.extended-virtual-addressing"):
    check(ent.get(key) is True, key)

print("6. YAML")
try:
    import yaml
except ImportError:
    print("  skip  pyyaml not installed")
else:
    for rel in ("project.yml", ".github/workflows/build-ipa.yml"):
        try:
            yaml.safe_load((ROOT / rel).read_text())
            check(True, rel)
        except Exception as exc:  # noqa: BLE001
            check(False, f"{rel}: {exc}")

print()
if fails:
    print(f"{len(fails)} check(s) failed")
    sys.exit(1)
print("all checks passed")
