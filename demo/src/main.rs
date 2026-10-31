//! Two-player lockstep demo for the Go server in the parent folder.
//!
//! Each player has 5 squares. Left-click selects one of yours (shift-click adds,
//! A selects all), right-click moves them. Commands are sent tagged for
//! `turn + delay` and run on both machines on that turn.
//!
//! With --bot (desktop) or ?bot=1 (browser) the client plays random moves by itself
//! and logs a checksum every 50 turns, so two clients can be compared without anyone clicking.

mod net;
mod protocol;
mod sim;

use std::collections::BTreeMap;

use macroquad::prelude::*;
use net::{HttpPost, NetEvent, Socket};
use protocol::{CmdsMsg, Command, MatchResp, ServerMsg};
use sim::{Sim, SCALE, TICK_SECS, WORLD_H, WORLD_W};

/// Sim ticks per lockstep turn: 2 x 50 ms = 100 ms turns.
const TICKS_PER_TURN: u32 = 2;
/// Unit square size, in pixels.
const UNIT_SIZE: f32 = 16.0;
const PLAYER_COLORS: [Color; 2] = [
    Color::new(0.30, 0.55, 1.00, 1.0),
    Color::new(1.00, 0.35, 0.30, 1.0),
];

fn window_conf() -> Conf {
    Conf {
        window_title: "Lockstep demo".to_owned(),
        window_width: WORLD_W,
        window_height: WORLD_H,
        ..Default::default()
    }
}

enum Phase {
    Joining(HttpPost),
    Connecting(Socket),
    Playing(Box<Game>),
    Ended(String),
}

#[macroquad::main(window_conf)]
async fn main() {
    let cfg = net::config();
    info!("server {} delay {}", cfg.server, cfg.delay);
    let mut phase = Phase::Joining(net::post(&format!("{}/match", cfg.server)));

    loop {
        phase = update(phase, &cfg);
        draw(&phase);
        next_frame().await;
    }
}

fn update(phase: Phase, cfg: &net::Config) -> Phase {
    match phase {
        Phase::Joining(mut req) => match req.try_recv() {
            None => Phase::Joining(req),
            Some(Err(e)) => Phase::Ended(format!("Couldn't join a match: {e}")),
            Some(Ok(body)) => match serde_json::from_str::<MatchResp>(&body) {
                Err(e) => Phase::Ended(format!("Bad /match response: {e}")),
                Ok(m) => {
                    let url = format!("{}/ws?match={}&player={}", net::ws_url(&cfg.server), m.match_id, m.player);
                    info!("joined match {} as player {}", m.match_id, m.player);
                    Phase::Connecting(Socket::connect(&url))
                }
            },
        },

        Phase::Connecting(mut sock) => {
            while let Some(ev) = sock.try_recv() {
                match ev {
                    NetEvent::Closed(reason) => return Phase::Ended(reason),
                    NetEvent::Open => {}
                    NetEvent::Text(t) => match serde_json::from_str::<ServerMsg>(&t) {
                        // Anything queued after "start" stays in the socket for the game to read.
                        Ok(m) if m.kind == "start" => {
                            return Phase::Playing(Box::new(Game::new(sock, m.player, m.seed, cfg.delay, cfg.bot)))
                        }
                        Ok(m) if m.kind == "end" => return Phase::Ended(m.reason),
                        _ => {}
                    },
                }
            }
            Phase::Connecting(sock)
        }

        Phase::Playing(mut game) => match game.update() {
            Ok(()) => Phase::Playing(game),
            Err(reason) => Phase::Ended(reason),
        },

        ended @ Phase::Ended(_) => ended,
    }
}

struct Game {
    sock: Socket,
    me: usize,
    delay: u32,
    sim: Sim,
    prev: Vec<(i32, i32)>, // positions before the last tick, for smooth drawing
    tick: u32,
    turn: u32,
    acc: f32, // real time not yet simulated
    next_send: u32,
    confirmed: BTreeMap<u32, [Vec<Command>; 2]>, // turns from the server, not yet run
    outbox: Vec<Command>,                        // typed this turn, goes out at the next turn boundary
    selected: Vec<u32>,
    marker: Option<(Vec2, f64)>, // last right-click, for instant feedback
    stalled_since: Option<f64>,
    bot: Option<Bot>,
}

/// Issues random moves for testing. It only produces commands, which go through
/// lockstep like a player's clicks, so its randomness doesn't need to be shared.
struct Bot {
    rng: u64,
    next_at: f64,
}

impl Bot {
    fn rand(&mut self, n: u32) -> u32 {
        // xorshift64
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 7;
        self.rng ^= self.rng << 17;
        (self.rng % n as u64) as u32
    }
}

