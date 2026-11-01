package main

import (
	"encoding/json"
	"math/rand"
	"sync"
	"time"

	"github.com/gorilla/websocket"
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

type Match struct {
	id   string
	seed int64

	mu       sync.Mutex
	conns    [2]*websocket.Conn
	writeMu  [2]sync.Mutex // gorilla allows only one writer per conn at a time
	joined   int
	nextTurn int
	pending  map[int]*[2][]json.RawMessage
	got      map[int]*[2]bool
	ended    bool
}

type Server struct {
	mu          sync.Mutex
	matches     map[string]*Match
	waiting     *Match // match with one player, waiting for a second
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
