#!/usr/bin/env bash
# Shared checks for one bridge instance. Source this file; do not execute it.
# Paths come from the caller. This file has no default data directory.

repo_root() {
  local src
  src=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  CDPATH= cd -- "$src/.." && pwd
}

instance_validate() {
  local dir="$1"
  local repo real realrepo part realdeny
  if [[ -z "$dir" ]]; then
    echo "instance directory is required" >&2
    return 2
  fi
  if [[ "$dir" != /* ]]; then
    echo "instance directory must be absolute" >&2
    return 2
  fi
  repo=$(repo_root)
  real=$(realpath -m -- "$dir")
  realrepo=$(realpath -m -- "$repo")
  case "$real" in
    "$realrepo"|"$realrepo"/*)
      echo "instance directory must be outside the repository" >&2
      return 2
      ;;
  esac
  if [[ -n "${WA_DENY_INSTANCE_DIRS:-}" ]]; then
    local IFS=':'
    for part in $WA_DENY_INSTANCE_DIRS; do
      [[ -z "$part" ]] && continue
      if [[ "$part" != /* ]]; then
        echo "denied path must be absolute" >&2
        return 2
      fi
      if [[ -e "$part" ]]; then
        realdeny=$(realpath -- "$part")
      else
        realdeny=$(realpath -m -- "$part")
      fi
      case "$real" in
        "$realdeny"|"$realdeny"/*)
          echo "instance directory is denied" >&2
          return 2
          ;;
      esac
      case "$realdeny" in
        "$real"/*)
          echo "denied path is inside the instance directory" >&2
          return 2
          ;;
      esac
    done
  fi
  mkdir -p -- "$real"
  chmod 700 "$real"
  printf '%s\n' "$real"
}
