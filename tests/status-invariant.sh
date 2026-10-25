#!/bin/bash
# Development-only check for the running daemon (needs omarchy-shell + jq).
#
#   tests/status-invariant.sh [samples] [interval-seconds]
#
# Invariant: a monitor that reports a pause reason must either be frozen
# (paused=true) or still inside the 2 s grace window after a start
# (pausing=true). Anything else means the status is misleading.

set -u

samples=${1:-12}
interval=${2:-0.5}
fails=0

for ((i = 1; i <= samples; i++)); do
  json=$(omarchy-shell morph.livewall status 2>/dev/null) || {
    echo "status IPC failed"
    exit 1
  }
  bad=$(printf '%s' "$json" | jq -r \
    '.monitors[] | select(.reason != "" and (.paused != true) and (.pausing != true)) | .name' \
    2>/dev/null)
  if [[ -n $bad ]]; then
    echo "VIOLATION sample $i: $bad"
    printf '%s\n' "$json" | jq -c '.monitors'
    fails=1
  fi
  sleep "$interval"
done

if ((fails == 0)); then
  echo "status invariant ok ($samples samples)"
fi
exit "$fails"
