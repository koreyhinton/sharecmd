# sharecmd

> **Note:** The server code in this project has been rewritten in an imperative style, assembled from bash scripts with the [orc](https://github.com/koreyhinton/orc) library, so the whole program can be read from start to end. The original Go reference implementation is at tag [`v0.1.0`](https://github.com/koreyhinton/sharecmd/tree/v0.1.0) (commit [`df82d3e`](https://github.com/koreyhinton/sharecmd/tree/df82d3e)):
>
> ```sh
> git checkout v0.1.0   # or: git checkout df82d3e
> ```
>
> **Reading the server code in Emacs**
>
> 1. Install [wik-mode](https://github.com/koreyhinton/wik-mode).
> 2. Make the Emacs frame full screen (`M-x toggle-frame-fullscreen`), then split it into two side-by-side portrait windows with `C-x 3`.
> 3. Open `main.sh` (`C-x C-f main.sh`) and turn on wik-mode (`M-x wik-mode`).
> 4. Search for `main(` (`C-s main(`) to jump to the start of the program.
> 5. Read down from there. On a subscript line, such as `` ` ./main-join-accept.sh ${v}jn_ ` ``, press `C-c <down>` to open the subscript and `C-c <up>` to close it.

A deterministic lockstep relay for a 2-player RTS game, plus a demo client.

For a playable demo game (Rust + macroquad, desktop and browser), see [demo/README.md](demo/README.md).

## Build it

`main.go` is generated from `main.sh`. Generate it before running:

```sh
./build.sh
```

This expects the `orc` repo to be checked out next to this one (it reads `../orc/lib/src/main/bash/com/koreyhinton/nsmap`). Run it again whenever you change `main.sh` or any of its `main-*.sh` subscripts.

## Test it

`server_test.go` builds the server, starts it and plays matches against it over websockets. `integration_test.go` runs the server with two real clients, types a command into each, and checks both clients print it for the right player, then closes one client and checks the other exits. Both need `main.go`, so build first:

```sh
./build.sh && go test -race ./...
```

The same checks run on every pull request into `main` (`.github/workflows/test.yml`).

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

The server runs one match at a time. While a match is being played it doesn't take new connections, and once two players have joined, more calls to `POST /match` get `503` until that match is over. Clients must send a `cmds` message every turn, even an empty one, or the match stalls.

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
