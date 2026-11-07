#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} M When
export ${v}snd_M=${!m}
export ${v}snd_P=p
export ${v}snd_Msg=endMsg

cat << EOF
	// Tell both players why the match is over and close their connections.
	if ${!when} {
		log.Printf("[%s] ended: %s", ${!m}.id, ${!m}.reason)
	}
	for p := 0; ${!when} && p < 2; p++ {
		endMsg := Msg{Type: "end", Reason: ${!m}.reason}
		` ./main-send.sh ${v}snd_ `
		hasConn := ${!m}.conns[p] != nil
		if hasConn {
			${!m}.conns[p].Close()
		}
	}
EOF
