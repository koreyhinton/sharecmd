#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} Conn When

cat << EOF
	// Read the request. A connection gets 5 seconds to send it and read the
	// reply, so a silent one can't hold up the server for long.
	var reader *bufio.Reader
	var req *http.Request
	if ${!when} {
		${!conn}.SetDeadline(time.Now().Add(5 * time.Second))
		reader = bufio.NewReader(${!conn})
		req, _ = http.ReadRequest(reader)
	}
	hasReq := req != nil
	isMatch := hasReq && req.URL.Path == "/match"
	isWS := hasReq && req.URL.Path == "/ws"

	// The reply, which the steps below fill in. keep is set when the connection
	// becomes a player's websocket, and switched once the handshake reply is sent.
	code, body := http.StatusNotFound, "404 page not found\n"
	header := http.Header{"Content-Type": {"text/plain; charset=utf-8"}}
	keep, switched := false, false
EOF
