#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} Conn

cat << EOF
	// Close player p's connection.
	${!conn}.Close()
EOF
