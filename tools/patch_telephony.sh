#!/usr/bin/env bash
# Patches the guest's telephony-common.jar so signal bars come from the
# modem's cell info (tools/patches/signal_from_cellinfo.py).
#
#   tools/patch_telephony.sh <in telephony-common.jar> <out telephony-common.jar>
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$ROOT/tools/patch_jar_classes.sh" "$ROOT/tools/patches/signal_from_cellinfo.py" "$1" "$2"
