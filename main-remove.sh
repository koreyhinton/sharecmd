#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S M When

cat << EOF
	// Drop the finished match. Safe to run more than once.
	${!s}.mu.Lock()
	isWaiting := ${!s}.waiting == ${!m}
	if ${!when} {
		delete(${!s}.matches, ${!m}.id)
	}
	if ${!when} && isWaiting {
		${!s}.waiting = nil
	}
	${!s}.mu.Unlock()
EOF
