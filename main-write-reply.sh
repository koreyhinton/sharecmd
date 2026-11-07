#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} Conn Req Code Body Header Switched Keep When

cat << EOF
	// Send the HTTP reply, unless the connection switched to a websocket. Then
	// close the connection, unless it's now a player's websocket.
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
	closes := ${!when} && !${!keep}
	if closes {
		${!conn}.Close()
	}
EOF
