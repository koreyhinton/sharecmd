#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} M S Conn Player Reason Reading
export ${v}snd_M=${!m}
export ${v}snd_P=p
export ${v}snd_Msg=o

cat << EOF
	var msg Msg
	readErr := ${!conn}.ReadJSON(&msg)
	disconnected := readErr != nil
	if disconnected {
		${!reason} = fmt.Sprintf("player %d disconnected", ${!player})
		${!reading} = false
	}
	isCmds := !disconnected && msg.Type == "cmds"

	// m.mu is held from the first if isCmds through the last.
	if isCmds {
		${!m}.mu.Lock()
	}
	oldTurn := isCmds && msg.Turn < ${!m}.nextTurn
	// A normal client is never more than its input delay ahead. Anything far
	// past that is a bug or abuse, and storing it would let memory grow without limit.
	tooFar := isCmds && msg.Turn > ${!m}.nextTurn+${!s}.maxAhead
	if tooFar {
		${!reason} = fmt.Sprintf("player %d sent turn %d, more than %d turns ahead of turn %d",
			${!player}, msg.Turn, ${!s}.maxAhead, ${!m}.nextTurn)
		${!reading} = false
	}
	current := isCmds && !oldTurn && !tooFar
	if current && ${!m}.got[msg.Turn] == nil {
		${!m}.got[msg.Turn] = &[2]bool{}
		${!m}.pending[msg.Turn] = &[2][]json.RawMessage{}
	}
	// Only a player's first submission for a turn counts.
	accepted := current && !${!m}.got[msg.Turn][${!player}]
	if accepted {
		${!m}.got[msg.Turn][${!player}] = true
		${!m}.pending[msg.Turn][${!player}] = msg.Cmds
	}

	// Release every turn that both players have now submitted, in order.
	var out []Msg
	for accepted && ${!m}.got[${!m}.nextTurn] != nil && ${!m}.got[${!m}.nextTurn][0] && ${!m}.got[${!m}.nextTurn][1] {
		t := ${!m}.nextTurn
		out = append(out, Msg{Type: "turn", Turn: t, All: *${!m}.pending[t]})
		delete(${!m}.got, t)
		delete(${!m}.pending, t)
		${!m}.nextTurn++
	}
	if isCmds {
		${!m}.mu.Unlock()
	}

	for _, o := range out {
		for p := 0; p < 2; p++ {
			` ./main-send.sh ${v}snd_ `
		}
	}
EOF
