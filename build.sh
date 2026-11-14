#!/usr/bin/env bash
# Compatibility wrapper. The real build logic lives in install.sh so there is
# only one dependency resolver and one set of logs.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec "$here/install.sh" --build "$@"
