# valheim-server

A Valheim dedicated server in Docker. Pulls the server from Steam on start, saves the
world properly on shutdown, and is configured entirely through one `.env` file —
including **the world seed**, which the dedicated server has no built-in way to set.

[![docker](https://github.com/reloadlife/valheim-server/actions/workflows/docker.yml/badge.svg)](https://github.com/reloadlife/valheim-server/actions/workflows/docker.yml)

## Quick start

```bash
git clone https://github.com/reloadlife/valheim-server.git
cd valheim-server
cp .env.example .env
$EDITOR .env          # set SERVER_NAME and SERVER_PASSWORD at minimum
docker compose up -d
docker compose logs -f
```

First boot downloads ~1.5 GB from Steam and takes a few minutes. The server is ready
when the log prints `Game server connected`.

Then open **UDP 2456 and 2457** on your firewall/router and connect from Valheim via
*Join Game → Join IP* using `your.server.ip:2456`.

## Configuration

Everything lives in `.env` — see [`.env.example`](.env.example) for the same list with
inline comments. Apply changes with `docker compose up -d` (`restart` won't re-read
`.env`).

Every variable is optional except `SERVER_PASSWORD`, which a public server requires.
Booleans are the literal strings `true` / `false`.

### Identity

| Variable | Default | What it does |
| --- | --- | --- |
| `SERVER_NAME` | `My Valheim Server` | Name in the server browser. **Cannot contain the password** — the server refuses to boot if it does. |
| `WORLD_NAME` | `Dedicated` | Save file name, and the `.db`/`.fwl` basename under `data/worlds_local/`. A new value creates a brand new world rather than renaming the old one. |
| `WORLD_SEED` | — | Seed for a **new** world only. 1–10 alphanumeric chars. See [Seeds](#seeds). |

### Networking

| Variable | Default | What it does |
| --- | --- | --- |
| `SERVER_PORT` | `2456` | Game port (UDP). |
| `SERVER_QUERY_PORT` | `2457` | Steam query port. **Only publishes the Docker port** — the server hardcodes `SERVER_PORT+1`, so this must equal `SERVER_PORT+1` or the server is unreachable in the browser. |
| `SERVER_PUBLIC` | `1` | `1` lists the server in the community browser, `0` hides it. Visibility only — **not** access control. |
| `CROSSPLAY` | `false` | `true` switches the backend from Steam to PlayFab so Xbox/PlayStation players can join. Changes the ID format in the access lists. |

### Access control

See [Access control](#access-control) for the semantics. IDs are comma or space separated.

| Variable | Default | What it does |
| --- | --- | --- |
| `ADMIN_IDS` | — | SteamID64s granted in-game admin commands. Writes `data/adminlist.txt`. |
| `BANNED_IDS` | — | SteamID64s blocked from joining. Writes `data/bannedlist.txt`. |
| `PERMITTED_IDS` | — | Allowlist. **Non-empty means everyone not listed is banned.** Writes `data/permittedlist.txt`. |

Leave one unset and its file is never touched, so you can hand-edit it instead.

### World rules

| Variable | Default | What it does |
| --- | --- | --- |
| `SERVER_PRESET` | — | Rule preset: `normal`, `casual`, `easy`, `hard`, `hardcore`, `immersive`, `hammer`. Empty = normal. Applied *before* `WORLD_MODIFIERS`, which override it. |
| `WORLD_MODIFIERS` | — | Space-separated `name=value` overrides. See the table below. |
| `WORLD_KEYS` | — | Space-separated boolean toggles. See the table below. |
| `SAVE_INTERVAL` | `1800` | Seconds between world autosaves. |
| `SERVER_ARGS` | — | Raw flags appended verbatim to the server command line, e.g. `-instanceid 1`. Unvalidated escape hatch. |

`WORLD_MODIFIERS` — every valid name and value. Anything else is a startup error:

| Name | Values |
| --- | --- |
| `combat` | `veryeasy`, `easy`, `hard`, `veryhard` |
| `deathpenalty` | `casual`, `veryeasy`, `easy`, `hard`, `hardcore` |
| `resources` | `muchless`, `less`, `more`, `muchmore`, `most` |
| `raids` | `none`, `muchless`, `less`, `more`, `muchmore` |
| `portals` | `casual`, `hard`, `veryhard` |

Each has an implicit "normal" default with no keyword — omit the modifier to get it.
Example: `WORLD_MODIFIERS=combat=hard raids=none portals=casual`

`WORLD_KEYS` — the four documented toggles, matching the client's "Extra modifiers"
checkboxes:

| Key | Effect |
| --- | --- |
| `nobuildcost` | Hammer pieces cost no resources. You still must have discovered a material to build with it. |
| `playerevents` | Raids trigger off each player's own progression instead of server-wide boss kills. |
| `passivemobs` | Enemies don't attack until provoked. |
| `nomap` | No map, no minimap. This is what the `immersive` preset does. |

Example: `WORLD_KEYS=nobuildcost passivemobs`

There is no `noportals` key — that's a legacy global key, replaced by the `portals`
modifier. Both `WORLD_KEYS` and `WORLD_MODIFIERS` are validated at startup, because the
server ignores an unknown key silently and that looks exactly like a setting that
didn't work.

### Updates and backups

| Variable | Default | What it does |
| --- | --- | --- |
| `UPDATE_ON_START` | `true` | Pull the latest Steam build on every container start. `false` pins whatever is installed — but the server still installs on first boot if missing. |
| `VALIDATE_ON_UPDATE` | `false` | Add steamcmd `validate` to verify every file. Slow; turn on only when you suspect a corrupt install. |
| `STEAM_BETA` | — | Opt into a Steam beta branch, e.g. `public-test`. Empty = stable. |
| `BACKUPS` | `true` | Enable the server's own rolling backups (3 kept of each interval). |
| `BACKUP_SHORT` | `7200` | Seconds between short-interval backups. Ignored when `BACKUPS=false`. |
| `BACKUP_LONG` | `43200` | Seconds between long-interval backups. Ignored when `BACKUPS=false`. |

### Paths

Overridable but rarely worth changing — the compose volumes already map them.

| Variable | Default | What it does |
| --- | --- | --- |
| `SAVE_DIR` | `/config` | Worlds and access lists. This is what `./data` mounts onto. |
| `INSTALL_DIR` | `/valheim` | Game install. Backed by a named volume; disposable. |

## Seeds

Valheim's dedicated server has **no `-seed` flag** — the seed lives only inside the
world's `.fwl` metadata file, which the game client normally writes when you create a
world. The usual workaround is to generate the world on your PC and upload the files.

This image skips that: set `WORLD_SEED` and [`mkworld.sh`](mkworld.sh) writes the `.fwl`
itself before first boot. The server generates the matching world from it.

```ini
WORLD_NAME=Midgard
WORLD_SEED=Meadows42
```

Rules worth knowing:

- **Only applies to a brand-new world.** The seed is baked into terrain at creation, so
  an existing `WORLD_NAME` is left alone and the variable is ignored (with a log line).
  To reseed, change `WORLD_NAME` or delete `data/worlds_local/<name>.*`.
- Seed must be 1–10 alphanumeric characters — the same limit the client enforces.
- Leave it empty for a random seed.

The `.fwl` format is community reverse-engineered, not documented by Iron Gate, so CI
boots a real server on every push and asserts it loads a generated world and preserves
the seed. If Steam ever changes the format, the build goes red rather than your world
silently coming out wrong.

## Access control

Set the ID variables in `.env` and restart — the entrypoint writes the list files the
server reads. IDs are comma or space separated.

```ini
ADMIN_IDS=76561198012345678,76561198087654321
BANNED_IDS=76561198099999999
```

- **Admins** get in-game commands (press `F5`): `/kick`, `/ban`, `/save`, `/skiptime`.
- Find your SteamID64 at [steamid.io](https://steamid.io). With `CROSSPLAY=true`,
  console players use the `Platform_ID` form, e.g. `Xbox_2533274801742044`.
- **`PERMITTED_IDS` is an allowlist and it is all-or-nothing**: leave it empty for a
  normal password-protected server. Add even one ID and *everyone not listed is banned*.
  There is no separate on/off switch — non-emptiness is the switch.
- `SERVER_PUBLIC=0` only hides the server from the browser. It is **not** access
  control — anyone with the IP and password still gets in. Use `PERMITTED_IDS` for that.

Leaving a variable unset means that file is never touched, so you can hand-edit
`data/adminlist.txt` instead if you prefer.

## Updating

**A new Valheim release needs no rebuild.** `UPDATE_ON_START=true` means the server
pulls the latest Steam build every time it starts:

```bash
docker compose restart
```

Rebuild the *image* only when the base OS or this repo's scripts change:

```bash
# Manual rebuild from the GitHub UI: Actions -> docker -> Run workflow
gh workflow run docker.yml                          # or from the CLI
gh workflow run docker.yml -f smoke_test=false      # skip the ~6 min boot test

# Then on the server:
docker compose pull && docker compose up -d
```

CI also builds automatically on every push to `main`, on version tags, and weekly so
base image security updates land without a commit.

## Multiple worlds on one host

[`docker-compose.multi.yml`](docker-compose.multi.yml) runs several worlds from a
single compose file, sharing `.env` for the common settings:

```bash
docker compose -f docker-compose.multi.yml up -d
```

**It does not save RAM.** Valheim runs exactly one world per server process, so each
world is its own container at ~2–3 GB. Budget `N × 3 GB` — two worlds want ~8 GB.
Nothing about the process is shareable; what you save is duplicated config, not
memory.

Each world needs its own **UDP port pair** (the server always uses `SERVER_PORT+1`
for Steam queries), so space them 2 apart: `2456/2457`, `2458/2459`. It also needs
its own data directory and its own game install volume.

| World | Ports | Data |
| --- | --- | --- |
| midgard | 2456–2457 | `./data/midgard` |
| vanaheim | 2458–2459 | `./data/vanaheim` |

Add a world by copying a service block and bumping the ports by 2. Note that
`SERVER_PORT` must match the published port by hand — compose can't read a value out
of `environment:` to reuse it.

If RAM is the constraint, run one world and swap `WORLD_NAME` instead; the other
worlds sit on disk costing nothing until you switch back.

## Data and backups

Worlds live in `./data` on the host (`/config` in the container) — that directory is
the only thing you need to back up. The game binaries live in a named volume and are
disposable.

```
data/
├── adminlist.txt
├── bannedlist.txt
├── permittedlist.txt
└── worlds_local/
    ├── Dedicated.fwl     # metadata: name, seed, modifiers
    ├── Dedicated.db      # the actual world
    └── *.old             # rolling backups
```

The server's own backups are on by default (`BACKUPS=true`): one every 2 hours, one
every 12 hours, 3 kept of each.

To restore, stop the server, copy a `.db.old` over the `.db`, and start again. To bring
an existing world in, drop its `.db` and `.fwl` into `data/worlds_local/` and set
`WORLD_NAME` to the filename without the extension. The two files must always travel
together.

## Common operations

```bash
docker compose logs -f              # watch the server
docker compose restart              # restart + update the game
docker compose down                 # stop, saving the world
```

Shutdown is safe: Valheim only writes the world on `SIGINT`, so the entrypoint
translates Docker's `SIGTERM` into one and compose waits 2 minutes for the save.
**Never `docker kill`** — that loses everything since the last autosave.

## Development

```bash
./test.sh              # checks the .fwl writer, no download needed
docker compose build   # after uncommenting `build: .` in docker-compose.yml
```

## Notes

- x86_64 only — Iron Gate ships no ARM build of the dedicated server.
- Budget ~4 GB RAM; the server uses ~2–3 GB with a handful of players.
- No mod loader (BepInEx / Valheim Plus) is installed. Vanilla only.
