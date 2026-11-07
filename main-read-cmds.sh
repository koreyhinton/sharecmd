#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S M P Reading
export ${v}msg_Reader=reader
export ${v}msg_Data=data
export ${v}msg_Err=readErr
export ${v}msg_When=needs

cat << EOF
	// Read player p's next message, unless they've already sent this turn.
	turnGot := ${!m}.got[${!m}.nextTurn]
	needs := ${!m}.reason == "" && !(turnGot != nil && turnGot[${!p}])
	reader := ${!m}.readers[${!p}]
	var data []byte
	var readErr error
	` ./main-read-message.sh ${v}msg_ `
	disconnected := needs && readErr != nil
	if disconnected {
		${!m}.reason = fmt.Sprintf("player %d disconnected", ${!p})
	}

	// Only "cmds" messages count. Anything else is ignored.
	var msg Msg
	isCmds := needs && !disconnected && json.Unmarshal(data, &msg) == nil && msg.Type == "cmds"
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
	${!reading} = needs
EOF
