#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} M P Ready Expired Msg

cat << EOF
	// Player p's notice: "start" if the match is ready, "end" if it expired.
	var ${!msg} Msg
	if ${!ready} {
		${!msg} = Msg{Type: "start", Player: ${!p}, Seed: ${!m}.seed}
	}
	if ${!expired} {
		${!msg} = Msg{Type: "end", Reason: ${!m}.reason}
	}
EOF
