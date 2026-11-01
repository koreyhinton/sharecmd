#!/bin/bash
v=${1:-mn_}
# maps
export ${v}hdl_ws_R=r
export ${v}hdl_ws_W=w
export ${v}hdl_mtch_R=r
export ${v}hdl_mtch_W=w

cat << EOF
// Deterministic lockstep relay for a 2-player RTS.
//
// Server: go run . -mode server -addr :8080
// Client: go run . -mode client -server http://localhost:8080 [-tick 50ms -ticks-per-turn 2 -delay 2]
//
// Flow:
//  1. Client POSTs /match (via resty) and gets {match_id, player}.
//  2. Client opens a websocket at /ws?match=ID&player=N.
//  3. When both players are connected the server sends "start" with a shared RNG seed.
//  4. Every turn, each client sends its commands for that turn (an empty list is fine).
//  5. Once both players have sent turn N, the server sends both command lists for
//     turn N to both clients, always in player order. Both sims run the same inputs
//     in the same order, so they stay in sync.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/go-resty/resty/v2"
	"github.com/gorilla/websocket"
)

// ---------- Server ----------

// remove drops a finished match. Safe to call more than once.
func (s *Server) remove(m *Match) {
	s.mu.Lock()
	delete(s.matches, m.id)
	if s.waiting == m {
		s.waiting = nil
	}
	s.mu.Unlock()
}

var upgrader = websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}

func (m *Match) send(p int, msg Msg) {
	m.mu.Lock()
	c := m.conns[p]
	over := m.ended && msg.Type != "end"
	m.mu.Unlock()
	if c == nil || over {
		return // no one to send to, or the match is over and only "end" still goes out
	}
	m.writeMu[p].Lock()
	defer m.writeMu[p].Unlock()
	c.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if err := c.WriteJSON(msg); err != nil {
		log.Printf("[%s] write to p%d: %v", m.id, p, err)
	}
}

// readLoop handles one player's messages until they disconnect or break the
// rules, and returns the reason the match should end.
func (m *Match) readLoop(player int, conn *websocket.Conn, maxAhead int) string {
	for {
		var msg Msg
		if err := conn.ReadJSON(&msg); err != nil {
			return fmt.Sprintf("player %d disconnected", player)
		}
		if msg.Type != "cmds" {
			continue
		}

		m.mu.Lock()
		if msg.Turn < m.nextTurn {
			m.mu.Unlock()
			continue // old turn, ignore
		}
		// A normal client is never more than its input delay ahead. Anything far
		// past that is a bug or abuse, and storing it would let memory grow without limit.
		if msg.Turn > m.nextTurn+maxAhead {
			now := m.nextTurn
			m.mu.Unlock()
			return fmt.Sprintf("player %d sent turn %d, more than %d turns ahead of turn %d",
				player, msg.Turn, maxAhead, now)
		}
		if m.got[msg.Turn] == nil {
			m.got[msg.Turn] = &[2]bool{}
			m.pending[msg.Turn] = &[2][]json.RawMessage{}
		}
		if m.got[msg.Turn][player] {
			m.mu.Unlock()
			continue // already submitted this turn
		}
		m.got[msg.Turn][player] = true
		m.pending[msg.Turn][player] = msg.Cmds

		// Release every turn that both players have now submitted, in order.
		var out []Msg
		for g := m.got[m.nextTurn]; g != nil && g[0] && g[1]; g = m.got[m.nextTurn] {
			t := m.nextTurn
			out = append(out, Msg{Type: "turn", Turn: t, All: *m.pending[t]})
			delete(m.got, t)
			delete(m.pending, t)
			m.nextTurn++
		}
		m.mu.Unlock()

		for _, o := range out {
			m.send(0, o)
			m.send(1, o)
		}
	}
}

func (m *Match) end(reason string) {
	m.mu.Lock()
	if m.ended {
		m.mu.Unlock()
		return
	}
	m.ended = true
	m.mu.Unlock()
	m.notifyEnd(reason)
}

// notifyEnd tells both players the match is over and closes their connections.
func (m *Match) notifyEnd(reason string) {
	log.Printf("[%s] ended: %s", m.id, reason)
	for p := 0; p < 2; p++ {
		m.send(p, Msg{Type: "end", Reason: reason})
		m.mu.Lock()
		if m.conns[p] != nil {
			m.conns[p].Close()
		}
		m.mu.Unlock()
	}
}

// ---------- Client (test/demo) ----------

