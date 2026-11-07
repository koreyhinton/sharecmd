#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S

cat << EOF
	// Play one turn. Turn m.nextTurn goes out once both players have sent it.
	// Read player 0's messages until they have, then player 1's. Anything else
	// that arrives on the way (early turns, repeats, old turns) is handled as
	// it's read.
	m := ${!s}.match
EOF
