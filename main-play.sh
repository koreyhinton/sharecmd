#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S Matched
export ${v}rd_S=${!s}
export ${v}rd_M=m
export ${v}rd_P=p
export ${v}rd_Reading=reading
export ${v}snd_M=m
export ${v}snd_P=p
export ${v}snd_Msg=out
export ${v}ne_M=m
export ${v}ne_When=ended

cat << EOF
	// Play one turn. Turn m.nextTurn goes out once both players have sent it.
	// Read player 0's messages until they have, then player 1's. Anything else
	// that arrives on the way (early turns, repeats, old turns) is handled as
	// it's read.
	m := ${!s}.match
	for p := 0; p < 2; p++ {
		for reading := true; reading; {
			` ./main-read-cmds.sh ${v}rd_ `
		}
	}

	release := m.reason == ""
	var out Msg
	if release {
		t := m.nextTurn
		out = Msg{Type: "turn", Turn: t, All: *m.pending[t]}
		delete(m.got, t)
		delete(m.pending, t)
		m.nextTurn++
	}
	for p := 0; release && p < 2; p++ {
		` ./main-send.sh ${v}snd_ `
	}

	// End the match once something has ended it, and go back to joining.
	ended := m.reason != ""
	` ./main-notify-end.sh ${v}ne_ `
	if ended {
		${!s}.match = nil
		${!matched} = false
	}
EOF