impl Game {
    fn new(sock: Socket, me: usize, seed: i64, delay: u32, bot: bool) -> Game {
        let sim = Sim::new(seed);
        let mut g = Game {
            sock,
            me,
            delay,
            prev: sim.positions(),
            sim,
            tick: 0,
            turn: 0,
            acc: 0.0,
            next_send: 0,
            confirmed: BTreeMap::new(),
            outbox: Vec::new(),
            selected: Vec::new(),
            marker: None,
            stalled_since: None,
            bot: bot.then(|| Bot { rng: 0x2545F4914F6CDD1D ^ (me as u64 + 1), next_at: 0.0 }),
        };
        // Prime the pipeline: turns 0..delay-1 can't hold any commands, but the
        // server still needs them from both players before it releases them.
        while g.next_send < delay {
            g.send_turn(&[]);
        }
        info!("match started, player {} seed {}", me, seed);
        g
    }

    fn send_turn(&mut self, cmds: &[Command]) {
        let msg = CmdsMsg { kind: "cmds", turn: self.next_send, cmds };
        self.sock.send(&serde_json::to_string(&msg).unwrap());
        self.next_send += 1;
    }

    /// One frame. Returns Err(reason) when the match is over.
    fn update(&mut self) -> Result<(), String> {
        while let Some(ev) = self.sock.try_recv() {
            match ev {
                NetEvent::Text(t) => {
                    let msg: ServerMsg = match serde_json::from_str(&t) {
                        Ok(m) => m,
                        Err(e) => {
                            warn!("bad message from server: {e}");
                            continue;
                        }
                    };
                    match msg.kind.as_str() {
                        "turn" => {
                            self.confirmed.insert(msg.turn, parse_cmds(msg.all));
                        }
                        "end" => return Err(msg.reason),
                        _ => {}
                    }
                }
                NetEvent::Closed(reason) => return Err(reason),
                NetEvent::Open => {}
            }
        }

        self.handle_input();
        self.run_bot();

        // Fixed-step sim: run as many 50 ms ticks as real time allows.
        self.acc += get_frame_time().min(0.25);
        let mut stalled = false;
        while self.acc >= TICK_SECS {
            if self.tick % TICKS_PER_TURN == 0 {
                let turn = self.tick / TICKS_PER_TURN;
                // Turn boundary: send what was typed, scheduled `delay` turns ahead.
                if self.next_send == turn + self.delay {
                    let cmds = std::mem::take(&mut self.outbox);
                    self.send_turn(&cmds);
                }
                // Run this turn only once both players' commands for it have arrived.
                let Some(all) = self.confirmed.remove(&turn) else {
                    stalled = true;
                    self.acc = TICK_SECS;
                    break;
                };
                for (player, cmds) in all.iter().enumerate() {
                    for cmd in cmds {
                        self.sim.apply(player, cmd);
                    }
                }
                self.turn = turn;
                if turn % 50 == 0 {
                    info!("turn {} checksum {:08x}", turn, self.sim.checksum());
                }
            }
            self.prev = self.sim.positions();
            self.sim.step();
            self.tick += 1;
            self.acc -= TICK_SECS;
        }
        self.stalled_since = match (stalled, self.stalled_since) {
            (true, None) => Some(get_time()),
            (true, since) => since,
            (false, _) => None,
        };
        Ok(())
    }

    fn handle_input(&mut self) {
        let view = View::current();
        let mouse = view.to_world(mouse_position().into());

        if is_key_pressed(KeyCode::A) {
            self.selected = self.my_units().map(|u| u.id).collect();
        }
        if is_mouse_button_pressed(MouseButton::Left) {
            let shift = is_key_down(KeyCode::LeftShift) || is_key_down(KeyCode::RightShift);
            let hit = self.my_units().find(|u| {
                let p = vec2(u.x as f32, u.y as f32) / SCALE as f32;
                (p - mouse).abs().max_element() <= UNIT_SIZE * 0.75
            });
            match (hit.map(|u| u.id), shift) {
                (Some(id), true) => {
                    if let Some(i) = self.selected.iter().position(|s| *s == id) {
                        self.selected.remove(i);
                    } else {
                        self.selected.push(id);
                    }
                }
                (Some(id), false) => self.selected = vec![id],
                (None, false) => self.selected.clear(),
                (None, true) => {}
            }
        }
        if is_mouse_button_pressed(MouseButton::Right) && !self.selected.is_empty() {
            let x = (mouse.x.clamp(0.0, WORLD_W as f32) * SCALE as f32) as i32;
            let y = (mouse.y.clamp(0.0, WORLD_H as f32) * SCALE as f32) as i32;
            self.outbox.push(Command::Move { units: self.selected.clone(), x, y });
            // Show the click right away. The units start moving `delay` turns later.
            self.marker = Some((mouse, get_time()));
        }
    }

    fn run_bot(&mut self) {
        let Some(bot) = self.bot.as_mut() else { return };
        if get_time() < bot.next_at {
            return;
        }
        bot.next_at = get_time() + 0.3 + bot.rand(700) as f64 / 1000.0;
        let mine: Vec<u32> = self.sim.units.iter().filter(|u| u.owner == self.me).map(|u| u.id).collect();
        let count = 1 + bot.rand(mine.len() as u32) as usize;
        let start = bot.rand(mine.len() as u32) as usize;
        let units = (0..count).map(|i| mine[(start + i) % mine.len()]).collect();
        let x = (40 + bot.rand(WORLD_W as u32 - 80)) as i32 * SCALE;
        let y = (40 + bot.rand(WORLD_H as u32 - 80)) as i32 * SCALE;
        self.outbox.push(Command::Move { units, x, y });
    }

