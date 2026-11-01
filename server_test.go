package main

// End-to-end tests for the server. The server is written inline in main() (see
// CLAUDE.md), so these tests build the binary with the race detector, start it,
// and talk to it over HTTP and websockets. Run ./build.sh first to generate main.go.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

var serverBin string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "sharecmd-test")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	serverBin = filepath.Join(dir, "sharecmd")
	out, err := exec.Command("go", "build", "-race", "-o", serverBin, ".").CombinedOutput()
	if err != nil {
		fmt.Fprintf(os.Stderr, "build server: %v\n%s", err, out)
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// startServer runs the server on a free port and returns its address. The test
// fails if the race detector reports anything in the server's output.
func startServer(t *testing.T, joinTimeout time.Duration) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	l.Close()

	var logs bytes.Buffer
	cmd := exec.Command(serverBin, "-mode", "server", "-addr", addr, "-join-timeout", joinTimeout.String())
	cmd.Stdout = &logs
	cmd.Stderr = &logs
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cmd.Process.Kill()
		cmd.Wait()
		if strings.Contains(logs.String(), "DATA RACE") {
			t.Errorf("server reported a data race:\n%s", logs.String())
		}
	})

	// Wait until it answers. GET /match is rejected, so it doesn't create a match.
	deadline := time.Now().Add(10 * time.Second)
	for {
		res, err := http.Get("http://" + addr + "/match")
		if err == nil {
			res.Body.Close()
			return addr
		}
		if time.Now().After(deadline) {
			t.Fatalf("server didn't start: %v\n%s", err, logs.String())
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func joinMatch(t *testing.T, addr string) MatchResp {
	t.Helper()
	res, err := http.Post("http://"+addr+"/match", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var mr MatchResp
	if err := json.NewDecoder(res.Body).Decode(&mr); err != nil {
		t.Fatal(err)
	}
	return mr
}

func dialWS(t *testing.T, addr, matchID string, player int) *websocket.Conn {
	t.Helper()
	u := fmt.Sprintf("ws://%s/ws?match=%s&player=%d", addr, matchID, player)
	c, _, err := websocket.DefaultDialer.Dial(u, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func readMsg(t *testing.T, c *websocket.Conn) Msg {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	var m Msg
	if err := c.ReadJSON(&m); err != nil {
		t.Fatalf("read: %v", err)
	}
	return m
}

func sendCmds(t *testing.T, c *websocket.Conn, turn int, cmds ...string) {
	t.Helper()
	var raw []json.RawMessage
	for _, s := range cmds {
		b, _ := json.Marshal(s)
		raw = append(raw, b)
	}
	if err := c.WriteJSON(Msg{Type: "cmds", Turn: turn, Cmds: raw}); err != nil {
		t.Fatal(err)
	}
}

// wantTurn reads one message and checks it is the given turn with these commands.
func wantTurn(t *testing.T, c *websocket.Conn, turn int, p0, p1 []string) {
	t.Helper()
	m := readMsg(t, c)
	var got [2][]string
	for p, list := range m.All {
		for _, raw := range list {
			var s string
			json.Unmarshal(raw, &s)
			got[p] = append(got[p], s)
		}
	}
	want := [2][]string{p0, p1}
	if m.Type != "turn" || m.Turn != turn || fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("got %s turn %d %v, want turn %d %v", m.Type, m.Turn, got, turn, want)
	}
}

func wantEnd(t *testing.T, c *websocket.Conn, reason string) {
	t.Helper()
	m := readMsg(t, c)
	if m.Type != "end" || !strings.Contains(m.Reason, reason) {
		t.Fatalf("got %s %q, want end containing %q", m.Type, m.Reason, reason)
	}
}

func TestBadRequests(t *testing.T) {
	addr := startServer(t, 30*time.Second)
	cases := []struct {
		name, method, path string
		code               int
	}{
		{"GET /match", "GET", "/match", http.StatusMethodNotAllowed},
		{"bad player", "GET", "/ws?match=m1&player=5", http.StatusBadRequest},
		{"no such match", "GET", "/ws?match=nope&player=0", http.StatusNotFound},
	}
	for _, tc := range cases {
		req, _ := http.NewRequest(tc.method, "http://"+addr+tc.path, nil)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if res.StatusCode != tc.code {
			t.Errorf("%s: got %d, want %d", tc.name, res.StatusCode, tc.code)
		}
	}
}

func TestMatch(t *testing.T) {
	addr := startServer(t, 30*time.Second)
	mr0, mr1 := joinMatch(t, addr), joinMatch(t, addr)
	if mr0.MatchID != mr1.MatchID || mr0.Player != 0 || mr1.Player != 1 {
		t.Fatalf("join: got %+v and %+v", mr0, mr1)
	}
	a, b := dialWS(t, addr, mr0.MatchID, 0), dialWS(t, addr, mr0.MatchID, 1)

	sa, sb := readMsg(t, a), readMsg(t, b)
	if sa.Type != "start" || sb.Type != "start" || sa.Player != 0 || sb.Player != 1 || sa.Seed != sb.Seed {
		t.Fatalf("start: got %+v and %+v", sa, sb)
	}

	// A non-cmds message and a second submission for the same turn are ignored.
	// Turn 0 is released only once both players have sent it.
	a.WriteJSON(Msg{Type: "hello"})
	sendCmds(t, a, 0, "a0")
	sendCmds(t, a, 0, "a0 again")
	sendCmds(t, b, 1, "b1")
	sendCmds(t, b, 0, "b0")
	wantTurn(t, a, 0, []string{"a0"}, []string{"b0"})
	wantTurn(t, b, 0, []string{"a0"}, []string{"b0"})

	sendCmds(t, a, 1, "a1")
	wantTurn(t, a, 1, []string{"a1"}, []string{"b1"})
	wantTurn(t, b, 1, []string{"a1"}, []string{"b1"})

	// A turn that was already released is ignored.
	sendCmds(t, a, 0, "old")
	sendCmds(t, a, 2)
	sendCmds(t, b, 2, "b2")
	wantTurn(t, a, 2, nil, []string{"b2"})
	wantTurn(t, b, 2, nil, []string{"b2"})

	t.Run("slot taken", func(t *testing.T) {
		c := dialWS(t, addr, mr0.MatchID, 0)
		wantEnd(t, c, "slot taken or match over")
	})

	t.Run("too far ahead ends match", func(t *testing.T) {
		sendCmds(t, a, 3+50+1, "far") // next turn is 3, default -max-ahead is 50
		wantEnd(t, a, "more than 50 turns ahead")
		wantEnd(t, b, "more than 50 turns ahead")
	})
}

func TestDisconnect(t *testing.T) {
	addr := startServer(t, 30*time.Second)
	id := joinMatch(t, addr).MatchID
	joinMatch(t, addr)
	a, b := dialWS(t, addr, id, 0), dialWS(t, addr, id, 1)
	readMsg(t, a)
	readMsg(t, b)
	b.Close()
	wantEnd(t, a, "player 1 disconnected")
}

func TestJoinTimeout(t *testing.T) {
	addr := startServer(t, 500*time.Millisecond)
	id := joinMatch(t, addr).MatchID
	a := dialWS(t, addr, id, 0)
	wantEnd(t, a, "opponent didn't connect in time")

	// The expired match is gone: the next join starts a new match.
	mr := joinMatch(t, addr)
	if mr.MatchID == id || mr.Player != 0 {
		t.Fatalf("after timeout: got %+v, want a new match as player 0", mr)
	}
}
