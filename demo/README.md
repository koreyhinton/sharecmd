# Lockstep demo (Rust + macroquad)

A small 2-player game that uses the Go lockstep server in the parent folder. Each player has 5 squares. The same code builds for desktop and for the browser (WebAssembly), and a desktop player can play a browser player.

Rust 1.90 is pinned in `rust-toolchain.toml`. rustup installs it, plus the wasm target, the first time you build in this folder. Your default Rust is not changed.

## Start the server

From the parent folder:

```sh
go run main.go -mode server -addr :8080
```

## Desktop

Run this in two terminals, one per player:

```sh
cargo run -- --server http://localhost:8080
```

## Browser

```sh
./build-web.sh
python3 -m http.server 8000 -d web
```

Open http://localhost:8000 in two browser tabs.

The page connects to port 8080 on the same host by default. Settings can go in the page URL, for example `http://localhost:8000/?server=http://192.168.1.20:8080&delay=3`.

## Controls

| Input | Action |
|---|---|
| Left-click | Select one of your units |
| Shift-click | Add or remove a unit from the selection |
| A | Select all your units |
| Right-click | Move the selected units |

The green circle appears as soon as you right-click. The units start moving `delay` turns later (200 ms by default), on both screens at the same time.

## Options

| Desktop | Browser URL | Default | Meaning |
|---|---|---|---|
| `--server URL` | `?server=URL` | `http://localhost:8080` | Go server address |
| `--delay N` | `?delay=N` | `2` | Input delay in turns (1 turn = 100 ms) |
| `--bot` | `?bot=1` | off | Play random moves automatically, for testing |

## Checking that both players stay in sync

The top bar shows a checksum of the whole game state. It should match in both windows. Each client also logs it every 50 turns, to the terminal on desktop and the browser console on the web. To test without clicking, run two clients with `--bot` and compare:

```
turn 50 checksum 1341c4f2
turn 100 checksum 2278f7f6
```

## Files

| File | What it does |
|---|---|
| `src/main.rs` | Game loop: lockstep turns, input, drawing |
| `src/sim.rs` | Deterministic sim: integer positions, seeded RNG, no `HashMap` |
| `src/protocol.rs` | JSON messages for the Go server |
| `src/net.rs` | HTTP + websocket. Desktop uses a background thread, browser calls `web/lockstep_net.js` |
| `web/index.html` | Browser page |
| `web/lockstep_net.js` | Browser websocket and HTTP, using the browser's built-in `WebSocket` and `XMLHttpRequest` |
| `build-web.sh` | Builds the `.wasm` and copies macroquad's JS loader files into `web/` |
