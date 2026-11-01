#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} R W

cat << EOF
	if ${!r}.Method != http.MethodPost {
		http.Error(${!w}, "POST only", http.StatusMethodNotAllowed)
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

	${!w}.Header().Set("Content-Type", "application/json")
	// Lets a browser client served from another port (like demo/web) read the reply.
	${!w}.Header().Set("Access-Control-Allow-Origin", "*")
	json.NewEncoder(${!w}).Encode(resp)
EOF
