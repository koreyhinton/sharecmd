package main

import (
	"encoding/json"
	"math/rand"
	"time"
)

// ---------- Protocol ----------

// Msg is the single wire format used in both directions.
type Msg struct {
	Type   string               `json:"type"`             // "cmds" (client->server), "start", "turn", "end"
	Turn   int                  `json:"turn,omitempty"`   // turn number
	Cmds   []json.RawMessage    `json:"cmds,omitempty"`   // client->server: this player's commands
	All    [2][]json.RawMessage `json:"all,omitempty"`    // server->client: both players' commands, by player index
	Player int                  `json:"player"`           // start: your player index
	Seed   int64                `json:"seed,omitempty"`   // start: shared RNG seed
	Reason string               `json:"reason,omitempty"` // end: why the match ended
}

type MatchResp struct {
	MatchID string `json:"match_id"`
	Player  int    `json:"player"`
}

// ---------- Server ----------

// maxMessage is the largest websocket message the server reads, in bytes.
const maxMessage = 1 << 20

type Match struct {
	id       string
	seed     int64
	joined   int       // players given a slot by POST /match
	deadline time.Time // both players must open their websocket by then

	players  [2]*WsConn // each player's websocket, nil until they connect (WsConn is generated into ws_models.go)
	nextTurn int
	pending  map[int]*[2][]json.RawMessage
	got      map[int]*[2]bool
	reason   string // why the match ended; empty while it's on
}

// Server runs one match at a time.
type Server struct {
	match       *Match // the match players are joining or playing, or nil
	nextID      int
	joinTimeout time.Duration // both players must connect within this long
	maxAhead    int           // furthest a client may send past the current turn
}

// ---------- Client (test/demo) ----------

// Sim is a stand-in for the deterministic game simulation. Everything here must
// depend only on the commands and the shared seed: no wall clock, no map
// iteration order, no unseeded randomness.
type Sim struct {
	rng *rand.Rand
}
