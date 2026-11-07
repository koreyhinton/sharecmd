#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} Conn Msg Err

cat << EOF
	// Write msg as one websocket text frame. Frames from the server aren't masked.
	payload, _ := json.Marshal(${!msg})
	frame := []byte{0x81} // FIN bit and the text opcode
	n := len(payload)
	small := n < 126
	medium := n >= 126 && n <= 0xffff
	large := n > 0xffff
	if small {
		frame = append(frame, byte(n))
	}
	if medium {
		frame = append(frame, 126)
		frame = binary.BigEndian.AppendUint16(frame, uint16(n))
	}
	if large {
		frame = append(frame, 127)
		frame = binary.BigEndian.AppendUint64(frame, uint64(n))
	}
	frame = append(frame, payload...)
	${!conn}.SetWriteDeadline(time.Now().Add(5 * time.Second))
	_, ${!err} = ${!conn}.Write(frame)
EOF
