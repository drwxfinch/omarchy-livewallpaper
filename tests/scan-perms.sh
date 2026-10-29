#!/bin/bash
# Checks that the thumbnail cache never becomes readable by other accounts.
#
#   tests/scan-perms.sh
#
# The scenario: a login umask of 022, a cache directory that already exists
# with the old 0755 mode, and an old 0644 thumbnail inside it. After one scan
# the thumbnail directory must be 0700, its morph.livewall parent 0700, and
# every thumbnail 0600 - no matter what mode the source video or folder has.

set -u

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scan="$here/../scan.sh"
fail=0

check() {
  local want=$1 path=$2 got
  got=$(stat -c '%a' -- "$path" 2>/dev/null) || got="missing"
  if [[ $got != "$want" ]]; then
    echo "FAIL $path: mode $got, expected $want"
    fail=1
  fi
}

tmp=$(mktemp -d) || exit 1
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p -- "$tmp/videos"
printf 'x' >"$tmp/videos/a.mp4"
chmod 700 -- "$tmp/videos"
chmod 600 -- "$tmp/videos/a.mp4"

# Simulate a cache written by an older version under umask 022.
cache="$tmp/cache/morph.livewall/thumbs"
mkdir -p -- "$cache"
chmod 755 -- "$tmp/cache/morph.livewall" "$cache"
thumb="$cache/0123456789abcdef0123456789abcdef.jpg"
printf 'jpeg' >"$thumb"
chmod 644 -- "$thumb"

(
  umask 022
  bash "$scan" "$tmp/videos" "$cache" >/dev/null
) || { echo "FAIL scan.sh exited non-zero"; exit 1; }

check 700 "$cache"
check 700 "$tmp/cache/morph.livewall"
check 600 "$thumb"

# A fresh cache must be private from the start, not repaired afterwards.
fresh="$tmp/fresh/morph.livewall/thumbs"
(
  umask 022
  bash "$scan" "$tmp/videos" "$fresh" >/dev/null
) || { echo "FAIL scan.sh exited non-zero"; exit 1; }
check 700 "$fresh"
check 700 "$tmp/fresh/morph.livewall"

# scan.sh must not chmod a parent directory it does not own.
mkdir -p -- "$tmp/other/thumbs"
chmod 755 -- "$tmp/other"
(
  umask 022
  bash "$scan" "$tmp/videos" "$tmp/other/thumbs" >/dev/null
)
check 755 "$tmp/other"
check 700 "$tmp/other/thumbs"

# ffmpeg writes the thumbnail itself; the panel wraps it in umask 077.
(
  umask 022
  bash -c 'umask 077; exec touch "$1"' livewall-thumb "$tmp/fresh.jpg"
)
check 600 "$tmp/fresh.jpg"

if ((fail == 0)); then
  echo "scan perms ok"
fi
exit "$fail"