// runClient joins a match and runs a fixed-step sim on top of the lockstep turns.
//
//   - The sim steps every simTick. A turn is ticksPerTurn sim ticks.
//   - Commands typed during turn T are sent tagged for turn T+delay, so they reach
//     the server and come back before either sim needs them.
//   - Turns 0..delay-1 are sent empty at startup so the first turns have data.
//   - A turn's commands are applied on its first tick, player 0 then player 1.
//   - If a turn's data hasn't arrived yet, the sim waits (the "waiting for player" stall).
func runClient(server string, simTick time.Duration, ticksPerTurn, delay int) {
	var mr MatchResp
	res, err := resty.New().R().SetResult(&mr).Post(server + "/match")
	if err != nil || res.IsError() {
		log.Fatalf("join match: %v %s", err, res.String())
	}
	log.Printf("joined match %s as player %d", mr.MatchID, mr.Player)

	u, _ := url.Parse(server)
	u.Scheme = strings.Replace(u.Scheme, "http", "ws", 1) // http->ws, https->wss
	u.Path = "/ws"
	u.RawQuery = fmt.Sprintf("match=%s&player=%d", mr.MatchID, mr.Player)
	conn, _, err := websocket.DefaultDialer.Dial(u.String(), nil)
	if err != nil {
		log.Fatal("dial:", err)
	}
	defer conn.Close()

	// Read from the server in one goroutine and hand messages to the game loop.
	incoming := make(chan Msg, 256)
	go func() {
		defer close(incoming)
		for {
			var msg Msg
			if err := conn.ReadJSON(&msg); err != nil {
				return
			}
			incoming <- msg
		}
	}()

	// Read stdin in another goroutine. Each line becomes one command.
	input := make(chan string, 64)
	go func() {
		sc := bufio.NewScanner(os.Stdin)
		for sc.Scan() {
			input <- sc.Text()
		}
	}()

	// Wait for both players.
	log.Println("waiting for opponent...")
	var start Msg
	for start = range incoming {
		if start.Type == "start" {
			break
		}
		if start.Type == "end" {
			log.Fatal("match ended before start: ", start.Reason)
		}
	}
	if start.Type != "start" {
		log.Fatal("disconnected before start")
	}
	sim := &Sim{rng: rand.New(rand.NewSource(start.Seed))}
	log.Printf("match started, seed=%d, delay=%d turns (%v). Type commands and press enter.",
		start.Seed, delay, time.Duration(delay*ticksPerTurn)*simTick)

	send := func(turn int, cmds []json.RawMessage) {
		if err := conn.WriteJSON(Msg{Type: "cmds", Turn: turn, Cmds: cmds}); err != nil {
			log.Fatal("write:", err)
		}
	}

	// Prime the pipeline with empty turns.
	for t := 0; t < delay; t++ {
		send(t, nil)
	}

	confirmed := map[int][2][]json.RawMessage{} // turns received from the server, not yet run

	// handle processes one server message. It returns false when the match is over.
	handle := func(msg Msg, ok bool) bool {
		if !ok {
			log.Println("connection closed")
			return false
		}
		switch msg.Type {
		case "end":
			log.Println("match ended:", msg.Reason)
			return false
		case "turn":
			confirmed[msg.Turn] = msg.All
		}
		return true
	}

	ticker := time.NewTicker(simTick)
	defer ticker.Stop()

	for tick := 0; ; tick++ {
		if tick%ticksPerTurn == 0 {
			turn := tick / ticksPerTurn

			// Send what the player typed, scheduled for turn+delay.
			var cmds []json.RawMessage
		drain:
			for {
				select {
				case line := <-input:
					b, _ := json.Marshal(map[string]string{"cmd": line})
					cmds = append(cmds, b)
					// A real game would give instant local feedback here (sound, click marker).
				default:
					break drain
				}
			}
			send(turn+delay, cmds)

			// Pick up whatever has arrived, then wait if this turn is still missing.
			for drained := false; !drained; {
				select {
				case msg, ok := <-incoming:
					if !handle(msg, ok) {
						return
					}
				default:
					drained = true
				}
			}
			if _, have := confirmed[turn]; !have {
				waitStart := time.Now()
				for {
					msg, ok := <-incoming
					if !handle(msg, ok) {
						return
					}
					if _, have := confirmed[turn]; have {
						break
					}
				}
				log.Printf("stalled %v waiting for turn %d", time.Since(waitStart).Round(time.Millisecond), turn)
			}

			sim.Apply(turn, confirmed[turn])
			delete(confirmed, turn)
		}

		sim.Step(tick)
		<-ticker.C
	}
}

func (s *Sim) Apply(turn int, all [2][]json.RawMessage) {
	for p, list := range all {
		for _, c := range list {
			fmt.Printf("turn %d  p%d: %s  (roll %d)\n", turn, p, c, s.rng.Intn(100))
		}
	}
}

func (s *Sim) Step(tick int) {
	// Move units, resolve combat, etc.
}

func main() {
	mode := flag.String("mode", "server", "server or client")
	addr := flag.String("addr", ":8080", "server listen address")
	server := flag.String("server", "http://localhost:8080", "server URL for client mode")
	simTick := flag.Duration("tick", 50*time.Millisecond, "client sim tick length")
	ticksPerTurn := flag.Int("ticks-per-turn", 2, "sim ticks per lockstep turn")
	delay := flag.Int("delay", 2, "input delay in turns")
	joinTimeout := flag.Duration("join-timeout", 30*time.Second, "server: time for both players to connect")
	maxAhead := flag.Int("max-ahead", 50, "server: furthest a client may send past the current turn")
	flag.Parse()

	switch *mode {
	case "server":
		// run server
		s := &Server{matches: map[string]*Match{}, joinTimeout: *joinTimeout, maxAhead: *maxAhead}
		handleMatch := func(w http.ResponseWriter, r *http.Request) {
			` ./main-handle-match.sh ${v}hdl_mtch_ `
		}
		handleWS := func(w http.ResponseWriter, r *http.Request) {
			` ./main-handle-ws.sh ${v}hdl_ws_ `
		}
		http.HandleFunc("/match", handleMatch)
		http.HandleFunc("/ws", handleWS)
		log.Println("lockstep server listening on", *addr)
		log.Fatal(http.ListenAndServe(*addr, nil))
	case "client":
		if *ticksPerTurn < 1 || *delay < 1 {
			log.Fatal("ticks-per-turn and delay must be >= 1")
		}
		runClient(*server, *simTick, *ticksPerTurn, *delay)
	default:
		log.Fatalf("unknown mode %q", *mode)
	}
}
EOF
