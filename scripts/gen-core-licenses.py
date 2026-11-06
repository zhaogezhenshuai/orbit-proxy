#!/usr/bin/env python3 -I
"""Collects the license of every Go module compiled into the mihomo core, plus Go itself, into
one text file that ships inside Orbit.app (binary distributions must carry these notices).

Usage: gen-core-licenses.py <go binary> <mihomo binary> <GOMODCACHE> <mihomo source dir> <output>
"""
import os
import subprocess
import sys

go, core, modcache, src, out = sys.argv[1:6]
NAMES = ("LICENSE", "LICENCE", "COPYING", "NOTICE", "UNLICENSE")


def escape(path):
    # Module cache paths encode upper-case letters as "!" + lower-case.
    return "".join("!" + c.lower() if c.isupper() else c for c in path)


def license_texts(directory):
    if not os.path.isdir(directory):
        return []
    texts = []
    for name in sorted(os.listdir(directory)):
        if name.upper().startswith(NAMES) and os.path.isfile(os.path.join(directory, name)):
            with open(os.path.join(directory, name), encoding="utf-8", errors="replace") as f:
                texts.append((name, f.read().strip()))
    return texts


info = subprocess.run([go, "version", "-m", core], capture_output=True, text=True, check=True).stdout
modules = []  # (display name, version, directory)
for line in info.splitlines():
    parts = line.strip().split("\t")
    if parts[0] == "dep":
        modules.append([parts[1], parts[2], os.path.join(modcache, escape(parts[1]) + "@" + parts[2])])
    elif parts[0] == "=>" and modules:  # replace directive: the code actually built comes from here
        modules[-1][0] += " (replaced by " + parts[1] + ")"
        modules[-1][1] = parts[2]
        modules[-1][2] = os.path.join(modcache, escape(parts[1]) + "@" + parts[2])

goroot = subprocess.run([go, "env", "GOROOT"], capture_output=True, text=True, check=True).stdout.strip()
goversion = info.splitlines()[0].split(":")[-1].strip()
sections = [("mihomo", "", src), ("Go standard library and runtime", goversion, goroot)]
sections += [tuple(m) for m in modules]

missing = []
with open(out, "w", encoding="utf-8") as f:
    f.write("Licenses of the components compiled into Orbit's mihomo core (Contents/Resources/mihomo).\n")
    f.write("Generated from the binary's embedded module list by scripts/gen-core-licenses.py.\n")
    for name, version, directory in sections:
        texts = license_texts(directory)
        if not texts:
            missing.append(name)
        f.write("\n" + "=" * 78 + "\n" + name + (" " + version if version else "") + "\n" + "=" * 78 + "\n")
        for file_name, text in texts:
            f.write("\n--- " + file_name + " ---\n\n" + text + "\n")
        if not texts:
            f.write("\n(no license file in the module; see its source repository)\n")

print("wrote %s: %d components, %d without a license file%s" % (
    out, len(sections), len(missing), (": " + ", ".join(missing)) if missing else ""))
