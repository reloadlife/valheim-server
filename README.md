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

Everything lives in `.env` — see [`.env.example`](.env.example) for the annotated list.
Apply changes with `docker compose up -d`.

| Variable | Default | What it does |
| --- | --- | --- |
| `SERVER_NAME` | `My Valheim Server` | Name in the server browser. Cannot contain the password. |
| `SERVER_PASSWORD` | — | Required for public servers. Minimum 5 characters. |
| `WORLD_NAME` | `Dedicated` | Save file name. A new value creates a new world. |
| `WORLD_SEED` | — | Seed for a **new** world. See [Seeds](#seeds). |
| `SERVER_PORT` | `2456` | Game port (UDP). Query port is always this + 1. |
| `SERVER_PUBLIC` | `1` | `1` lists it in the community browser, `0` is join-by-IP only. |
| `CROSSPLAY` | `false` | `true` lets Xbox/PlayStation players join via PlayFab. |
| `ADMIN_IDS` | — | SteamID64s that get admin powers. See [Access control](#access-control). |
| `BANNED_IDS` | — | SteamID64s blocked from joining. |
| `PERMITTED_IDS` | — | Allowlist. **Non-empty = everyone else is banned.** |
| `SERVER_PRESET` | — | `casual`, `easy`, `hard`, `hardcore`, `immersive`, `hammer`. |
| `WORLD_MODIFIERS` | — | Per-rule overrides, e.g. `combat=hard raids=none`. |
| `WORLD_KEYS` | — | Toggles: `nobuildcost playerevents passivemobs nomap`. |
| `SAVE_INTERVAL` | `1800` | Seconds between autosaves. |
| `UPDATE_ON_START` | `true` | Pull the latest Steam build on every start. |
| `SERVER_ARGS` | — | Raw extra flags, appended verbatim. |

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
