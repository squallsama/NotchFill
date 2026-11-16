#!/usr/bin/env python3
"""Make a hardened-runtime game load NotchFillHook (for games where DYLD_INSERT_LIBRARIES
does not work). This CHANGES THE GAME'S FILES, so it always makes a backup first.

    scripts/patch-game.py patch   "/Applications/Some Game.app" [--hook PATH]
    scripts/patch-game.py restore "/Applications/Some Game.app"
    scripts/patch-game.py status  "/Applications/Some Game.app"

What `patch` does, for the app and every app inside it whose executable has the hardened
runtime without both `allow-dyld-environment-variables` and `disable-library-validation`:
  1. Back up the executable and _CodeSignature to
     ~/Library/Application Support/NotchFill/backups/<bundle id>/
  2. Copy the hook to ~/Library/Application Support/NotchFill/libNotchFillHook.dylib.
  3. Add LC_LOAD_WEAK_DYLIB for it to every slice of the executable (weak: if the file is
     ever missing, the game still starts, just without the hook).
  4. Re-sign that .app ad-hoc with its own entitlements (plus disable-library-validation,
     so a library from another signer may load) and the hardened runtime.
A game update or "verify files" in Steam replaces the patched file; run `patch` again.
"""
import argparse
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile

SUPPORT = os.path.expanduser("~/Library/Application Support/NotchFill")
HOOK_DEST = os.path.join(SUPPORT, "libNotchFillHook.dylib")
BACKUPS = os.path.join(SUPPORT, "backups")

FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF
MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_LOAD_WEAK_DYLIB = 0x80000018
DYLIB_CMDS = {0xC, 0x80000018, 0x8000001F, 0x80000023}  # LOAD, WEAK, REEXPORT, LAZY


def replace_file(dest, data=None, source=None):
    """Write a new file and rename it over `dest`. Never rewrite a signed binary in place:
    the kernel caches the signature per file (inode) and kills the next launch."""
    tmp = dest + ".notchfill-tmp"
    if source is not None:
        shutil.copy2(source, tmp)
    else:
        with open(tmp, "wb") as f:
            f.write(data)
        shutil.copymode(dest, tmp)
    os.replace(tmp, dest)


def run(*cmd, check=True):
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


def bundle_id(app):
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    return info.get("CFBundleIdentifier") or os.path.basename(app), info["CFBundleExecutable"]


def entitlements(exe):
    out = subprocess.run(["codesign", "-d", "--entitlements", ":-", exe], capture_output=True).stdout
    try:
        return plistlib.loads(out) if out.strip() else {}
    except Exception:
        return {}


def is_hardened(exe):
    info = run("codesign", "-dv", exe, check=False).stderr
    flags = next((l for l in info.splitlines() if "flags=" in l), "")
    if "runtime" not in flags:
        return False
    # DYLD_INSERT_LIBRARIES needs both: dyld variables allowed, and library validation off
    # (the hook is signed by another team).
    ents = entitlements(exe)
    return not (ents.get("com.apple.security.cs.allow-dyld-environment-variables", False)
                and ents.get("com.apple.security.cs.disable-library-validation", False))


def targets(app):
    """The app and nested apps (wrappers) whose executable blocks DYLD_INSERT_LIBRARIES."""
    found = []
    for root, dirs, _ in os.walk(app):
        if root.count(os.sep) - app.count(os.sep) > 6:
            dirs[:] = []
            continue
        for d in list(dirs):
            if d.endswith(".app"):
                found.append(os.path.join(root, d))
    result = []
    for a in [app] + found:
        try:
            _, exe_name = bundle_id(a)
        except Exception:
            continue
        exe = os.path.join(a, "Contents", "MacOS", exe_name)
        if os.path.isfile(exe) and is_hardened(exe):
            result.append((a, exe))
    return result


# --- Mach-O --------------------------------------------------------------------------

