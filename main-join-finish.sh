#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S M Ready Expired Matched

cat << EOF
	// Drop an expired match, or start playing a ready one.
	if ${!expired} {
		${!s}.match = nil
	}
	if ${!ready} {
		log.Printf("[%s] started, seed=%d", ${!m}.id, ${!m}.seed)
		${!matched} = true
	}
EOF
