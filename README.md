# Game Server

Real-time multiplayer game server built with **Erlang/OTP** and **Cowboy WebSockets**. Designed for a top-down arena game where players choose characters with unique combat abilities, fight each other in a 2000x2000 world, and compete on a global leaderboard.

## Features

- **Real-time multiplayer** via WebSocket with 50ms server tick (20 ticks/sec)
- **4 playable characters** with distinct combat styles: Knight, Mage, Rogue, Golem
- **Server-authoritative state** — all game logic runs on the server
- **Spatial indexing** with hash grid for efficient proximity queries
- **Delta compression** — only changed fields are sent each tick, reducing bandwidth
- **Graceful reconnection** — 5-second grace period preserves player state on disconnect
- **Ping/pong heartbeat** — server-initiated pings detect dead connections within 5 seconds
- **Leaderboard** — session stats persisted to PostgreSQL on disconnect
- **Server-driven configuration** — characters, cosmetics, achievements, and game rules served via REST

## Architecture

```
Erlang/OTP Supervision Tree
│
├── db                  PostgreSQL connection (epgsql)
├── player_registry     ETS table — authoritative player state
├── spatial_index       ETS hash grid (200u cells) — proximity queries
├── web_broadcaster     WebSocket registry, process monitors, disconnect timers
└── game_loop           50ms tick loop + DoT processing every 1s
```

The server follows **Domain-Driven Design**:

```
apps/
├── core/                          Domain + Application + Infrastructure
│   └── src/
│       ├── domain/
│       │   ├── player/            Player aggregate root
│       │   ├── combat/            Combat resolver, character stats
│       │   └── world/             World bounds, spawn points
│       ├── application/
│       │   ├── player/            Join, leave, equip use cases
│       │   ├── combat/            Attack processing, XP, kills
│       │   ├── session/           Game loop (tick + DoT)
│       │   └── leaderboard/       Session recording
│       └── infrastructure/
│           ├── spatial/           ETS registry + spatial index
│           ├── persistence/       PostgreSQL adapter
│           └── websocket/         Achievement evaluator
│
└── web/                           HTTP + WebSocket layer (Cowboy)
    └── src/
        ├── ws_handler.erl         WebSocket handler (per-connection process)
        ├── web_broadcaster.erl    Broadcast, monitors, grace period
        ├── config_handler.erl     GET /api/config
        └── leaderboard_handler.erl GET /api/leaderboard
```

## Requirements

- **Erlang/OTP 26+** (tested with OTP 27)
- **rebar3** (Erlang build tool)
- **PostgreSQL** (for leaderboard persistence)
- **Docker** (optional, for containerized deployment)

## Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/jhuliangr/erlang_free_for_all_game_server
cd erlang_free_for_all_game_server
```

### 2. Configure the database

Edit `config/sys.config` with your PostgreSQL credentials:

```erlang
{core, [
  {db, [
    {host, "localhost"},
    {port, 5432},
    {username, "postgres"},
    {password, "your_password"},
    {database, "game_db"},
    {ssl, false}
  ]}
]}
```

The leaderboard table is created automatically on startup.

### 3. Run locally

```bash
rebar3 shell
```

The server starts on port **8200** by default (configurable in `config/sys.config`).

### 4. Run with Docker

```bash
docker compose up --build
```

Exposes port **8080** on the host, mapped to **8200** inside the container.

## API Reference

### WebSocket — `ws://host:8200/ws`

#### Client Messages

| Type    | Payload                                        | Description            |
| ------- | ---------------------------------------------- | ---------------------- |
| `join`  | `{ name, character?, playerId? }`              | Join or reconnect      |
| `move`  | `{ dx, dy }`                                   | Incremental movement   |
| `attack`| `{ angle }`                                    | Attack in a direction  |
| `equip` | `{ slot: "skin"\|"weapon"\|"character", itemId }` | Equip a cosmetic    |

#### Server Messages

| Type           | Description                                                  |
| -------------- | ------------------------------------------------------------ |
| `welcome`      | Response to join — includes `playerId` and full player state |
| `state_update` | Every 50ms — delta diffs of nearby players + `removed` list  |
| `combat_event` | Hit event with `attackerId`, `defenderId`, `damage`          |
| `error`        | Error with `reason`                                          |

#### Reconnection

Send `join` with the `playerId` received in the original `welcome` message. If the player is still within the 5-second grace period, their full state (position, HP, level, kills) is preserved.

### REST Endpoints

| Endpoint            | Method | Description                                        |
| ------------------- | ------ | -------------------------------------------------- |
| `/api/config`       | GET    | Game configuration: characters, skins, achievements, rules |
| `/api/leaderboard`  | GET    | Global ranking. Query: `?limit=N` (default 50, max 100)   |

## Characters

| Stat        | Knight       | Mage               | Rogue        | Golem         |
| ----------- | ------------ | ------------------- | ------------ | ------------- |
| HP          | 100          | 80                  | 80           | 120           |
| Damage      | 10           | DoT: 3/s for 5s     | 7            | 20            |
| Range       | 150u         | 200u                | 80u          | 150u          |
| Knockback   | 50u          | 30u                 | 0            | 150u          |
| Cooldown    | 334ms (3/s)  | 1000ms (1/s)        | 0ms (no cap) | 2000ms (0.5/s)|

Instant damage scales with level: `base * (1 + 0.15 * (level - 1))`. Mage DoT stacks on repeated hits.

## Testing

```bash
rebar3 eunit      # Unit tests (player, combat, spatial index)
rebar3 ct         # Common Test integration suites
rebar3 dialyzer   # Static type analysis
```

## Tech Stack

| Component      | Technology                      |
| -------------- | ------------------------------- |
| Runtime        | Erlang/OTP                      |
| HTTP/WebSocket | Cowboy 2.10                     |
| JSON           | jsx 3.1                         |
| Logging        | Lager 3.9                       |
| Database       | PostgreSQL via epgsql 4.7       |
| Build          | rebar3                          |
| Container      | Docker                          |

## License

This project is provided as-is for educational and personal use.
