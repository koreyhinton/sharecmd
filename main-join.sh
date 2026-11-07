#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S Listener Matched
export ${v}rq_Conn=conn
export ${v}rq_When=accepted
export ${v}mt_S=${!s}
export ${v}mt_Req=req
export ${v}mt_Code=code
export ${v}mt_Body=body
export ${v}mt_Header=header
export ${v}mt_When=isMatch
export ${v}ws_S=${!s}
export ${v}ws_Req=req
export ${v}ws_Conn=conn
export ${v}ws_Reader=reader
export ${v}ws_Code=code
export ${v}ws_Body=body
export ${v}ws_Keep=keep
export ${v}ws_Switched=switched
export ${v}ws_Taken=taken
export ${v}ws_When=isWS
export ${v}tk_Conn=conn
export ${v}tk_Msg=takenMsg
export ${v}tk_Err=takenErr
export ${v}tk_When=taken
export ${v}rp_Conn=conn
export ${v}rp_Req=req
export ${v}rp_Code=code
export ${v}rp_Body=body
export ${v}rp_Header=header
export ${v}rp_Switched=switched
export ${v}rp_Keep=keep
export ${v}rp_When=accepted
export ${v}wf_Conn=c
export ${v}wf_Msg=out
export ${v}wf_Err=writeErr
export ${v}wf_When=connected

cat << EOF
	// Join: take one connection and handle its request. Each connection
	// carries one HTTP request: POST /match to get a slot, or GET /ws to open
	// that slot's websocket. While a match is waiting for its players, stop
	// waiting for a connection at its join deadline.
	var deadline time.Time
	hasMatch := ${!s}.match != nil
	if hasMatch {
		deadline = ${!s}.match.deadline
	}
	${!listener}.SetDeadline(deadline)
	conn, acceptErr := ${!listener}.Accept()
	timedOut := errors.Is(acceptErr, os.ErrDeadlineExceeded)
	if acceptErr != nil && !timedOut {
		log.Println("accept:", acceptErr)
	}
	accepted := acceptErr == nil
	` ./main-read-request.sh ${v}rq_ `

	// The reply, which the steps below fill in. keep is set when the connection
	// becomes a player's websocket, switched once the handshake reply is sent,
	// and taken when the player's slot is already in use.
	code, body := http.StatusNotFound, "404 page not found\n"
	header := http.Header{"Content-Type": {"text/plain; charset=utf-8"}}
	keep, switched, taken := false, false, false
	` ./main-handle-match.sh ${v}mt_ `
	` ./main-handle-ws.sh ${v}ws_ `

	// Turn the websocket away if its slot is taken.
	takenMsg := Msg{Type: "end", Reason: "slot taken or match over"}
	var takenErr error
	` ./main-write-frame.sh ${v}tk_ `
	if takenErr != nil {
		log.Println("write:", takenErr)
	}
	` ./main-write-reply.sh ${v}rp_ `

	// End the match if its players didn't both connect in time, or start it
	// once both are connected. Either way, tell each player.
	waiting := ${!s}.match
	ready := waiting != nil && waiting.conns[0] != nil && waiting.conns[1] != nil
	expired := waiting != nil && !ready && !time.Now().Before(waiting.deadline)
	if expired {
		waiting.reason = "opponent didn't connect in time"
		log.Printf("[%s] ended: %s", waiting.id, waiting.reason)
	}
	for p := 0; (ready || expired) && p < 2; p++ {
		c := waiting.conns[p]
		connected := c != nil
		var out Msg
		if ready {
			out = Msg{Type: "start", Player: p, Seed: waiting.seed}
		}
		if expired {
			out = Msg{Type: "end", Reason: waiting.reason}
		}
		var writeErr error
		` ./main-write-frame.sh ${v}wf_ `
		if writeErr != nil {
			log.Printf("[%s] write to p%d: %v", waiting.id, p, writeErr)
		}
		if expired && connected {
			c.Close()
		}
	}
	if expired {
		${!s}.match = nil
	}
	if ready {
		log.Printf("[%s] started, seed=%d", waiting.id, waiting.seed)
		${!matched} = true
	}
EOF
