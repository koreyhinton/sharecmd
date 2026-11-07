#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} Ws

cat << EOF
	// Close player p's connection.
	${!ws}.Conn.Close()
EOF
