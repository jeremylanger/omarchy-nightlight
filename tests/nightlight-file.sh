#!/usr/bin/env bash
# Checks nightlight-file.pl directly: plain reads and writes work, and no
# symlink anywhere on the path, the file or any directory above it, is
# followed. Needs only perl, so it runs without a Wayland session.
set -euo pipefail

helper=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/nightlight-file.pl
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT

failed=0
check() { # check <name> <expected exit> <command...>
  local name=$1 want=$2 got=0
  shift 2
  "$@" >/dev/null 2>&1 || got=$?
  if [[ $got == "$want" ]]; then echo "  ok  - $name"; else echo "  not ok - $name (exit $got, want $want)"; failed=1; fi
}

mkdir -p "$root/home/.config/hypr" "$root/outside/hypr"
conf=$root/home/.config/hypr/hyprsunset.conf

check "write a new config" 0 perl -- "$helper" write "$conf" "body"
[[ $(perl -- "$helper" read "$conf") == body ]] && echo "  ok  - read it back" || { echo "  not ok - read it back"; failed=1; }

check "mark" 0 perl -- "$helper" mark "$root/home/pending"
[[ $(perl -- "$helper" read "$conf" "$root/home/pending") == $'__PENDING__\nbody' ]] \
  && echo "  ok  - read reports the marker" || { echo "  not ok - read reports the marker"; failed=1; }

check "relative path is refused" 3 perl -- "$helper" write "relative/hyprsunset.conf" "body"
check "dot-dot component is refused" 3 perl -- "$helper" write "$root/home/../outside/hypr/x.conf" "body"

ln -s "$root/outside/hypr" "$root/home/.config/linked"
check "symlinked parent: write refused" 3 perl -- "$helper" write "$root/home/.config/linked/hyprsunset.conf" "evil"
ln -s "$root/outside" "$root/home/linked-config"
check "symlinked ancestor: write refused" 3 perl -- "$helper" write "$root/home/linked-config/hypr/hyprsunset.conf" "evil"
check "symlinked ancestor: read refused" 3 perl -- "$helper" read "$root/home/linked-config/hypr/hyprsunset.conf"
perl -- "$helper" mark "$root/home/linked-config/hypr/pending" || true
check "symlinked ancestor: mark refused" 1 test -e "$root/outside/hypr/pending"
[[ -z $(ls -A "$root/outside/hypr") ]] && echo "  ok  - nothing written outside" || { echo "  not ok - nothing written outside"; failed=1; }

ln -s "$root/outside/hypr/target" "$root/home/.config/hypr/link.conf"
check "symlinked file: write refused" 3 perl -- "$helper" write "$root/home/.config/hypr/link.conf" "evil"

[[ $failed == 0 ]] && echo "PASS nightlight-file" || echo "FAIL nightlight-file"
exit "$failed"
