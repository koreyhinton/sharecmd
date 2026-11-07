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
EOF
