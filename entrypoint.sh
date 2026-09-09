#!/usr/bin/env bash
set -euo pipefail

SERVER_NAME="${SERVER_NAME:-My Valheim Server}"
WORLD_NAME="${WORLD_NAME:-Dedicated}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"
SERVER_PORT="${SERVER_PORT:-2456}"
SERVER_PUBLIC="${SERVER_PUBLIC:-1}"
CROSSPLAY="${CROSSPLAY:-false}"
SERVER_PRESET="${SERVER_PRESET:-}"
WORLD_SEED="${WORLD_SEED:-}"
WORLD_MODIFIERS="${WORLD_MODIFIERS:-}"
WORLD_KEYS="${WORLD_KEYS:-}"
SAVE_INTERVAL="${SAVE_INTERVAL:-1800}"
ADMIN_IDS="${ADMIN_IDS:-}"
BANNED_IDS="${BANNED_IDS:-}"
PERMITTED_IDS="${PERMITTED_IDS:-}"
SERVER_ARGS="${SERVER_ARGS:-}"
UPDATE_ON_START="${UPDATE_ON_START:-true}"
VALIDATE_ON_UPDATE="${VALIDATE_ON_UPDATE:-false}"
BACKUPS="${BACKUPS:-true}"
BACKUP_SHORT="${BACKUP_SHORT:-7200}"
BACKUP_LONG="${BACKUP_LONG:-43200}"
STEAM_BETA="${STEAM_BETA:-}"

INSTALL_DIR="${INSTALL_DIR:-/valheim}"
# Overridable so test.sh can exercise the validation without writing to /config.
SAVE_DIR="${SAVE_DIR:-/config}"

