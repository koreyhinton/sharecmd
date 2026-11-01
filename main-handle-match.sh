#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} R W S
export ${v}xp_M=m
export ${v}xp_S=${!s}

cat << EOF
	isPost := ${!r}.Method == http.MethodPost
	if !isPost {
		http.Error(${!w}, "POST only", http.StatusMethodNotAllowed)
	}

	// expire ends a new match if both players haven't opened their websocket in time,
	// so nobody waits forever on a player who called /match and then went away.
	expire := func(m *Match) {
		` ./main-handle-match-expire.sh ${v}xp_ `
	}

	${!s}.mu.Lock()
	m := ${!s}.waiting
	hasWaiting := m != nil
	var resp MatchResp
	if isPost && hasWaiting {
		${!s}.waiting = nil
		resp = MatchResp{MatchID: m.id, Player: 1}
	}
	if isPost && !hasWaiting {
		${!s}.nextID++
		m = &Match{
			id:      fmt.Sprintf("m%d", ${!s}.nextID),
			seed:    rand.Int63(),
			pending: map[int]*[2][]json.RawMessage{},
			got:     map[int]*[2]bool{},
		}
		${!s}.matches[m.id] = m
		${!s}.waiting = m
		resp = MatchResp{MatchID: m.id, Player: 0}
		time.AfterFunc(${!s}.joinTimeout, func() { expire(m) })
	}
	${!s}.mu.Unlock()

	if isPost {
		${!w}.Header().Set("Content-Type", "application/json")
		// Lets a browser client served from another port (like demo/web) read the reply.
		${!w}.Header().Set("Access-Control-Allow-Origin", "*")
		json.NewEncoder(${!w}).Encode(resp)
	}
EOF
