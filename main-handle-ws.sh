#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S Req Code Body Player Found

cat << EOF
	// GET /ws?match=ID&player=N opens player N's websocket in the current match.
	query := ${!req}.URL.Query()
	var ${!player} int
	_, playerErr := fmt.Sscan(query.Get("player"), &${!player})
	validPlayer := playerErr == nil && ${!player} >= 0 && ${!player} <= 1
	if !validPlayer {
		${!code}, ${!body} = http.StatusBadRequest, "bad player\n"
	}
	${!found} := validPlayer && ${!s}.match != nil && ${!s}.match.id == query.Get("match")
	if validPlayer && !${!found} {
		${!code}, ${!body} = http.StatusNotFound, "no such match\n"
	}
EOF
