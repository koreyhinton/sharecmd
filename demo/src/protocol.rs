//! Messages exchanged with the Go lockstep server.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Reply from `POST /match`.
#[derive(Deserialize)]
pub struct MatchResp {
    pub match_id: String,
    pub player: usize,
}

/// Any message from the server: "start", "turn" or "end".
#[derive(Deserialize)]
pub struct ServerMsg {
    #[serde(rename = "type")]
    pub kind: String,
    /// The server leaves this out when it's 0.
    #[serde(default)]
    pub turn: u32,
    /// "turn": each player's commands. A player with no commands comes through as null.
    /// Kept as raw JSON here so one unknown command can't break the whole turn.
    #[serde(default)]
    pub all: [Option<Vec<Value>>; 2],
    /// "start": your player index.
    #[serde(default)]
    pub player: usize,
    /// "start": shared RNG seed.
    #[serde(default)]
    pub seed: i64,
    /// "end": why the match ended.
    #[serde(default)]
    pub reason: String,
}

/// This player's commands for one turn.
#[derive(Serialize)]
pub struct CmdsMsg<'a> {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub turn: u32,
    pub cmds: &'a [Command],
}

/// A game command. On the wire: {"op":"move","units":[0,1],"x":400000,"y":300000}
/// Positions are in sim units (1/1000 of a pixel), see sim::SCALE.
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Command {
    Move { units: Vec<u32>, x: i32, y: i32 },
}
