#!/bin/bash

orc=$(realpath ../orc/lib/src/main/bash/com/koreyhinton/nsmap)
export NSMAP="$orc"

set -o pipefail
./main.sh | gofmt > ./main.go
