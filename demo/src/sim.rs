//! The deterministic game simulation.
//!
//! Both clients run this with the same seed and the same commands on the same
//! ticks, so they must end up in exactly the same state. Rules that keep it that way:
//!   - integers only (no f32/f64), positions are in 1/1000 of a pixel
//!   - Vec, not HashMap (HashMap iteration order differs between processes)
//!   - our own RNG with a fixed algorithm, seeded from the server
//!   - no clock, no input, no frame rate: only commands and ticks

use crate::protocol::Command;

/// Sim units per pixel.
pub const SCALE: i32 = 1000;
pub const WORLD_W: i32 = 800;
pub const WORLD_H: i32 = 600;
/// Length of one sim tick (50 ms = 20 ticks per second).
pub const TICK_SECS: f32 = 0.05;

const UNITS_PER_PLAYER: usize = 5;
/// 4 pixels per tick = 80 pixels per second.
const SPEED: i64 = 4 * SCALE as i64;
/// Spacing between units in a group move, in pixels.
const SPACING: i32 = 24;

pub struct Unit {
    pub id: u32,
    pub owner: usize,
    pub x: i32,
    pub y: i32,
    pub tx: i32,
    pub ty: i32,
}

pub struct Sim {
    pub units: Vec<Unit>, // index == id
}

impl Sim {
    pub fn new(seed: i64) -> Sim {
        // Spawn points come from the shared seed, so both players see the same layout.
        let mut rng = Rng(seed as u64);
        let mut units = Vec::new();
        for owner in 0..2 {
            let left = if owner == 0 { 60 } else { WORLD_W - 260 };
            for _ in 0..UNITS_PER_PLAYER {
                let x = (left + rng.below(200) as i32) * SCALE;
                let y = (80 + rng.below((WORLD_H - 140) as u32) as i32) * SCALE;
                units.push(Unit { id: units.len() as u32, owner, x, y, tx: x, ty: y });
            }
        }
        Sim { units }
    }

    /// Applies one command from `player`. Units they don't own are ignored.
    pub fn apply(&mut self, player: usize, cmd: &Command) {
        match cmd {
            Command::Move { units, x, y } => {
                // Clamp first: x and y come from the network, and adding the offset
                // to a huge value would overflow (a crash in debug builds).
                let x = (*x).clamp(0, WORLD_W * SCALE);
                let y = (*y).clamp(0, WORLD_H * SCALE);
                // Cap the list too, so a huge one can't overflow the row offset below.
                let count = units.len().min(self.units.len());
                for (i, id) in units[..count].iter().enumerate() {
                    // Spread a group into a 3-wide grid around the click point.
                    let col = (i % 3) as i32 - 1;
                    let row = (i / 3) as i32;
                    let tx = (x + col * SPACING * SCALE).clamp(0, WORLD_W * SCALE);
                    let ty = (y + row * SPACING * SCALE).clamp(0, WORLD_H * SCALE);
                    if let Some(u) = self.units.get_mut(*id as usize) {
                        if u.owner == player {
                            u.tx = tx;
                            u.ty = ty;
                        }
                    }
                }
            }
        }
    }

    /// Advances one tick.
    pub fn step(&mut self) {
        for u in &mut self.units {
            let dx = (u.tx - u.x) as i64;
            let dy = (u.ty - u.y) as i64;
            let dist = (dx * dx + dy * dy).isqrt();
            if dist <= SPEED {
                u.x = u.tx;
                u.y = u.ty;
            } else {
                u.x += (dx * SPEED / dist) as i32;
                u.y += (dy * SPEED / dist) as i32;
            }
        }
    }

    pub fn positions(&self) -> Vec<(i32, i32)> {
        self.units.iter().map(|u| (u.x, u.y)).collect()
    }

    /// Hash of the whole state. If the two windows ever show different values, they've desynced.
    pub fn checksum(&self) -> u32 {
        let mut h: u32 = 0x811c9dc5; // FNV-1a
        for u in &self.units {
            for v in [u.x, u.y, u.tx, u.ty] {
                for b in v.to_le_bytes() {
                    h = (h ^ b as u32).wrapping_mul(0x01000193);
                }
            }
        }
        h
    }
}

/// SplitMix64. Tiny, fast, and the same on every platform and Rust version.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }

    fn below(&mut self, n: u32) -> u32 {
        (self.next() % n as u64) as u32
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extreme_move_values_dont_panic() {
        let mut sim = Sim::new(1);
        sim.apply(0, &Command::Move { units: vec![0; 300_000], x: i32::MAX, y: i32::MIN });
        let u = &sim.units[0];
        assert!((0..=WORLD_W * SCALE).contains(&u.tx) && (0..=WORLD_H * SCALE).contains(&u.ty));
    }
}
