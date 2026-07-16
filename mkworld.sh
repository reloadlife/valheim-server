#!/usr/bin/env bash
# Write a Valheim .fwl (world metadata) file with a chosen seed.
#
# The dedicated server has no -seed flag: the seed lives only inside the .fwl,
# which the client normally writes at world-creation time. Given a .fwl the
# server generates the matching .db itself on first load, so writing this one
# small file is enough to pin a seed on a fresh server.
#
# Layout is community reverse-engineered (Iron Gate documents none of it), all
# little-endian:
#   int32  length of everything that follows
#   int32  worldVersion
#   int8   name length + name bytes
#   int8   seed length + seed bytes
#   int32  seedValue   (.NET GetStableHashCode of the seed string)
#   int64  uid         (random)
#   int32  worldGenVersion
#
# ponytail: pinned to worldVersion 26, which predates world modifiers. Newer
# builds append fields after worldGenVersion; the server upgrades an older file
# on load, which is why writing the old version stays forward-compatible.
# Re-verify against a client-made .fwl if a future build ever ignores the seed.
set -euo pipefail

usage() { echo "usage: mkworld.sh <world-name> <seed> <output.fwl>" >&2; exit 2; }
[[ $# -eq 3 ]] || usage

name=$1
seed=$2
out=$3

# Client-enforced limits. The server is laxer, but staying inside them keeps the
# world loadable by a normal client too.
(( ${#name} >= 1 && ${#name} <= 20 )) || { echo "mkworld: world name must be 1-20 chars" >&2; exit 1; }
(( ${#seed} >= 1 && ${#seed} <= 10 )) || { echo "mkworld: seed must be 1-10 chars" >&2; exit 1; }
[[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "mkworld: world name must be alphanumeric/_/-" >&2; exit 1; }
[[ "$seed" =~ ^[A-Za-z0-9]+$ ]] || { echo "mkworld: seed must be alphanumeric" >&2; exit 1; }

WORLD_VERSION=26
WORLD_GEN_VERSION=1

# .NET string.GetStableHashCode — Valheim hashes the seed string with this to get
# the int32 the world generator actually consumes. Must match exactly or the seed
# produces a different map than the same text typed into the client.
stable_hash() {
  local s=$1 num1=5381 num2=5381 i c
  for (( i = 0; i < ${#s}; i += 2 )); do
    printf -v c '%d' "'${s:i:1}"
    num1=$(( ((((num1 << 5) + num1) & 0xFFFFFFFF) ^ c) & 0xFFFFFFFF ))
    (( i + 1 < ${#s} )) || break
    printf -v c '%d' "'${s:i+1:1}"
    num2=$(( ((((num2 << 5) + num2) & 0xFFFFFFFF) ^ c) & 0xFFFFFFFF ))
  done
  echo $(( (num1 + ((num2 * 1566083941) & 0xFFFFFFFF)) & 0xFFFFFFFF ))
}

emit_bytes() { # emit_bytes <value> <byte-count> — little-endian
  local v=$1 n=$2 i fmt=""
  for (( i = 0; i < n; i++ )); do
    fmt+=$(printf '\\x%02x' $(( (v >> (8 * i)) & 0xff )))
  done
  printf "%b" "$fmt"
}

emit_string() { # int8 length prefix + raw bytes
  local s=$1
  emit_bytes ${#s} 1
  printf '%s' "$s"
}

seed_value=$(stable_hash "$seed")
uid=$(( 0x$(head -c 8 /dev/urandom | od -An -tx8 | tr -d ' \n') & 0x7FFFFFFFFFFFFFFF ))

body=$(mktemp)
trap 'rm -f "$body"' EXIT
{
  emit_bytes "$WORLD_VERSION" 4
  emit_string "$name"
  emit_string "$seed"
  emit_bytes "$seed_value" 4
  emit_bytes "$uid" 8
  emit_bytes "$WORLD_GEN_VERSION" 4
} > "$body"

{
  emit_bytes "$(stat -c %s "$body")" 4
  cat "$body"
} > "$out"

echo "mkworld: wrote $out (world '$name', seed '$seed', hash $seed_value)"
