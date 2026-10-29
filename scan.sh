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

# Thumbnails are frames decoded from the user's videos. They must not become
# world-readable just because the login umask is 022, so the cache is created
# private (0700) and repaired on every run in case it already existed.
umask 077

folder=${1:-}
cache=${2:-}
limit=${3:-120}

[[ -n $folder && -d $folder && -n $cache ]] || exit 0
mkdir -p -- "$cache" 2>/dev/null || exit 0
chmod 700 -- "$cache" 2>/dev/null

# The parent is ours as well (it only ever holds the thumbnails), but it is
# tightened only when it is literally named morph.livewall: scan.sh must never
# chmod a directory it did not create, whatever cache path it is handed.
parent=${cache%/*}
[[ ${parent##*/} == morph.livewall ]] && chmod 700 -- "$parent" 2>/dev/null

# Older versions created the cache with the ambient umask, so tighten any
# thumbnail that is still readable by group or others. Only our own files are
# touched; failures are ignored.
find "$cache" -maxdepth 1 -type f -name '*.jpg' ! -perm 600 \
  -exec chmod 600 -- {} + 2>/dev/null

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
