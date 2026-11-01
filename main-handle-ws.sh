#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} R W

cat << EOF
	id := ${!r}.URL.Query().Get("match")
	var player int
	if _, err := fmt.Sscan(${!r}.URL.Query().Get("player"), &player); err != nil || player < 0 || player > 1 {
		http.Error(${!w}, "bad player", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	m := s.matches[id]
	s.mu.Unlock()
	if m == nil {
		http.Error(${!w}, "no such match", http.StatusNotFound)
		return
	}

	conn, err := upgrader.Upgrade(${!w}, ${!r}, nil)
	if err != nil {
		log.Println("upgrade:", err)
		return
	}

	m.mu.Lock()
	if m.conns[player] != nil || m.ended {
		m.mu.Unlock()
		conn.WriteJSON(Msg{Type: "end", Reason: "slot taken or match over"})
		conn.Close()
		return
	}
	m.conns[player] = conn
	ready := m.conns[0] != nil && m.conns[1] != nil
	m.mu.Unlock()

	log.Printf("[%s] player %d connected", m.id, player)
	if ready {
		for p := 0; p < 2; p++ {
			m.send(p, Msg{Type: "start", Player: p, Seed: m.seed})
		}
		log.Printf("[%s] started, seed=%d", m.id, m.seed)
	}

	m.end(m.readLoop(player, conn, s.maxAhead))
	s.remove(m)
EOF
