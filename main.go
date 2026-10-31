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
	"sync"
	"time"

	"github.com/go-resty/resty/v2"
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

func (s *Server) handleMatch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	s.mu.Lock()
	var resp MatchResp
	if s.waiting != nil {
		m := s.waiting
		s.waiting = nil
		m.joined = 2
		resp = MatchResp{MatchID: m.id, Player: 1}
	} else {
		s.nextID++
		m := &Match{
			id:      fmt.Sprintf("m%d", s.nextID),
			seed:    rand.Int63(),
			joined:  1,
			pending: map[int]*[2][]json.RawMessage{},
			got:     map[int]*[2]bool{},
		}
		s.matches[m.id] = m
		s.waiting = m
		resp = MatchResp{MatchID: m.id, Player: 0}

		// If both players haven't opened their websocket in time, end the match so
		// nobody waits forever on a player who called /match and then went away.
		time.AfterFunc(s.joinTimeout, func() {
			m.mu.Lock()
			if m.ended || (m.conns[0] != nil && m.conns[1] != nil) {
				m.mu.Unlock()
				return
			}
			m.ended = true // set under the lock so a late connect is rejected
			m.mu.Unlock()
			m.notifyEnd("opponent didn't connect in time")
			s.remove(m)
		})
	}
	s.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("match")
	var player int
	if _, err := fmt.Sscan(r.URL.Query().Get("player"), &player); err != nil || player < 0 || player > 1 {
		http.Error(w, "bad player", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	m := s.matches[id]
	s.mu.Unlock()
	if m == nil {
		http.Error(w, "no such match", http.StatusNotFound)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Println("upgrade:", err)
		return
	}

	m.mu.Lock()
	if m.conns[player] != nil || m.ended {
		m.mu.Unlock()
		conn.WriteJSON(Msg{Type: "end", Reason: "slot taken or match over"})
		conn.Close()
		return
	}
	m.conns[player] = conn
	ready := m.conns[0] != nil && m.conns[1] != nil
	m.mu.Unlock()

	log.Printf("[%s] player %d connected", m.id, player)
	if ready {
		for p := 0; p < 2; p++ {
			m.send(p, Msg{Type: "start", Player: p, Seed: m.seed})
		}
		log.Printf("[%s] started, seed=%d", m.id, m.seed)
	}

	m.end(m.readLoop(player, conn, s.maxAhead))
	s.remove(m)
}

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

func runServer(addr string, joinTimeout time.Duration, maxAhead int) {
	s := &Server{matches: map[string]*Match{}, joinTimeout: joinTimeout, maxAhead: maxAhead}
	http.HandleFunc("/match", s.handleMatch)
	http.HandleFunc("/ws", s.handleWS)
	log.Println("lockstep server listening on", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
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

// Sim is a stand-in for the deterministic game simulation. Everything here must
// depend only on the commands and the shared seed: no wall clock, no map
// iteration order, no unseeded randomness.
type Sim struct {
	rng *rand.Rand
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
		runServer(*addr, *joinTimeout, *maxAhead)
	case "client":
		if *ticksPerTurn < 1 || *delay < 1 {
			log.Fatal("ticks-per-turn and delay must be >= 1")
		}
		runClient(*server, *simTick, *ticksPerTurn, *delay)
	default:
		log.Fatalf("unknown mode %q", *mode)
	}
}
