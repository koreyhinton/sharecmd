#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} M P WriteErr

cat << EOF
	// Log a failed write to player p.
	if ${!write_err} != nil {
		log.Printf("[%s] write to p%d: %v", ${!m}.id, ${!p}, ${!write_err})
	}
EOF
