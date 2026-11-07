#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} M P Msg
export ${v}wf_Conn=c
export ${v}wf_Msg=${!msg}
export ${v}wf_Err=writeErr
export ${v}wf_When=connected

cat << EOF
	// Send the message to player p, if they're connected.
	c := ${!m}.conns[${!p}]
	connected := c != nil
	var writeErr error
	` ./main-write-frame.sh ${v}wf_ `
	if writeErr != nil {
		log.Printf("[%s] write to p%d: %v", ${!m}.id, ${!p}, writeErr)
	}
EOF
