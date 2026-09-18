#!/usr/bin/env bash
# Compatibility entry point. Never collect clipboard data in a shell variable
# or source the optional (unbounded) omarchy-dict library.
set -euo pipefail
exec python3 -I "$(dirname -- "${BASH_SOURCE[0]}")/bounded_io.py" selection "$@"
