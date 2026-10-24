#!/usr/bin/env python3
"""Regenerate App/Info.plist from project.yml's `info.properties` intent.

XcodeGen would normally synthesise the plist; we keep an explicit checked-in
copy so the file is readable/diffable and so the build works even if the
`info:` block is dropped.
"""
import plistlib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PLIST = ROOT / "App" / "Info.plist"

if not PLIST.exists():
    sys.exit("App/Info.plist missing")

with PLIST.open("rb") as fh:
    data = plistlib.load(fh)

required = [
    "CFBundleIdentifier", "CFBundleExecutable", "CFBundleName",
    "CFBundlePackageType", "CFBundleShortVersionString", "CFBundleVersion",
    "UILaunchScreen", "LSRequiresIPhoneOS",
]
missing = [k for k in required if k not in data]
if missing:
    sys.exit(f"Info.plist missing keys: {missing}")

ent = plistlib.loads((ROOT / "App" / "App.entitlements").read_bytes())
for key in ("com.apple.developer.kernel.increased-memory-limit",
            "com.apple.developer.kernel.extended-virtual-addressing"):
    if ent.get(key) is not True:
        sys.exit(f"entitlement {key} must be true (otherwise the app is jetsam-killed on load)")

print("info.plist + entitlements OK")
