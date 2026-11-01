#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} R W S
export ${v}st_M=m
export ${v}st_P=p
export ${v}st_Msg=start
export ${v}rd_M=m
export ${v}rd_S=${!s}
export ${v}rd_Conn=conn
export ${v}rd_Player=player
export ${v}rd_Reason=reason
export ${v}rd_Reading=reading
export ${v}ne_M=m
export ${v}ne_Reason=reason
export ${v}ne_When=endNow
export ${v}rm_S=${!s}
export ${v}rm_M=m
export ${v}rm_When=claimed

cat << EOF
	id := ${!r}.URL.Query().Get("match")
	var player int
	_, err := fmt.Sscan(${!r}.URL.Query().Get("player"), &player)
	validPlayer := err == nil && player >= 0 && player <= 1
	if !validPlayer {
		http.Error(${!w}, "bad player", http.StatusBadRequest)
	}

	${!s}.mu.Lock()
	m := ${!s}.matches[id]
	${!s}.mu.Unlock()
	found := m != nil
	if validPlayer && !found {
		http.Error(${!w}, "no such match", http.StatusNotFound)
	}

	var conn *websocket.Conn
	var upgradeErr error
	if validPlayer && found {
		conn, upgradeErr = upgrader.Upgrade(${!w}, ${!r}, nil)
	}
	upgraded := conn != nil
	if upgradeErr != nil {
		log.Println("upgrade:", upgradeErr)
	}

	// Take the player's slot. m.mu is held from the first if through the last.
	claimed, ready := false, false
	if upgraded {
		m.mu.Lock()
		claimed = m.conns[player] == nil && !m.ended
	}
	if claimed {
		m.conns[player] = conn
		ready = m.conns[0] != nil && m.conns[1] != nil
	}
	if upgraded {
		m.mu.Unlock()
	}

	if upgraded && !claimed {
		conn.WriteJSON(Msg{Type: "end", Reason: "slot taken or match over"})
		conn.Close()
	}
	if claimed {
		log.Printf("[%s] player %d connected", m.id, player)
	}
	for p := 0; ready && p < 2; p++ {
		start := Msg{Type: "start", Player: p, Seed: m.seed}
		` ./main-send.sh ${v}st_ `
	}
	if ready {
		log.Printf("[%s] started, seed=%d", m.id, m.seed)
	}

	// Handle this player's messages until they disconnect or break the rules.
	// reason says why the match should end.
	var reason string
	for reading := claimed; reading; {
		` ./main-handle-ws-read.sh ${v}rd_ `
	}

	// End the match. Only the first handler to get here tells the players.
	endNow := false
	if claimed {
		m.mu.Lock()
		endNow = !m.ended
		m.ended = true
		m.mu.Unlock()
	}
	` ./main-notify-end.sh ${v}ne_ `
	` ./main-remove.sh ${v}rm_ `
EOF
