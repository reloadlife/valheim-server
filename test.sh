#!/usr/bin/env bash
# Checks the .fwl writer without needing the 1.5 GB server download.
# The boot smoke test that proves the real server accepts these files lives in
# .github/workflows/docker.yml.
set -euo pipefail
cd "$(dirname "$0")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { # check <label> <actual> <expected>
  if [[ "$2" == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: got '$2', want '$3'"; fails=$((fails + 1))
  fi
}

# .NET GetStableHashCode vectors. Valheim feeds this hash to the world generator,
# so a drift here means the seed silently produces a different map than the same
# text typed into the game client.
hash_of() { ./mkworld.sh W "$1" "$tmp/h.fwl" | grep -o 'hash [0-9]*' | cut -d' ' -f2; }
check "hash(a)"          "$(hash_of a)"          "372029373"
check "hash(abc)"        "$(hash_of abc)"        "1099313834"
check "hash(valheim)"    "$(hash_of valheim)"    "3466750896"
check "hash(Seed123)"    "$(hash_of Seed123)"    "502027295"
check "hash(0000000000)" "$(hash_of 0000000000)" "454386782"

# Structure: verified byte-for-byte against a file the real server loaded.
./mkworld.sh TestWorld Seed123 "$tmp/t.fwl" > /dev/null
check "file size" "$(stat -c %s "$tmp/t.fwl")" "42"
parsed=$(python3 - "$tmp/t.fwl" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
o = 0
def i32():
    global o; v = struct.unpack_from("<i", d, o)[0]; o += 4; return v
def s():
    global o; n = d[o]; o += 1; v = d[o:o+n].decode(); o += n; return v
length, ver = i32(), i32()
name, seed = s(), s()
sv = i32(); o += 8; gen = i32()
assert length == len(d) - 4, "length prefix mismatch"
assert o == len(d), "trailing bytes"
print(f"{ver}|{name}|{seed}|{sv}|{gen}")
PY
)
check "fwl fields" "$parsed" "26|TestWorld|Seed123|502027295|1"

# Input validation: bad seeds must fail loudly, not write a corrupt world.
for bad in "toolongseed11" "has space" "sym!"; do
  if ./mkworld.sh World "$bad" "$tmp/bad.fwl" >/dev/null 2>&1; then
    echo "FAIL rejects '$bad': accepted it"; fails=$((fails + 1))
  else
    echo "ok   rejects '$bad'"
  fi
done

echo
if [[ $fails -eq 0 ]]; then
  echo "all passed"
else
  echo "$fails failed"
  exit 1
fi
