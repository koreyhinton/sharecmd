#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S Listener Matched
export ${v}req_S=${!s}
export ${v}req_Conn=conn
export ${v}req_When=accepted
export ${v}ne_M=waiting
export ${v}ne_When=expired
export ${v}st_M=waiting
export ${v}st_P=p
export ${v}st_Msg=start

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
	` ./main-handle-request.sh ${v}req_ `

	// End the match if its players didn't both connect in time.
	waiting := ${!s}.match
	ready := waiting != nil && waiting.conns[0] != nil && waiting.conns[1] != nil
	expired := waiting != nil && !ready && !time.Now().Before(waiting.deadline)
	if expired {
		waiting.reason = "opponent didn't connect in time"
	}
	` ./main-notify-end.sh ${v}ne_ `
	if expired {
		${!s}.match = nil
	}

	// Start the match once both players are connected.
	for p := 0; ready && p < 2; p++ {
		start := Msg{Type: "start", Player: p, Seed: waiting.seed}
		` ./main-send.sh ${v}st_ `
	}
	if ready {
		log.Printf("[%s] started, seed=%d", waiting.id, waiting.seed)
		${!matched} = true
	}
EOF
