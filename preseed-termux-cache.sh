#!/usr/bin/env bash

set -Eeuo pipefail

# `run-as` starts outside Termux's normal launcher, so it does not export PREFIX.
export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

readonly blobs_base_url='https://blobs.brkn.lol'
readonly bw_item='blobs.brkn.lol private downloads'
readonly bw_username='termux-cache'

usage() {
  cat <<EOF
Usage: $(basename "$0")

Download and install the prebuilt Termux zinit/tmux cache. Run this before the
existing yadm initializer:

  curl -fsSL y.brkn.lol -L | bash
EOF
}

query_secret() {
  local prompt="$1"
  local secret

  read -rs -p "${prompt}: " secret < /dev/tty
  printf '\n' >&2

  if [[ -z "$secret" ]]
  then
    return 1
  fi

  printf '%s' "$secret"
}

install_rbw() {
  local tmpdir tag version url

  if command -v rbw >/dev/null 2>&1
  then
    return 0
  fi

  tmpdir=$(mktemp -d "${PREFIX}/tmp/yadm-init-rbw.XXXXXXXX")
  tag=$(curl -fsSI 'https://github.com/pschmitt/rbw/releases/latest' |
    awk 'tolower($1) == "location:" { gsub("\r", "", $2); count = split($2, parts, "/"); print parts[count] }')
  if [[ -z "$tag" ]]
  then
    rm -rf -- "$tmpdir"
    printf 'Could not determine the latest rbw release\n' >&2
    return 1
  fi

  version="${tag#v}"
  url="https://github.com/pschmitt/rbw/releases/download/${tag}/rbw-${version}-aarch64-linux-android.tar.gz"
  if ! curl -qfsSL -o "$tmpdir/rbw.tar.gz" "$url"
  then
    rm -rf -- "$tmpdir"
    printf 'Could not download rbw for Termux aarch64\n' >&2
    return 1
  fi

  tar -xzf "$tmpdir/rbw.tar.gz" -C "$tmpdir"
  install -m 700 "$tmpdir/rbw-${version}-aarch64-linux-android/rbw" "$PREFIX/bin/rbw"
  install -m 700 "$tmpdir/rbw-${version}-aarch64-linux-android/rbw-agent" "$PREFIX/bin/rbw-agent"
  rm -rf -- "$tmpdir"
}

upgrade_termux_packages() {
  local log

  log=$(mktemp)
  printf 'Updating Termux packages before downloading the cache...\n' >&2

  if ! apt update >"$log" 2>&1 || ! apt full-upgrade -y >>"$log" 2>&1
  then
    printf 'Failed to update Termux packages; output follows:\n' >&2
    cat "$log" >&2
    rm -f -- "$log"
    return 1
  fi

  rm -f -- "$log"
}

login_rbw() {
  local attempt password totp

  if rbw unlocked >/dev/null 2>&1
  then
    printf 'Bitwarden is already unlocked\n' >&2
    return 0
  fi

  rbw config set email "${RBW_EMAIL:-philipp@schmitt.co}"
  for attempt in 1 2 3
  do
    password=$(query_secret 'Bitwarden password')
    totp=$(query_secret 'Bitwarden TOTP code (blank if none)') || true

    if printf '%s\n' "$password" | rbw unlock --stdin --totp "$totp"
    then
      unset password totp
      return 0
    fi

    unset password totp
    printf 'Bitwarden login attempt %s/3 failed\n' "$attempt" >&2
  done

  printf 'Too many failed Bitwarden login attempts\n' >&2
  return 1
}

cleanup() {
  local exit_status=$?

  if [[ -n "${tmpdir:-}" ]]
  then
    rm -rf -- "$tmpdir"
  fi

  return "$exit_status"
}

main() {
  local architecture password archive_name archive_url
  local manifest_url

  if [[ "${1:-}" == -h || "${1:-}" == --help ]]
  then
    usage
    return 0
  fi

  if [[ "$#" -ne 0 ]]
  then
    printf 'Unexpected argument: %s\n' "$1" >&2
    usage >&2
    return 2
  fi

  if ! command -v termux-info >/dev/null 2>&1
  then
    printf 'This provisioner only runs inside Termux\n' >&2
    return 1
  fi

  architecture=$(dpkg --print-architecture)
  if [[ "$architecture" != aarch64 ]]
  then
    printf 'The published cache requires Termux aarch64; found %s\n' "$architecture" >&2
    return 1
  fi

  upgrade_termux_packages
  pkg install -y curl coreutils tar >/dev/null
  install_rbw
  login_rbw

  tmpdir=$(mktemp -d "${PREFIX}/tmp/yadm-init-cache.XXXXXXXX")
  chmod 0700 "$tmpdir"
  trap cleanup EXIT

  password=$(rbw get "$bw_item" -f password)
  if [[ ! "$password" =~ ^[[:alnum:]]{32,}$ ]]
  then
    unset password
    printf 'Bitwarden item has no supported password; expected at least 32 alphanumeric characters\n' >&2
    return 1
  fi

  printf 'machine blobs.brkn.lol login %s password %s\n' "$bw_username" "$password" > "$tmpdir/netrc"
  chmod 0600 "$tmpdir/netrc"
  unset password

  manifest_url="${blobs_base_url}/private/termux/zinit-cache-aarch64-latest.manifest"
  curl -qfsSL --netrc-file "$tmpdir/netrc" -o "$tmpdir/latest.manifest" "$manifest_url"
  archive_name=$(awk -F= '$1 == "archive" { print $2 }' "$tmpdir/latest.manifest")
  if [[ ! "$archive_name" =~ ^zinit-cache-aarch64-[[:xdigit:]]{16}-[0-9]{8}T[0-9]{6}Z\.tar\.gz$ ]]
  then
    printf 'Latest cache manifest contains an invalid archive name\n' >&2
    return 1
  fi
  if ! grep -Fxq 'arch=aarch64' "$tmpdir/latest.manifest"
  then
    printf 'Latest cache manifest is not for AArch64\n' >&2
    return 1
  fi

  archive_url="${blobs_base_url}/private/termux/${archive_name}"
  curl -qfsSL --netrc-file "$tmpdir/netrc" -o "$tmpdir/$archive_name" "$archive_url"
  curl -qfsSL --netrc-file "$tmpdir/netrc" -o "$tmpdir/$archive_name.sha256" "${archive_url}.sha256"
  unset archive_url

  if ! (cd "$tmpdir" && sha256sum --check --status "$archive_name.sha256")
  then
    printf 'Downloaded cache checksum does not match\n' >&2
    return 1
  fi

  if ! tar -tzf "$tmpdir/$archive_name" | awk '
    BEGIN { bad = 0 }
    /^\// || /(^|\/)\.\.($|\/)/ { bad = 1 }
    {
      split($0, parts, "/")
      if (parts[1] !~ /^(share|bin|lib)$/) bad = 1
    }
    END { exit bad }
  '
  then
    printf 'Downloaded cache contains an unsafe path\n' >&2
    return 1
  fi

  mkdir -p "$HOME/.local"
  tar -xzf "$tmpdir/$archive_name" -C "$HOME/.local"
  printf 'Installed verified Termux cache %s\n' "$archive_name"
  printf 'Next run the existing yadm initializer: curl -fsSL y.brkn.lol -L | bash\n'
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]
then
  main "$@"
fi

# vim: set ft=sh et ts=2 sw=2 :
