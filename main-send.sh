#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} M P Msg

cat << EOF
	// Send the message to player p. Once the match is over, only "end" still goes out.
	${!m}.mu.Lock()
	c := ${!m}.conns[${!p}]
	over := ${!m}.ended && ${!msg}.Type != "end"
	${!m}.mu.Unlock()
	canSend := c != nil && !over
	var writeErr error
	if canSend {
		${!m}.writeMu[${!p}].Lock()
		c.SetWriteDeadline(time.Now().Add(5 * time.Second))
		writeErr = c.WriteJSON(${!msg})
		${!m}.writeMu[${!p}].Unlock()
	}
	if writeErr != nil {
		log.Printf("[%s] write to p%d: %v", ${!m}.id, ${!p}, writeErr)
	}
EOF
