#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} M P Conn Err Expired

cat << EOF
	// Log a failed notice, and close player p's connection if the match expired.
	if ${!err} != nil {
		log.Printf("[%s] write to p%d: %v", ${!m}.id, ${!p}, ${!err})
	}
	closes := ${!expired} && ${!conn} != nil
	if closes {
		${!conn}.Close()
	}
EOF
