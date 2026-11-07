#!/bin/bash

orc=$(realpath ../orc/lib/src/main/bash/com/koreyhinton/nsmap)
export NSMAP="$orc"
export ORC_WS=$(realpath -m ../orc/lib/src/templates/go/com/koreyhinton/ws)
export ORC_WS_VERSION=0.1.0
# A missing snippet fails inside main.sh's backticks without stopping the build.
if [ ! -d "$ORC_WS/snippets" ]; then
    echo "build.sh: $ORC_WS/snippets not found (is orc checked out with the ws snippets?)" >&2
    exit 1
fi

set -o pipefail
${ORC_WS}/models.sh "${ORC_WS_VERSION}" | gofmt > ./ws_models.go || exit 1
./main.sh | gofmt > ./main.go
