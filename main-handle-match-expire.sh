#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} M S
export ${v}ne_M=${!m}
export ${v}ne_Reason=reason
export ${v}ne_When=expired
export ${v}rm_S=${!s}
export ${v}rm_M=${!m}
export ${v}rm_When=expired

cat << EOF
	${!m}.mu.Lock()
	expired := !${!m}.ended && (${!m}.conns[0] == nil || ${!m}.conns[1] == nil)
	if expired {
		${!m}.ended = true // set under the lock so a late connect is rejected
	}
	${!m}.mu.Unlock()

	reason := "opponent didn't connect in time"
	` ./main-notify-end.sh ${v}ne_ `
	` ./main-remove.sh ${v}rm_ `
EOF
