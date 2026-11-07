#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} M P Conn Connected Err

cat << EOF
	// Player p's connection, if they're connected.
	${!conn} := ${!m}.conns[${!p}]
	${!connected} := ${!conn} != nil
	var ${!err} error
EOF
