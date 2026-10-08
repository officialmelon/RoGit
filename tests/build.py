#!/usr/bin/env python3
"""
Bundles src/server, the Roblox mock and a test file into tests/_run.lua, runnable with the Luau CLI:

    python3 tests/build.py tests/merge_test.lua && luau tests/_run.lua
"""
import glob
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(os.path.dirname(here), "src", "server")

out = ["SRC_ROOT = %r" % root, "SOURCES = {}"]
for path in sorted(glob.glob(root + "/**/*", recursive=True)):
    if os.path.isfile(path) and path.endswith((".lua", ".luau")):
        with open(path) as f:
            source = f.read()
        assert "]=====]" not in source
        out.append("SOURCES[%r] = [=====[%s]=====]" % (path, source))

with open(os.path.join(here, "harness.lua")) as f:
    out.append(f.read())
with open(sys.argv[1]) as f:
    out.append(f.read())

with open(os.path.join(here, "_run.lua"), "w") as f:
    f.write("\n".join(out))
