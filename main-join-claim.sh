#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S Ws Code Body Player Upgraded Keep Taken

cat << EOF
	// A request that wasn't a websocket handshake gets a 400. A websocket takes
	// the player's slot, or is marked taken if the slot is in use.
	if !${!upgraded} {
		${!code}, ${!body} = http.StatusBadRequest, "not a websocket handshake\n"
	}
	claimed := ${!upgraded} && ${!s}.match.players[${!player}] == nil
	if claimed {
		${!s}.match.players[${!player}] = ${!ws}
		${!keep} = true
		log.Printf("[%s] player %d connected", ${!s}.match.id, ${!player})
	}
	${!taken} = ${!upgraded} && !claimed
EOF
