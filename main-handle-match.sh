#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S Req Code Body Header

cat << EOF
	// POST /match gives the caller a slot: player 0 starts a new match and
	// player 1 fills it. Matches run one at a time, so once both slots are
	// given out, later callers are turned away until the match is over.
	isPost := ${!req}.Method == http.MethodPost
	if !isPost {
		${!code}, ${!body} = http.StatusMethodNotAllowed, "POST only\n"
	}
	isNew := isPost && ${!s}.match == nil
	if isNew {
		${!s}.nextID++
		${!s}.match = &Match{
			id:       fmt.Sprintf("m%d", ${!s}.nextID),
			seed:     rand.Int63(),
			deadline: time.Now().Add(${!s}.joinTimeout),
			pending:  map[int]*[2][]json.RawMessage{},
			got:      map[int]*[2]bool{},
		}
	}
	full := isPost && ${!s}.match.joined == 2
	if full {
		${!code}, ${!body} = http.StatusServiceUnavailable, "a match is in progress, try again later\n"
	}
	hasSlot := isPost && !full
	if hasSlot {
		resp := MatchResp{MatchID: ${!s}.match.id, Player: ${!s}.match.joined}
		${!s}.match.joined++
		b, _ := json.Marshal(resp)
		${!code}, ${!body} = http.StatusOK, string(b)+"\n"
		${!header}.Set("Content-Type", "application/json")
		// Lets a browser client served from another port (like demo/web) read the reply.
		${!header}.Set("Access-Control-Allow-Origin", "*")
	}
EOF
