#!/bin/bash
v=${1:-mn_}
# maps
# Only names main.sh uses are exported. Other bound names default to their
# namespaced name (such as mn_jn_Body), shared by every step in the namespace.
# join: handle one connection, then start or expire the match
export ${v}jn_S=s
export ${v}jn_Listener=ln
export ${v}jn_Matched=matched
export ${v}jn_Accepted=accepted
export ${v}jn_IsMatch=isMatch
export ${v}jn_IsWs=isWS
export ${v}jn_Ready=ready
export ${v}jn_Expired=expired
export ${v}jn_When=${v}jn_Taken
export ${v}jn_Msg=${v}jn_TakenMsg
export ${v}jn_Err=${v}jn_TakenErr
# join: send player p their start or end notice
export ${v}js_P=p
export ${v}js_Ready=ready
export ${v}js_Expired=expired
export ${v}js_Connected=connected
export ${v}js_When=connected
export ${v}js_M=${v}jn_M
# play: one turn
export ${v}pl_S=s
export ${v}pl_Matched=matched
export ${v}pl_P=p
export ${v}pl_Reading=reading
export ${v}pl_Framing=framing
export ${v}pl_Ended=ended
export ${v}pl_Connected=connected
export ${v}pl_When=connected

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
//
// The server runs one match at a time in a single loop. Each pass either takes
// one connection while players join, or plays one turn once they're matched.
package main

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/go-resty/resty/v2"
	"github.com/gorilla/websocket"
)

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
		s := &Server{joinTimeout: *joinTimeout, maxAhead: *maxAhead}
		tcpAddr, err := net.ResolveTCPAddr("tcp", *addr)
		if err != nil {
			log.Fatal("listen: ", err)
		}
		ln, err := net.ListenTCP("tcp", tcpAddr)
		if err != nil {
			log.Fatal("listen: ", err)
		}
		log.Println("lockstep server listening on", *addr)
		// The server runs until it's stopped. Each pass takes one step: while
		// players are joining, it handles one connection; once they're matched,
		// it plays one turn. Joining sets matched when the match starts, and
		// playing clears it when the match ends.
		matched := false
		for serving := true; serving; {
			if !matched {
				` ./main-join-accept.sh ${v}jn_ `
				if accepted {
					` ./main-join-read-request.sh ${v}jn_ `
					if isMatch {
						` ./main-handle-match.sh ${v}jn_ `
					}
					if isWS {
						` ./main-handle-ws.sh ${v}jn_ `
					}
					` ./main-write-frame.sh ${v}jn_ `
					` ./main-join-reply.sh ${v}jn_ `
				}
				` ./main-join-check.sh ${v}jn_ `
				for p := 0; (ready || expired) && p < 2; p++ {
					` ./main-join-notice.sh ${v}js_ `
					` ./main-player-conn.sh ${v}js_ `
					` ./main-write-frame.sh ${v}js_ `
					` ./main-player-sent.sh ${v}js_ `
					if expired && connected {
						` ./main-player-close.sh ${v}js_ `
					}
				}
				if expired {
					` ./main-match-end.sh ${v}jn_ `
				}
				if ready {
					` ./main-join-start.sh ${v}jn_ `
				}
			} else {
				` ./main-play-begin.sh ${v}pl_ `
				for p := 0; p < 2; p++ {
					for reading := true; reading; {
						` ./main-play-need.sh ${v}pl_ `
						if reading {
							for framing := true; framing; {
								` ./main-read-frame.sh ${v}pl_ `
							}
							` ./main-read-cmds.sh ${v}pl_ `
						}
					}
				}
				` ./main-play-outcome.sh ${v}pl_ `
				for p := 0; p < 2; p++ {
					` ./main-player-conn.sh ${v}pl_ `
					` ./main-write-frame.sh ${v}pl_ `
					` ./main-player-sent.sh ${v}pl_ `
					if ended && connected {
						` ./main-player-close.sh ${v}pl_ `
					}
				}
				if ended {
					` ./main-match-end.sh ${v}pl_ `
				}
			}
		}
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
