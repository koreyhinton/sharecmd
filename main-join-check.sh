#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S M Ready Expired

cat << EOF
	// The match is ready once both players are connected, and expired if they
	// didn't both connect in time.
	${!m} := ${!s}.match
	${!ready} := ${!m} != nil && ${!m}.players[0] != nil && ${!m}.players[1] != nil
	${!expired} := ${!m} != nil && !${!ready} && !time.Now().Before(${!m}.deadline)
	if ${!expired} {
		${!m}.reason = "opponent didn't connect in time"
		log.Printf("[%s] ended: %s", ${!m}.id, ${!m}.reason)
	}
EOF
