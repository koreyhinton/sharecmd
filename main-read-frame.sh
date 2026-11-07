#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} Reader Data Err Framing

cat << EOF
	// Header: the FIN bit and opcode, then the mask bit and a 7-bit length.
	var head [2]byte
	_, ${!err} = io.ReadFull(${!reader}, head[:])
	fin := head[0]&0x80 != 0
	opcode := head[0] & 0x0f
	masked := head[1]&0x80 != 0
	lenCode := head[1] & 0x7f
	size := uint64(lenCode)

	// A length code of 126 or 127 means the length follows, in 2 or 8 bytes.
	var ext [8]byte
	has16 := ${!err} == nil && lenCode == 126
	if has16 {
		_, ${!err} = io.ReadFull(${!reader}, ext[:2])
		size = uint64(binary.BigEndian.Uint16(ext[:2]))
	}
	has64 := ${!err} == nil && lenCode == 127
	if has64 {
		_, ${!err} = io.ReadFull(${!reader}, ext[:])
		size = binary.BigEndian.Uint64(ext[:])
	}

	// Messages are small JSON. Refuse large ones, so a bad client can't make
	// the server allocate without limit.
	tooBig := ${!err} == nil && size > maxMessage-uint64(len(${!data}))
	if tooBig {
		${!err} = errors.New("message too large")
	}

	// Client frames are masked with a 4-byte key.
	var mask [4]byte
	hasMask := ${!err} == nil && masked
	if hasMask {
		_, ${!err} = io.ReadFull(${!reader}, mask[:])
	}
	var payload []byte
	if ${!err} == nil {
		payload = make([]byte, size)
		_, ${!err} = io.ReadFull(${!reader}, payload)
	}
	for i := 0; masked && i < len(payload); i++ {
		payload[i] ^= mask[i%4]
	}

	// Opcodes: 0 continues a message, 1 is text, 2 is binary, 8 is close,
	// 9 and 10 are ping and pong.
	isClose := ${!err} == nil && opcode == 0x8
	if isClose {
		${!err} = io.EOF
	}
	isData := ${!err} == nil && opcode <= 0x2
	if isData {
		${!data} = append(${!data}, payload...)
	}
	${!framing} = ${!err} == nil && !(isData && fin)
EOF