# Valheim refuses to boot on a password shorter than 5 chars or one contained in
# the server name. Fail loudly here instead of crash-looping with a cryptic log.
if [[ -n "$SERVER_PASSWORD" ]]; then
  if (( ${#SERVER_PASSWORD} < 5 )); then
    echo "FATAL: SERVER_PASSWORD must be at least 5 characters." >&2
    exit 1
  fi
  if [[ "${SERVER_NAME,,}" == *"${SERVER_PASSWORD,,}"* ]]; then
    echo "FATAL: SERVER_PASSWORD must not be contained in SERVER_NAME." >&2
    exit 1
  fi
elif [[ "$SERVER_PUBLIC" == "1" ]]; then
  echo "FATAL: a public server needs SERVER_PASSWORD set (or set SERVER_PUBLIC=0)." >&2
  exit 1
fi

if [[ "$UPDATE_ON_START" == "true" || ! -x "$INSTALL_DIR/valheim_server.x86_64" ]]; then
  echo "==> Updating Valheim dedicated server (app 896660)"
  update_args=(+force_install_dir "$INSTALL_DIR" +login anonymous +app_update 896660)
  [[ -n "$STEAM_BETA" ]] && update_args+=(-beta "$STEAM_BETA")
  [[ "$VALIDATE_ON_UPDATE" == "true" ]] && update_args+=(validate)

  # An out-of-date steamcmd self-updates and relaunches itself mid-session, which
  # drops the queued +app_update and fails with "Missing configuration". Let it do
  # that in a throwaway invocation first; it's a no-op once already current.
  echo "==> Bootstrapping steamcmd"
  steamcmd +quit > /dev/null 2>&1 || true

  # Steam's CDN fails often enough that a single attempt is a coin flip on a bad day.
  for attempt in 1 2 3; do
    if steamcmd "${update_args[@]}" +quit; then
      break
    fi
    if (( attempt == 3 )); then
      echo "FATAL: steamcmd could not install app 896660 after 3 attempts." >&2
      exit 1
    fi
    echo "==> steamcmd failed (attempt $attempt/3), retrying in 15s..."
    sleep 15
  done
fi

mkdir -p "$SAVE_DIR/worlds_local"

# Access control lists. The server reads these from the savedir root, one ID per
# line. Each is only rewritten when its variable is set, so leaving a variable
# out lets you hand-edit the file in ./data instead.
write_list() { # write_list <filename> <ids>
  local file="$SAVE_DIR/$1" ids="$2"
  # Accept commas or whitespace as separators.
  # shellcheck disable=SC2086 # word splitting on the separators is the point
  printf '%s\n' ${ids//,/ } > "$file"
  echo "==> $1: $(wc -l < "$file") entries"
}
[[ -n "$ADMIN_IDS" ]] && write_list adminlist.txt "$ADMIN_IDS"
[[ -n "$BANNED_IDS" ]] && write_list bannedlist.txt "$BANNED_IDS"
if [[ -n "$PERMITTED_IDS" ]]; then
  write_list permittedlist.txt "$PERMITTED_IDS"
  echo "==> permittedlist is non-empty: ONLY those IDs can join."
fi

# The seed lives inside the world's .fwl and nowhere else — there is no -seed
# flag. Writing the .fwl before first boot pins the seed; the server generates
# the matching .db from it. An existing world is never touched: its seed is
# already baked into terrain that's been played on.
#
# 1.0 stores a world as a worlds_local/<name>/ directory of chunks and removes the
# legacy .fwl when it converts one. Checking only the .fwl would miss a converted
# world, write a fresh seed file beside it, and hand the server what looks like a
# new world — silently discarding the played one on the next restart.
if [[ -n "$WORLD_SEED" ]]; then
  fwl="$SAVE_DIR/worlds_local/$WORLD_NAME.fwl"
  if [[ -e "$fwl" || -d "$SAVE_DIR/worlds_local/$WORLD_NAME" ]]; then
    echo "==> World '$WORLD_NAME' already exists; ignoring WORLD_SEED."
    echo "    To use the seed, pick a new WORLD_NAME or delete data/worlds_local/$WORLD_NAME"
    echo "    and data/worlds_local/$WORLD_NAME.* first."
  else
    echo "==> Creating world '$WORLD_NAME' with seed '$WORLD_SEED'"
    mkworld.sh "$WORLD_NAME" "$WORLD_SEED" "$fwl"
  fi
fi

export LD_LIBRARY_PATH="$INSTALL_DIR/linux64:${LD_LIBRARY_PATH:-}"
export SteamAppId=892970

args=(
  -nographics -batchmode
  -name "$SERVER_NAME"
  -port "$SERVER_PORT"
  -world "$WORLD_NAME"
  -public "$SERVER_PUBLIC"
  -savedir "$SAVE_DIR"
)
[[ -n "$SERVER_PASSWORD" ]] && args+=(-password "$SERVER_PASSWORD")
[[ "$CROSSPLAY" == "true" ]] && args+=(-crossplay)
args+=(-saveinterval "$SAVE_INTERVAL")
if [[ "$BACKUPS" == "true" ]]; then
  args+=(-backups 3 -backupshort "$BACKUP_SHORT" -backuplong "$BACKUP_LONG")
fi

# -preset must precede -modifier: a preset resets every modifier it covers, so
# passing it afterwards would silently wipe the individual overrides.
[[ -n "$SERVER_PRESET" ]] && args+=(-preset "$SERVER_PRESET")

# WORLD_MODIFIERS="combat=hard raids=none" -> -modifier combat hard -modifier raids none
# Same as WORLD_KEYS: a bad name or value is ignored silently by the server, which
# looks identical to "the setting didn't work". Reject it up front.
for pair in $WORLD_MODIFIERS; do
  if [[ "$pair" != *=* ]]; then
    echo "FATAL: WORLD_MODIFIERS entry '$pair' must be name=value." >&2
    exit 1
  fi
  mod_name=${pair%%=*}
  mod_value=${pair#*=}
  case "${mod_name,,}" in
    combat)       valid="veryeasy easy hard veryhard" ;;
    deathpenalty) valid="casual veryeasy easy hard hardcore" ;;
    resources)    valid="muchless less more muchmore most" ;;
    raids)        valid="none muchless less more muchmore" ;;
    portals)      valid="casual hard veryhard" ;;
    *)
      echo "FATAL: unknown WORLD_MODIFIERS name '$mod_name'." >&2
      echo "       Valid names: combat deathpenalty resources raids portals" >&2
      exit 1
      ;;
  esac
  if [[ " $valid " != *" ${mod_value,,} "* ]]; then
    echo "FATAL: invalid value '$mod_value' for modifier '$mod_name'." >&2
    echo "       Valid values: $valid" >&2
    exit 1
  fi
  args+=(-modifier "${mod_name,,}" "${mod_value,,}")
done

# WORLD_KEYS="nobuildcost playerevents" -> -setkey nobuildcost -setkey playerevents
# The server ignores an unknown key without a word of complaint, so a typo would
# quietly mean "toggle never applied". Check against the documented set instead.
for key in $WORLD_KEYS; do
  case "${key,,}" in
    nobuildcost|playerevents|passivemobs|nomap) ;;
    *)
      echo "FATAL: unknown WORLD_KEYS entry '$key'." >&2
      echo "       Valid keys: nobuildcost playerevents passivemobs nomap" >&2
      exit 1
      ;;
  esac
  args+=(-setkey "${key,,}")
done
# shellcheck disable=SC2206
[[ -n "$SERVER_ARGS" ]] && args+=($SERVER_ARGS)

echo "==> Starting '$SERVER_NAME' (world '$WORLD_NAME', port $SERVER_PORT, public $SERVER_PUBLIC)"

# The server only flushes the world to disk on SIGINT. Docker sends SIGTERM, so
# translate it — otherwise every `docker stop` loses progress since the last save.
"$INSTALL_DIR/valheim_server.x86_64" "${args[@]}" &
pid=$!
trap 'echo "==> Stopping, saving world..."; kill -INT "$pid" 2>/dev/null || true' TERM INT

set +e
wait "$pid"
status=$?
# A signal interrupts wait before the child is reaped; wait again for the real status.
if (( status > 128 )); then
  wait "$pid"
  status=$?
fi
echo "==> Server exited ($status)."
exit "$status"
