#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S Conn When
export ${v}mt_S=${!s}
export ${v}mt_Req=req
export ${v}mt_Code=code
export ${v}mt_Body=body
export ${v}mt_Header=header
export ${v}mt_When=isMatch
export ${v}ws_S=${!s}
export ${v}ws_Req=req
export ${v}ws_Conn=${!conn}
export ${v}ws_Reader=reader
export ${v}ws_Code=code
export ${v}ws_Body=body
export ${v}ws_Keep=keep
export ${v}ws_Switched=switched
export ${v}ws_When=isWS

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
	` ./main-handle-match.sh ${v}mt_ `
	` ./main-handle-ws.sh ${v}ws_ `

	replies := hasReq && !switched
	if replies {
		res := &http.Response{
			StatusCode:    code,
			ProtoMajor:    1,
			ProtoMinor:    1,
			Header:        header,
			ContentLength: int64(len(body)),
			Body:          io.NopCloser(strings.NewReader(body)),
			Close:         true,
		}
		res.Write(${!conn})
	}
	closes := ${!when} && !keep
	if closes {
		${!conn}.Close()
	}
EOF
