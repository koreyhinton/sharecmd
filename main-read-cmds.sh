#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S M P Data ReadErr

cat << EOF
	// A failed read means player p disconnected.
	disconnected := ${!read_err} != nil
	if disconnected {
		${!m}.reason = fmt.Sprintf("player %d disconnected", ${!p})
	}

	// Only "cmds" messages count. Anything else is ignored.
	var msg Msg
	isCmds := !disconnected && json.Unmarshal(${!data}, &msg) == nil && msg.Type == "cmds"
	oldTurn := isCmds && msg.Turn < ${!m}.nextTurn
	// A normal client is never more than its input delay ahead. Anything far
	// past that is a bug or abuse, and storing it would let memory grow without limit.
	tooFar := isCmds && msg.Turn > ${!m}.nextTurn+${!s}.maxAhead
	if tooFar {
		${!m}.reason = fmt.Sprintf("player %d sent turn %d, more than %d turns ahead of turn %d",
			${!p}, msg.Turn, ${!s}.maxAhead, ${!m}.nextTurn)
	}
	current := isCmds && !oldTurn && !tooFar
	if current && ${!m}.got[msg.Turn] == nil {
		${!m}.got[msg.Turn] = &[2]bool{}
		${!m}.pending[msg.Turn] = &[2][]json.RawMessage{}
	}
	// Only a player's first submission for a turn counts.
	accepted := current && !${!m}.got[msg.Turn][${!p}]
	if accepted {
		${!m}.got[msg.Turn][${!p}] = true
		${!m}.pending[msg.Turn][${!p}] = msg.Cmds
	}
EOF
