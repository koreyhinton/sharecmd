#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} M P

cat << EOF
	// Player p's connection, if they're connected.
	c := ${!m}.conns[${!p}]
	connected := c != nil
	var writeErr error
EOF
