#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} M P Err

cat << EOF
	// Log a failed write to player p.
	if ${!err} != nil {
		log.Printf("[%s] write to p%d: %v", ${!m}.id, ${!p}, ${!err})
	}
EOF
