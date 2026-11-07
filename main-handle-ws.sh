#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S Req Conn Reader Code Body Keep Switched When

cat << EOF
	// GET /ws?match=ID&player=N opens player N's websocket in the current match.
	query, reqHeader := url.Values{}, http.Header{}
	if ${!when} {
		query, reqHeader = ${!req}.URL.Query(), ${!req}.Header
	}
	var player int
	_, playerErr := fmt.Sscan(query.Get("player"), &player)
	validPlayer := ${!when} && playerErr == nil && player >= 0 && player <= 1
	if ${!when} && !validPlayer {
		${!code}, ${!body} = http.StatusBadRequest, "bad player\n"
	}
	found := validPlayer && ${!s}.match != nil && ${!s}.match.id == query.Get("match")
	if validPlayer && !found {
		${!code}, ${!body} = http.StatusNotFound, "no such match\n"
	}

	// Finish the websocket handshake (RFC 6455, section 4.2.2).
	key := reqHeader.Get("Sec-WebSocket-Key")
	isUpgrade := found && strings.EqualFold(reqHeader.Get("Upgrade"), "websocket") && key != ""
	if found && !isUpgrade {
		${!code}, ${!body} = http.StatusBadRequest, "not a websocket handshake\n"
	}
	if isUpgrade {
		sum := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
		accept := base64.StdEncoding.EncodeToString(sum[:])
		fmt.Fprintf(${!conn}, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept)
		${!conn}.SetDeadline(time.Time{})
		${!switched} = true
	}

	// Take the player's slot. If it's already in use, the connection gets an
	// "end" message instead.
	claimed := isUpgrade && ${!s}.match.conns[player] == nil
	if claimed {
		${!s}.match.conns[player] = ${!conn}
		${!s}.match.readers[player] = ${!reader}
		${!keep} = true
		log.Printf("[%s] player %d connected", ${!s}.match.id, player)
	}
	taken := isUpgrade && !claimed
	takenMsg := Msg{Type: "end", Reason: "slot taken or match over"}
	var takenErr error
EOF
