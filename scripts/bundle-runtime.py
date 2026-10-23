#!/usr/bin/env python3
"""Embed compiler-provided Swift compatibility libraries before signing a Mac app."""
import pathlib
import re
import shutil
import subprocess
import sys

executable = pathlib.Path(sys.argv[1])
frameworks = pathlib.Path(sys.argv[2])
identity = sys.argv[3]
frameworks.mkdir(parents=True, exist_ok=True)


def rpaths(binary):
    load_commands = subprocess.check_output(["otool", "-l", str(binary)], text=True)
    return re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset \d+\)", load_commands)


def dependencies(binary):
    output = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    return [line.strip().split(" (compatibility", 1)[0] for line in output.splitlines()[1:]]


def developer_path(value):
    return value.startswith(("/Applications/", "/var/run/com.apple.security.cryptexd/",
                             "/private/var/run/com.apple.security.cryptexd/"))


search_paths = rpaths(executable)
queue = [executable]
copied = set()
while queue:
    binary = queue.pop()
    for dependency in dependencies(binary):
        if not dependency.startswith("@rpath/"):
            continue
        name = dependency.removeprefix("@rpath/")
        if name in copied:
            continue
        if "/" in name or not name.startswith("libswift") or not name.endswith(".dylib"):
            raise SystemExit(f"Unrecognized runtime dependency: {dependency}")
        candidates = [pathlib.Path(value) / name for value in search_paths if value.startswith("/")]
        source = next((path for path in candidates if path.is_file()), None)
        if source is None:
            raise SystemExit(f"Cannot locate {dependency} in compiler runtime search paths")
        target = frameworks / name
        shutil.copy2(source, target)
        copied.add(name)
        queue.append(target)
        print(f"Embedded {name}")

for binary in [executable] + [frameworks / name for name in sorted(copied)]:
    for path in rpaths(binary):
        if developer_path(path):
            subprocess.run(["install_name_tool", "-delete_rpath", path, str(binary)], check=True)

relative = "@executable_path/../Frameworks"
if relative not in rpaths(executable):
    subprocess.run(["install_name_tool", "-add_rpath", relative, str(executable)], check=True)
if any(developer_path(path) for path in rpaths(executable)):
    raise SystemExit("A developer-only runtime search path remains")

for name in sorted(copied):
    command = ["codesign", "--force", "--sign", identity, "--options", "runtime"]
    if identity != "-":
        command.append("--timestamp")
    subprocess.run(command + [str(frameworks / name)], check=True)
