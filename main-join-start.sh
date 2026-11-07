#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} M Matched

cat << EOF
	// Both players are in, so start playing.
	log.Printf("[%s] started, seed=%d", ${!m}.id, ${!m}.seed)
	${!matched} = true
EOF