    fn my_units(&self) -> impl Iterator<Item = &sim::Unit> {
        let me = self.me;
        self.sim.units.iter().filter(move |u| u.owner == me)
    }

    fn draw(&self) {
        let view = View::current();
        let alpha = (self.acc / TICK_SECS).clamp(0.0, 1.0);

        for (u, prev) in self.sim.units.iter().zip(&self.prev) {
            // Draw between the last two sim states so motion is smooth at any frame rate.
            let x = prev.0 as f32 + (u.x - prev.0) as f32 * alpha;
            let y = prev.1 as f32 + (u.y - prev.1) as f32 * alpha;
            let p = view.to_screen(vec2(x, y) / SCALE as f32);
            let size = UNIT_SIZE * view.scale;
            let selected = self.selected.contains(&u.id);

            if selected && (u.tx, u.ty) != (u.x, u.y) {
                let t = view.to_screen(vec2(u.tx as f32, u.ty as f32) / SCALE as f32);
                draw_line(p.x, p.y, t.x, t.y, 1.0, Color::new(1.0, 1.0, 1.0, 0.25));
            }
            draw_rectangle(p.x - size / 2.0, p.y - size / 2.0, size, size, PLAYER_COLORS[u.owner]);
            if selected {
                draw_rectangle_lines(p.x - size / 2.0 - 3.0, p.y - size / 2.0 - 3.0, size + 6.0, size + 6.0, 2.0, WHITE);
            }
        }

        if let Some((pos, at)) = self.marker {
            let age = (get_time() - at) as f32;
            if age < 0.5 {
                let p = view.to_screen(pos);
                draw_circle_lines(p.x, p.y, (14.0 - age * 20.0) * view.scale, 2.0, Color::new(0.4, 1.0, 0.4, 1.0 - age * 2.0));
            }
        }

        let color = if self.me == 0 { "blue" } else { "red" };
        let hud = format!(
            "You are player {} ({color})   turn {}   delay {} turns   checksum {:08x}",
            self.me, self.turn, self.delay, self.sim.checksum()
        );
        draw_text(&hud, 10.0, 22.0, 20.0, WHITE);
        draw_text(
            "Left-click: select   Shift-click: add   A: select all   Right-click: move",
            10.0,
            screen_height() - 12.0,
            18.0,
            GRAY,
        );

        // Only show the wait message if it lasts long enough to notice.
        if let Some(since) = self.stalled_since {
            if get_time() - since > 0.15 {
                draw_centered("Waiting for other player...", screen_height() / 2.0, 30.0, YELLOW);
            }
        }
    }
}

/// Turns the server's raw JSON into commands. Anything unknown (like the Go demo
/// client's {"cmd":"..."}) is skipped the same way on both machines.
fn parse_cmds(all: [Option<Vec<serde_json::Value>>; 2]) -> [Vec<Command>; 2] {
    all.map(|list| {
        list.unwrap_or_default()
            .into_iter()
            .filter_map(|v| match serde_json::from_value::<Command>(v.clone()) {
                Ok(c) => Some(c),
                Err(_) => {
                    warn!("skipping unknown command {v}");
                    None
                }
            })
            .collect()
    })
}

fn draw(phase: &Phase) {
    clear_background(Color::new(0.06, 0.07, 0.09, 1.0));
    let view = View::current();
    draw_rectangle(
        view.offset.x,
        view.offset.y,
        WORLD_W as f32 * view.scale,
        WORLD_H as f32 * view.scale,
        Color::new(0.11, 0.13, 0.16, 1.0),
    );

    let mid = screen_height() / 2.0;
    match phase {
        Phase::Joining(_) => draw_centered("Joining a match...", mid, 30.0, WHITE),
        Phase::Connecting(_) => draw_centered("Waiting for an opponent...", mid, 30.0, WHITE),
        Phase::Playing(game) => game.draw(),
        Phase::Ended(reason) => {
            draw_centered("Match over", mid - 20.0, 34.0, WHITE);
            draw_centered(reason, mid + 16.0, 22.0, GRAY);
        }
    }
}

fn draw_centered(text: &str, y: f32, size: f32, color: Color) {
    let w = measure_text(text, None, size as u16, 1.0).width;
    draw_text(text, (screen_width() - w) / 2.0, y, size, color);
}

/// Maps the 800x600 world onto the window, keeping its shape (the browser canvas can be any size).
struct View {
    scale: f32,
    offset: Vec2,
}

impl View {
    fn current() -> View {
        let scale = (screen_width() / WORLD_W as f32).min(screen_height() / WORLD_H as f32);
        let offset = vec2(
            (screen_width() - WORLD_W as f32 * scale) / 2.0,
            (screen_height() - WORLD_H as f32 * scale) / 2.0,
        );
        View { scale, offset }
    }

    fn to_screen(&self, world: Vec2) -> Vec2 {
        self.offset + world * self.scale
    }

    fn to_world(&self, screen: Vec2) -> Vec2 {
        (screen - self.offset) / self.scale
    }
}
