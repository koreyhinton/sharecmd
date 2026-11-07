#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} M P Reading Reader Data ReadErr

cat << EOF
	// Keep reading player p's messages until they've sent this turn, or
	// something ends the match.
	turnGot := ${!m}.got[${!m}.nextTurn]
	${!reading} = ${!m}.reason == "" && !(turnGot != nil && turnGot[${!p}])
	${!reader} := ${!m}.readers[${!p}]
	var ${!data} []byte
	var ${!read_err} error
EOF
