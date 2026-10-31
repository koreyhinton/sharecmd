#!/bin/sh
# Builds the browser version into web/.
# Serve it with:  python3 -m http.server 8000 -d web
set -e
cd "$(dirname "$0")"

cargo build --release --target wasm32-unknown-unknown
cp target/wasm32-unknown-unknown/release/lockstep-demo.wasm web/

# Copy the JS loader files from the exact miniquad and sapp-jsutils versions in
# Cargo.lock, so the JS always matches the Rust side.
cargo metadata --format-version 1 | python3 -c '
import json, os, sys
for p in json.load(sys.stdin)["packages"]:
    if p["name"] in ("miniquad", "sapp-jsutils"):
        print(os.path.dirname(p["manifest_path"]))
' | while read -r dir; do
    cp "$dir"/js/*.js web/
done

echo "Built web/. Serve it with: python3 -m http.server 8000 -d web"