def slices(data):
    magic = struct.unpack(">I", data[:4])[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        n = struct.unpack(">I", data[4:8])[0]
        out = []
        for i in range(n):
            if magic == FAT_MAGIC:
                _, _, off, size, _ = struct.unpack(">iiIII", data[8 + i * 20: 28 + i * 20])
            else:
                _, _, off, size, _, _ = struct.unpack(">iiQQII", data[8 + i * 32: 40 + i * 32])
            out.append((off, size))
        return out
    return [(0, len(data))]


def dylib_paths(data, off):
    magic, _, _, _, ncmds, sizeofcmds, _, _ = struct.unpack("<IiiIIIII", data[off:off + 32])
    if magic != MH_MAGIC_64:
        raise ValueError("only 64-bit Mach-O is supported")
    p, paths = off + 32, []
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", data[p:p + 8])
        if cmd in DYLIB_CMDS:
            name_off = struct.unpack("<I", data[p + 8:p + 12])[0]
            paths.append(data[p + name_off:p + size].split(b"\0")[0].decode())
        p += size
    return paths


def add_weak_dylib(data, off, path):
    magic, cpu, sub, ftype, ncmds, sizeofcmds, flags, res = struct.unpack("<IiiIIIII", data[off:off + 32])
    end = off + 32 + sizeofcmds
    # First byte of section data: the load commands may grow up to there.
    p, first = off + 32, None
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", data[p:p + 8])
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack("<I", data[p + 64:p + 68])[0]
            for s in range(nsects):
                sp = p + 72 + s * 80
                sect_off = struct.unpack("<I", data[sp + 48:sp + 52])[0]
                if sect_off:
                    first = sect_off if first is None else min(first, sect_off)
        p += size
    name = path.encode() + b"\0"
    cmdsize = (24 + len(name) + 7) & ~7
    if first is None or off + first - end < cmdsize:
        raise ValueError("not enough free space after the load commands")
    if any(b != 0 for b in data[end:end + cmdsize]):
        raise ValueError("space after the load commands is not empty")
    lc = struct.pack("<IIIIII", LC_LOAD_WEAK_DYLIB, cmdsize, 24, 2, 0, 0) + name
    lc += b"\0" * (cmdsize - len(lc))
    data[end:end + cmdsize] = lc
    data[off:off + 32] = struct.pack("<IiiIIIII", magic, cpu, sub, ftype, ncmds + 1, sizeofcmds + cmdsize, flags, res)


# --- Commands -----------------------------------------------------------------------

def patch(app, hook):
    found = targets(app)
    if not found:
        print("Nothing to patch: no hardened executable that blocks the hook.")
        return
    os.makedirs(SUPPORT, exist_ok=True)
    if os.path.exists(HOOK_DEST):
        replace_file(HOOK_DEST, source=hook)
    else:
        shutil.copy2(hook, HOOK_DEST)
    for target_app, exe in found:
        bid, _ = bundle_id(target_app)
        with open(exe, "rb") as f:
            data = bytearray(f.read())
        if all(HOOK_DEST in dylib_paths(data, off) for off, _ in slices(data)):
            print(f"Already patched: {exe}")
            continue
        # One backup per executable path (a wrapper and its inner app may share a bundle id).
        import hashlib
        backup = os.path.join(BACKUPS, f"{bid}-{hashlib.sha1(exe.encode()).hexdigest()[:8]}")
        if not os.path.exists(os.path.join(backup, "executable")):
            os.makedirs(backup, exist_ok=True)
            shutil.copy2(exe, os.path.join(backup, "executable"))
            sig = os.path.join(target_app, "Contents", "_CodeSignature")
            if os.path.isdir(sig):
                shutil.copytree(sig, os.path.join(backup, "_CodeSignature"))
            with open(os.path.join(backup, "path.txt"), "w") as f:
                f.write(exe + "\n")
            print(f"Backup: {backup}")
        ents = entitlements(exe)
        ents["com.apple.security.cs.disable-library-validation"] = True
        for off, _ in slices(data):
            add_weak_dylib(data, off, HOOK_DEST)
        replace_file(exe, data=bytes(data))
        with tempfile.NamedTemporaryFile(suffix=".plist", delete=False) as t:
            plistlib.dump(ents, t)
        try:
            run("codesign", "--force", "--sign", "-", "--options", "runtime",
                "--entitlements", t.name, target_app)
        finally:
            os.unlink(t.name)
        run("codesign", "--verify", "--strict", target_app)
        print(f"Patched and re-signed: {target_app}")


def restore(app):
    """Put back exactly the files named in each backup's path.txt. Never match by bundle id:
    a wrapper app and the game inside it can share one (seen in a real wrapper app)."""
    restored = False
    app_prefix = app.rstrip("/") + "/"
    for name in sorted(os.listdir(BACKUPS)) if os.path.isdir(BACKUPS) else []:
        backup = os.path.join(BACKUPS, name)
        try:
            with open(os.path.join(backup, "path.txt")) as f:
                exe = f.read().strip()
        except OSError:
            continue
        if not exe.startswith(app_prefix) or not os.path.exists(os.path.join(backup, "executable")):
            continue
        target_app = exe.split("/Contents/MacOS/")[0]
        replace_file(exe, source=os.path.join(backup, "executable"))
        sig = os.path.join(target_app, "Contents", "_CodeSignature")
        if os.path.isdir(os.path.join(backup, "_CodeSignature")):
            shutil.rmtree(sig, ignore_errors=True)
            shutil.copytree(os.path.join(backup, "_CodeSignature"), sig)
        ok = run("codesign", "--verify", "--strict", target_app, check=False).returncode == 0
        print(f"Restored {target_app} (original signature {'valid' if ok else 'INVALID'})")
        restored = True
    if not restored:
        print("No backup found for this app.")


def status(app):
    for _, exe in targets(app):
        print(f"hardened (blocks DYLD_INSERT_LIBRARIES): {exe}")
    for a in [app] + [os.path.join(r, d) for r, ds, _ in os.walk(app) for d in ds if d.endswith(".app")]:
        try:
            _, exe_name = bundle_id(a)
            exe = os.path.join(a, "Contents", "MacOS", exe_name)
            with open(exe, "rb") as f:
                data = f.read()
            if any(HOOK_DEST in dylib_paths(data, off) for off, _ in slices(data)):
                print(f"patched: {exe}")
        except Exception:
            continue


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["patch", "restore", "status"])
    ap.add_argument("app")
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--hook", default=os.path.join(here, "..", "build", "NotchFill.app", "Contents", "Resources", "libNotchFillHook.dylib"))
    a = ap.parse_args()
    app = os.path.abspath(a.app.rstrip("/"))
    if a.command == "patch":
        if not os.path.isfile(a.hook):
            sys.exit(f"Hook not found: {a.hook} (run scripts/build-app.sh)")
        patch(app, a.hook)
    elif a.command == "restore":
        restore(app)
    else:
        status(app)


if __name__ == "__main__":
    main()
