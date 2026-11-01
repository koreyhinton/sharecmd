package main

// TestTwoClients runs the server and two real clients (-mode client) the way you
// would by hand: type a command into each client, check both clients print it
// for the right player, then close one client and check the other one exits.

import (
	"bytes"
	"io"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

// syncBuffer collects a process's output while the test reads it.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.String()
}

type client struct {
	name  string
	stdin io.WriteCloser
	out   *syncBuffer
	cmd   *exec.Cmd
	done  chan struct{} // closed when the process exits
}

func startClient(t *testing.T, name, addr string) *client {
	t.Helper()
	c := &client{name: name, out: &syncBuffer{}, done: make(chan struct{})}
	c.cmd = exec.Command(serverBin, "-mode", "client", "-server", "http://"+addr)
	c.cmd.Stdout = c.out
	c.cmd.Stderr = c.out
	stdin, err := c.cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	c.stdin = stdin
	if err := c.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	go func() {
		c.cmd.Wait()
		close(c.done)
	}()
	t.Cleanup(func() {
		c.cmd.Process.Kill()
		<-c.done
		if strings.Contains(c.out.String(), "DATA RACE") {
			t.Errorf("%s reported a data race:\n%s", c.name, c.out)
		}
	})
	return c
}

func (c *client) typeLine(t *testing.T, line string) {
	t.Helper()
	if _, err := io.WriteString(c.stdin, line+"\n"); err != nil {
		t.Fatalf("%s: type %q: %v", c.name, line, err)
	}
}

// waitFor waits until the client's output matches re and returns the match.
func (c *client) waitFor(t *testing.T, re *regexp.Regexp) string {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if m := re.FindString(c.out.String()); m != "" {
			return m
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("%s: timed out waiting for %q. Output so far:\n%s", c.name, re, c.out)
	return ""
}

// turnLine matches the line a client prints when it runs a command, such as
// turn 7  p0: {"cmd":"move 10 20"}  (roll 87)
func turnLine(player, cmd string) *regexp.Regexp {
	return regexp.MustCompile(`turn \d+  ` + player + `: \{"cmd":"` + regexp.QuoteMeta(cmd) + `"\}  \(roll \d+\)`)
}

func TestTwoClients(t *testing.T) {
	addr := startServer(t, 30*time.Second)

	// Start them one at a time so c0 is player 0 and c1 is player 1.
	c0 := startClient(t, "client 0", addr)
	c0.waitFor(t, regexp.MustCompile(`as player 0`))
	c1 := startClient(t, "client 1", addr)
	c1.waitFor(t, regexp.MustCompile(`as player 1`))
	started := regexp.MustCompile(`match started`)
	c0.waitFor(t, started)
	c1.waitFor(t, started)

	// Each command shows up in both clients, for the player who typed it, on the
	// same turn with the same roll.
	steps := []struct {
		from   *client
		player string
		cmd    string
	}{
		{c0, "p0", "move 10 20"},
		{c1, "p1", "attack 3 4"},
	}
	for _, s := range steps {
		s.from.typeLine(t, s.cmd)
		re := turnLine(s.player, s.cmd)
		got0, got1 := c0.waitFor(t, re), c1.waitFor(t, re)
		if got0 != got1 {
			t.Fatalf("clients disagree:\n  client 0: %s\n  client 1: %s", got0, got1)
		}
	}

	// Closing one client ends the match, and the other client exits too.
	c1.cmd.Process.Kill()
	c0.waitFor(t, regexp.MustCompile(`match ended: player 1 disconnected`))
	select {
	case <-c0.done:
	case <-time.After(5 * time.Second):
		t.Fatalf("client 0 didn't exit after client 1 closed. Output:\n%s", c0.out)
	}
	if code := c0.cmd.ProcessState.ExitCode(); code != 0 {
		t.Fatalf("client 0 exited with code %d. Output:\n%s", code, c0.out)
	}
	// The server is stopped by startServer's cleanup.
}
