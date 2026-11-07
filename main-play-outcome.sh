#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} M Ended Msg

cat << EOF
	// Send both players the turn, or, if something ended the match while
	// reading, tell them why it's over.
	${!ended} := ${!m}.reason != ""
	var ${!msg} Msg
	if !${!ended} {
		t := ${!m}.nextTurn
		${!msg} = Msg{Type: "turn", Turn: t, All: *${!m}.pending[t]}
		delete(${!m}.got, t)
		delete(${!m}.pending, t)
		${!m}.nextTurn++
	}
	if ${!ended} {
		${!msg} = Msg{Type: "end", Reason: ${!m}.reason}
		log.Printf("[%s] ended: %s", ${!m}.id, ${!m}.reason)
	}
EOF
