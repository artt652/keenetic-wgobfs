#!/usr/bin/env bash
# Cross-test of the module codec (wgobfs.c from the patch) against the real
# wg-obfuscator implementation, in user space: both directions, with and
# without STUN masking, several keys. wg-obfuscator (GPL-3.0) is downloaded
# for the test only and is not part of this repository.
#
#   test/run.sh [wg-obfuscator tag]      default v1.6
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
TAG=${1:-v1.6}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# wgobfs.c / wgobfs.h are new files in the patch: take them straight from it.
python3 - "$ROOT/patches/wgobfs.patch" "$W" <<'EOF'
import re, sys
patch, out = sys.argv[1], sys.argv[2]
cur = None
for line in open(patch, encoding="utf-8"):
    m = re.match(r"^\+\+\+ b/src/(wgobfs\.[ch])$", line.rstrip("\n"))
    if m:
        cur = open(f"{out}/{m.group(1)}", "w", encoding="utf-8")
        continue
    if line.startswith("diff --git"):
        cur = None
        continue
    if cur and line.startswith("+"):
        cur.write(line[1:])
EOF

git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" https://github.com/ClusterM/wg-obfuscator.git "$W/wg-obfuscator"
SRC=$W/wg-obfuscator

gcc -O2 -Wall -I"$HERE/fake" -I"$W" -I"$SRC" -o "$W/codec-test" \
	"$HERE/codec-test.c" "$W/wgobfs.c" "$SRC/obfuscation.c" -lz
for key in 'jnD1j4zRQjv9Unsh7xZfZVTZUHEMO0olJAMqUfpLwIKpSnB4O1RssWAgnMDxlFl6' a 'K3y!' \
	"$(head -c 300 /dev/urandom | base64 -w0 | tr -d '=#+/' | head -c 255)"; do
	"$W/codec-test" "$key" | tail -n 1
done
echo "codec test passed"
