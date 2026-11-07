#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S

cat << EOF
	// The match is ready once both players are connected, and expired if they
	// didn't both connect in time.
	waiting := ${!s}.match
	ready := waiting != nil && waiting.conns[0] != nil && waiting.conns[1] != nil
	expired := waiting != nil && !ready && !time.Now().Before(waiting.deadline)
	if expired {
		waiting.reason = "opponent didn't connect in time"
		log.Printf("[%s] ended: %s", waiting.id, waiting.reason)
	}
EOF
