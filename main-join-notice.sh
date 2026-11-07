#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} M P Ready Expired

cat << EOF
	// Player p's notice: "start" if the match is ready, "end" if it expired.
	var out Msg
	if ${!ready} {
		out = Msg{Type: "start", Player: ${!p}, Seed: ${!m}.seed}
	}
	if ${!expired} {
		out = Msg{Type: "end", Reason: ${!m}.reason}
	}
EOF
