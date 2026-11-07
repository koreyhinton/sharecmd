#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} M P Ws Connected WriteErr

cat << EOF
	// Player p's connection, if they're connected.
	${!ws} := ${!m}.players[${!p}]
	${!connected} := ${!ws} != nil
	var ${!write_err} error
EOF
