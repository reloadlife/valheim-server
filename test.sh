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

# WORLD_KEYS / WORLD_MODIFIERS validation. The server ignores a bad key silently,
# so these guards are the only thing between a typo and a setting that looks
# applied but never was.
#
# entrypoint always ends by failing to exec the (absent) server binary, so a
# nonzero exit proves nothing — grep for the FATAL line the guards actually emit.
mkdir -p "$tmp/stub"
printf '#!/bin/sh\nexit 0\n' > "$tmp/stub/steamcmd"; chmod +x "$tmp/stub/steamcmd"
printf '#!/bin/sh\nexit 0\n' > "$tmp/stub/mkworld.sh"; chmod +x "$tmp/stub/mkworld.sh"

entry_fatal() { # entry_fatal <VAR=value>... -> prints the FATAL line, if any
  env SERVER_PUBLIC=0 SAVE_DIR="$tmp/save" PATH="$tmp/stub:$PATH" "$@" \
    bash ./entrypoint.sh 2>&1 | grep -m1 '^FATAL' || true
}

for bad in "combat=nonsense" "nosuchmod=hard" "combat"; do
  if [[ -n "$(entry_fatal WORLD_MODIFIERS="$bad")" ]]; then
    echo "ok   rejects modifier '$bad'"
  else
    echo "FAIL rejects modifier '$bad': accepted it"; fails=$((fails + 1))
  fi
done
for bad in "noportals" "nocraftcost" "typo"; do
  if [[ -n "$(entry_fatal WORLD_KEYS="$bad")" ]]; then
    echo "ok   rejects key '$bad'"
  else
    echo "FAIL rejects key '$bad': accepted it"; fails=$((fails + 1))
  fi
done

# Positive control: without this, a guard that rejects *everything* would pass
# every check above.
good=$(entry_fatal WORLD_MODIFIERS="combat=hard raids=none" WORLD_KEYS="nobuildcost nomap")
check "accepts valid modifiers and keys" "$good" ""

# A public server with no password is a footgun the server itself reports badly.
pw=$(env SAVE_DIR="$tmp/save" PATH="$tmp/stub:$PATH" SERVER_PUBLIC=1 SERVER_PASSWORD= \
       bash ./entrypoint.sh 2>&1 | grep -c 'needs SERVER_PASSWORD' || true)
check "public server requires a password" "$pw" "1"

echo
if [[ $fails -eq 0 ]]; then
  echo "all passed"
else
  echo "$fails failed"
  exit 1
fi
