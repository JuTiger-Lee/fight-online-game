#!/usr/bin/env bash
# Export the Godot project for the web into build/web (deployed by Vercel).
set -euo pipefail
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
rm -rf build/web && mkdir -p build/web
"$GODOT" --headless --path . --import
"$GODOT" --headless --path . --export-release "Web" build/web/index.html
cp web/config.js web/supanet.js build/web/
echo "Built build/web:"; ls -lh build/web
