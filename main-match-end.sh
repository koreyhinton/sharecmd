#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S Matched

cat << EOF
	// Drop the match and go back to joining.
	${!s}.match = nil
	${!matched} = false
EOF
