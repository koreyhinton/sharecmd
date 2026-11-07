#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} Reader Data Err When
export ${v}frm_Reader=${!reader}
export ${v}frm_Data=${!data}
export ${v}frm_Err=${!err}
export ${v}frm_Framing=framing

cat << EOF
	// Read one websocket message (RFC 6455, section 5). A message can be split
	// over several frames. Control frames in between are skipped, except a
	// close frame, which counts as a disconnect.
	for framing := ${!when}; framing; {
		` ./main-read-frame.sh ${v}frm_ `
	}
EOF
