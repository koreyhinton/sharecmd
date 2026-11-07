#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} Conn Reader Req IsMatch IsWs Code Body Header Keep Switched Taken TakenMsg TakenErr

cat << EOF
	// Read the request. A connection gets 5 seconds to send it and read the
	// reply, so a silent one can't hold up the server for long.
	${!conn}.SetDeadline(time.Now().Add(5 * time.Second))
	${!reader} := bufio.NewReader(${!conn})
	${!req}, _ := http.ReadRequest(${!reader})
	hasReq := ${!req} != nil
	${!is_match} := hasReq && ${!req}.URL.Path == "/match"
	${!is_ws} := hasReq && ${!req}.URL.Path == "/ws"

	// The reply, which the steps below fill in. keep is set when the connection
	// becomes a player's websocket, and switched once the handshake reply is sent.
	// taken is set when the player's slot is already in use: the connection then
	// gets takenMsg over the websocket instead.
	${!code}, ${!body} := http.StatusNotFound, "404 page not found\n"
	${!header} := http.Header{"Content-Type": {"text/plain; charset=utf-8"}}
	${!keep}, ${!switched}, ${!taken} := false, false, false
	${!taken_msg} := Msg{Type: "end", Reason: "slot taken or match over"}
	var ${!taken_err} error
EOF
