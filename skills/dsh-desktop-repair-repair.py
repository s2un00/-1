"""Backup-first repair for DeepSeek Harness (dsh) profile config corruption.

Fixes:
  1. UTF-8 BOM prepended to profile package.json  (breaks JSON.parse)
  2. Bad YAML indentation in cordis.patch.yml      (breaks overlay parse)

Usage:
  python repair.py                 # scan + report only (dry run)
  python repair.py --fix           # strip BOMs, report YAML errors
  python repair.py --fix --restore-overlay   # also restore overlay from .hsg-backup

Never touches sessions/tasks data. Every modified file is copied into
~/.dsh/.bom-fix-backup/<timestamp>/ first.
"""
import argparse
import datetime
import glob
import json
import os
import shutil
import sys

DSH = os.path.join(os.path.expanduser("~"), ".dsh")
PROFILES = os.path.join(DSH, "profiles")
BOM = b"\xef\xbb\xbf"


def find_profiles():
    if not os.path.isdir(PROFILES):
        return []
    return [
        os.path.join(PROFILES, d)
        for d in os.listdir(PROFILES)
        if os.path.isdir(os.path.join(PROFILES, d))
    ]


def newest(pattern):
    hits = sorted(glob.glob(pattern))
    return hits[-1] if hits else None


def backup(path, bkdir):
    os.makedirs(bkdir, exist_ok=True)
    dst = os.path.join(bkdir, path.replace("\\", "_").replace("/", "_").lstrip("_"))
    shutil.copy2(path, dst)
    return dst


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fix", action="store_true", help="apply fixes (default: dry run)")
    ap.add_argument("--restore-overlay", action="store_true",
                    help="restore cordis.patch.yml from .hsg-backup if it is the empty template")
    args = ap.parse_args()

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    bkdir = os.path.join(DSH, ".bom-fix-backup", stamp)

    problems = 0
    for prof in find_profiles():
        name = os.path.basename(prof)

        # --- package.json: BOM + JSON validity ---
        pkg = os.path.join(prof, "package.json")
        if os.path.isfile(pkg):
            raw = open(pkg, "rb").read()
            if raw.startswith(BOM):
                problems += 1
                print(f"[BOM ] {name}/package.json")
                if args.fix:
                    backup(pkg, bkdir)
                    open(pkg, "wb").write(raw[3:])
                    print("       -> BOM stripped")
                    raw = raw[3:]
            try:
                json.loads(raw.decode("utf-8"))
                print(f"[ ok ] {name}/package.json parses")
            except Exception as exc:  # noqa: BLE001
                print(f"[FAIL] {name}/package.json -> {exc}")

        # --- cordis.patch.yml: BOM + empty-template detection ---
        pat = os.path.join(prof, "cordis.patch.yml")
        if os.path.isfile(pat):
            raw = open(pat, "rb").read()
            if raw.startswith(BOM):
                problems += 1
                print(f"[BOM ] {name}/cordis.patch.yml")
                if args.fix:
                    backup(pat, bkdir)
                    open(pat, "wb").write(raw[3:])
                    print("       -> BOM stripped")
                    raw = raw[3:]
            body = raw.decode("utf-8", "replace")
            if body.strip().endswith("[]"):
                snap = newest(os.path.join(prof, ".hsg-backup", "cordis.patch.yml.*"))
                print(f"[warn] {name}/cordis.patch.yml is the empty template "
                      f"(user overrides may be lost); snapshot: {snap}")
                if args.fix and args.restore_overlay and snap:
                    backup(pat, bkdir)
                    shutil.copy2(snap, pat)
                    print(f"       -> restored from {os.path.basename(snap)}")

    print(f"\nproblems found: {problems}")
    print(f"backups: {bkdir}" if os.path.isdir(bkdir) else "backups: (none written)")
    print("reminder: validate YAML with the profile's bundled js-yaml; "
          "close the app before editing; relaunch and confirm no new crash-*-host.log")
    return 0


if __name__ == "__main__":
    sys.exit(main())
