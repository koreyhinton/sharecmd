#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S Listener

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
EOF
