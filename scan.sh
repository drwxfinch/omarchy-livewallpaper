#!/bin/bash
# Directory scan for the Livewall panel.
#
#   scan.sh <folder> <thumbnail-cache> [limit]
#
# Prints one line per video, newest first:
#
#   mtime <TAB> has-thumbnail <TAB> path <TAB> thumbnail-path
#
# The panel runs this as a single process so the QML side never touches the
# filesystem, and the cache is consulted here so ffmpeg is only asked for
# frames that are actually missing.

set -u

folder=${1:-}
cache=${2:-}
limit=${3:-120}

[[ -n $folder && -d $folder && -n $cache ]] || exit 0
mkdir -p -- "$cache" 2>/dev/null || exit 0

find -L "$folder" -maxdepth 3 -type f \
  \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' \
     -o -iname '*.mov' -o -iname '*.gif' \) \
  -printf '%T@\t%p\n' 2>/dev/null |
  sort -t $'\t' -k1,1 -nr |
  head -n "$limit" |
  while IFS=$'\t' read -r mtime path; do
    key=$(printf '%s\t%s' "$path" "$mtime" | md5sum | cut -d' ' -f1)
    thumb="$cache/$key.jpg"
    if [[ -f $thumb ]]; then ready=1; else ready=0; fi
    printf '%s\t%s\t%s\t%s\n' "$mtime" "$ready" "$path" "$thumb"
  done
