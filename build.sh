#!/bin/bash

orc=$(realpath ../orc/lib/src/main/bash/com/koreyhinton/nsmap)
export NSMAP="$orc"

./main.sh > ./main.go
