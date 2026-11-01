# sharecmd

A deterministic lockstep relay for a 2-player RTS game, plus a demo client.

For a playable demo game (Rust + macroquad, desktop and browser), see [demo/README.md](demo/README.md).

## Run it

Open three terminals in this folder.

**Terminal 1: server**

```sh
go run main.go models.go -mode server -addr :8080
```

**Terminal 2: player 0**

```sh
go run main.go models.go -mode client -server http://localhost:8080
```

**Terminal 3: player 1**

```sh
go run main.go models.go -mode client -server http://localhost:8080
```

The first client to connect becomes player 0 and the second becomes player 1. When both are connected, the match starts. Type a command in either client and press Enter. Both clients will print it on the same turn.

## Sending a command

At a client prompt, type the command as plain text and press Enter:

```
move 10 20
```

Both clients print it on the same turn:

```
turn 7  p0: {"cmd":"move 10 20"}  (roll 87)
```

Type only the command, not JSON. The client adds the JSON wrapper itself. Over the websocket, the line above is sent as:

```json
{"type":"cmds","turn":7,"cmds":[{"cmd":"move 10 20"}]}
```

## Server options

| Flag | Default | Meaning |
|---|---|---|
| `-addr` | `:8080` | Address to listen on |
| `-join-timeout` | `30s` | Time for both players to connect. If they don't, the match ends. |
| `-max-ahead` | `50` | Furthest a client may send past the current turn. A client that goes further ends the match. Must be larger than the clients' `-delay`. |

Example with a shorter join timeout:

```sh
go run main.go models.go -mode server -addr :8080 -join-timeout 10s
```

## Client options

| Flag | Default | Meaning |
|---|---|---|
| `-server` | `http://localhost:8080` | Server URL |
| `-tick` | `50ms` | Length of one sim tick |
| `-ticks-per-turn` | `2` | Sim ticks per lockstep turn |
| `-delay` | `2` | Input delay in turns (commands typed in turn T run at turn T+delay) |

Example with a longer delay for a slow connection:

```sh
go run main.go models.go -mode client -server http://localhost:8080 -delay 4
```
