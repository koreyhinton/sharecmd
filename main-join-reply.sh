#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} Conn Req Code Body Header Switched Keep TakenErr

cat << EOF
	// Log a failed "end" message to a taken slot. Send the HTTP reply, unless
	// the connection switched to a websocket. Then close the connection, unless
	// it's now a player's websocket.
	if ${!taken_err} != nil {
		log.Println("write:", ${!taken_err})
	}
	replies := ${!req} != nil && !${!switched}
	if replies {
		res := &http.Response{
			StatusCode:    ${!code},
			ProtoMajor:    1,
			ProtoMinor:    1,
			Header:        ${!header},
			ContentLength: int64(len(${!body})),
			Body:          io.NopCloser(strings.NewReader(${!body})),
			Close:         true,
		}
		res.Write(${!conn})
	}
	closes := !${!keep}
	if closes {
		${!conn}.Close()
	}
EOF
