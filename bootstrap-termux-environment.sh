#!/usr/bin/env bash

set -Eeuo pipefail

export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
readonly blobs_base_url='https://blobs.brkn.lol'
readonly bw_item='blobs.brkn.lol private downloads'
readonly bw_username='termux-cache'
readonly files_dir="${PREFIX%/usr}"
readonly total_steps=4
step_number=0

if [[ -t 2 && -z "${NO_COLOR+x}" && "${TERM:-}" != dumb ]]
then
  readonly color_reset=$'\033[0m'
  readonly color_bold=$'\033[1m'
  readonly color_dim=$'\033[2m'
  readonly color_blue=$'\033[34m'
  readonly color_cyan=$'\033[36m'
  readonly color_green=$'\033[32m'
  readonly color_red=$'\033[31m'
else
  readonly color_reset=''
  readonly color_bold=''
  readonly color_dim=''
  readonly color_blue=''
  readonly color_cyan=''
  readonly color_green=''
  readonly color_red=''
fi

step() {
  step_number=$((step_number + 1))
  printf '\n%s[%d/%d]%s %s\n' \
    "$color_blue$color_bold" "$step_number" "$total_steps" \
    "$color_reset" "$1" >&2
}

banner() {
  printf '%s╭──────────────────────────────────────╮%s\n' "$color_cyan" "$color_reset" >&2
  printf '%s│   Termux environment bootstrap       │%s\n' "$color_cyan$color_bold" "$color_reset" >&2
  printf '%s╰──────────────────────────────────────╯%s\n\n' "$color_cyan" "$color_reset" >&2
}

success() {
  printf '  %s✓%s %s\n' "$color_green" "$color_reset" "$1" >&2
}

info() {
  printf '  %s›%s %s\n' "$color_cyan" "$color_reset" "$1" >&2
}

fail() {
  printf '\n%s✗ %s%s\n' "$color_red$color_bold" "$1" "$color_reset" >&2
}

progress_bar() {
  local title="$1"
  shift
  local log rc spinner=$'|/-\\' spin=0 pid

  log=$(mktemp)
  "$@" >"$log" 2>&1 &
  pid=$!
  if [[ -t 2 ]]
  then
    while kill -0 "$pid" 2>/dev/null
    do
      printf '\r  %s%s%s %s' "$color_dim" "${spinner:spin++%4:1}" "$color_reset" "$title" >&2
      sleep 0.2
    done
    printf '\r\033[2K' >&2
  fi

  if wait "$pid"
  then
    rm -f -- "$log"
    success "$title"
    return 0
  else
    rc=$?
    fail "$title failed (exit $rc); command output follows"
    cat "$log" >&2
    rm -f -- "$log"
    return "$rc"
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--archive-only]

Install the prepared Termux package and home archives, then run the existing
yadm initializer. --archive-only installs the archives and opens a fresh shell.

  curl -fsSL https://raw.githubusercontent.com/pschmitt/yadm-init/main/bootstrap-termux-environment.sh | bash
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

upgrade_termux_packages() {
  progress_bar 'Updating Termux base packages' bash -c \
    'apt update && apt-get -y -o Dpkg::Options::=--force-confold full-upgrade'
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
  if ! curl -qfSL --progress-bar -o "$tmpdir/rbw.tar.gz" "$url"
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

login_rbw() {
  local attempt email password totp

  if rbw unlocked >/dev/null 2>&1
  then
    printf 'Bitwarden is already unlocked\n' >&2
    return 0
  fi

  email="${RBW_EMAIL:-$(rbw config get email 2>/dev/null || true)}"
  if [[ -z "$email" ]]
  then
    read -r -p 'Bitwarden email: ' email < /dev/tty
  fi
  rbw config set email "$email"
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

manifest_value() {
  local key="$1"
  local manifest="$2"

  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1) }' "$manifest"
}

validate_archive_paths() {
  local archive="$1"
  local kind="$2"

  tar -tzf "$archive" | awk -v kind="$kind" '
    BEGIN { bad = 0 }
    /^\// || /(^|\/)\.\.($|\/)/ { bad = 1 }
    {
      split($0, parts, "/")
      if (kind == "prefix" && parts[1] != "usr") bad = 1
      if (kind == "home" && parts[1] !~ /^(bin|lib|share)$/) bad = 1
    }
    END { exit bad }
  '
}

cleanup() {
  local exit_status=$?

  if [[ -n "${tmpdir:-}" ]]
  then
    rm -rf -- "$tmpdir"
  fi
  if [[ -n "${stage_prefix:-}" && -d "$stage_prefix" ]]
  then
    rm -rf -- "$stage_prefix"
  fi

  return "$exit_status"
}

write_swap_helper() {
  local helper="$1"

  cat > "$helper" <<'EOF'
#!/system/bin/sh

set -eu

unset LD_PRELOAD

files_dir='/data/data/com.termux/files'
prefix="$files_dir/usr"
stage_prefix="$1"
tmpdir="$2"
run_yadm="$3"
backup="$files_dir/usr.bootstrap-backup"
toybox='/system/bin/toybox'

if [ -e "$backup" ]; then
  echo "A previous prefix backup exists at $backup; refusing to replace it" >&2
  exit 1
fi

if ! "$toybox" mv "$prefix" "$backup"; then
  echo 'Could not move the current Termux prefix aside' >&2
  exit 1
fi

if ! "$toybox" mv "$stage_prefix" "$prefix"; then
  "$toybox" mv "$backup" "$prefix"
  echo 'Could not install the prepared Termux prefix; restored the previous prefix' >&2
  exit 1
fi

if ! LD_PRELOAD="$prefix/lib/libtermux-exec.so" "$prefix/bin/bash" -c 'command -v dpkg-query >/dev/null && command -v curl >/dev/null'; then
  "$toybox" rm -rf "$prefix"
  "$toybox" mv "$backup" "$prefix"
  echo 'Prepared prefix failed its startup check; restored the previous prefix' >&2
  exit 1
fi

if ! PREFIX="$prefix" LD_PRELOAD="$prefix/lib/libtermux-exec.so" "$prefix/bin/ssh-keygen" -A; then
  "$toybox" rm -rf "$prefix"
  "$toybox" mv "$backup" "$prefix"
  echo 'Could not generate device-specific SSH host keys; restored the previous prefix' >&2
  exit 1
fi

"$toybox" rm -rf "$backup" "$tmpdir"
export PREFIX="$files_dir/usr"
export HOME="$files_dir/home"
export TMPDIR="$PREFIX/tmp"
export PATH="$PREFIX/bin:/system/bin"
export LD_PRELOAD="$PREFIX/lib/libtermux-exec.so"
cd "$HOME"

if [ "$run_yadm" = 1 ]; then
  export YADM_TERMUX_ARCHIVE_READY=1
  "$PREFIX/bin/bash" -lic 'set -euo pipefail; curl -fsSL y.brkn.lol -L | bash'
  unset YADM_TERMUX_ARCHIVE_READY
fi

exec "$PREFIX/bin/zsh" -li
EOF

  chmod 0700 "$helper"
}

main() {
  local run_yadm=1 architecture manifest_url password prefix_archive home_archive
  local prefix_sha256 home_sha256 prefix_url home_url
  local -a args=("$@")

  if [[ "${args[0]:-}" == -h || "${args[0]:-}" == --help ]]
  then
    usage
    return 0
  fi

  if [[ "${args[0]:-}" == --archive-only && "${#args[@]}" -eq 1 ]]
  then
    run_yadm=0
  elif [[ "${#args[@]}" -ne 0 ]]
  then
    printf 'Unexpected argument: %s\n' "${args[0]}" >&2
    usage >&2
    return 2
  fi

  if ! command -v termux-info >/dev/null 2>&1
  then
    fail 'This provisioner only runs inside Termux'
    return 1
  fi

  architecture=$(dpkg --print-architecture)
  if [[ "$architecture" != aarch64 ]]
  then
    fail "The published environment requires Termux aarch64; found $architecture"
    return 1
  fi

  banner
  step 'Prepare Termux and Bitwarden access'
  upgrade_termux_packages
  progress_bar 'Installing bootstrap tools' pkg install -y curl coreutils tar
  install_rbw
  success 'Bitwarden CLI is ready'
  login_rbw
  success 'Bitwarden is unlocked'

  step 'Fetch the private environment archives'
  mkdir -p "$HOME/.cache"
  chmod 0700 "$HOME/.cache"
  tmpdir=$(mktemp -d "${HOME}/.cache/yadm-init-environment.XXXXXXXX")
  chmod 0700 "$tmpdir"
  trap cleanup EXIT
  stage_prefix="${files_dir}/usr.bootstrap-new"
  if [[ -e "$stage_prefix" ]]
  then
    printf 'Refusing to overwrite an existing staged prefix: %s\n' "$stage_prefix" >&2
    return 1
  fi

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

  manifest_url="${blobs_base_url}/private/termux/termux-environment-aarch64-latest.manifest"
  info 'Authenticating to blobs.brkn.lol via the Bitwarden item'
  curl -qfsSL --netrc-file "$tmpdir/netrc" -o "$tmpdir/manifest" "$manifest_url"
  if [[ "$(manifest_value format "$tmpdir/manifest")" != 1 || "$(manifest_value arch "$tmpdir/manifest")" != aarch64 ]]
  then
    fail 'Environment manifest has an unsupported format or architecture'
    return 1
  fi

  prefix_archive=$(manifest_value prefix "$tmpdir/manifest")
  home_archive=$(manifest_value home "$tmpdir/manifest")
  prefix_sha256=$(manifest_value prefix_sha256 "$tmpdir/manifest")
  home_sha256=$(manifest_value home_sha256 "$tmpdir/manifest")
  if [[ ! "$prefix_archive" =~ ^termux-prefix-aarch64-[[:xdigit:]]{16}-[0-9]{8}T[0-9]{6}Z\.tar\.gz$ ||
    ! "$home_archive" =~ ^termux-home-aarch64-[[:xdigit:]]{16}-[0-9]{8}T[0-9]{6}Z\.tar\.gz$ ||
    ! "$prefix_sha256" =~ ^[[:xdigit:]]{64}$ || ! "$home_sha256" =~ ^[[:xdigit:]]{64}$ ]]
  then
    fail 'Environment manifest contains invalid archive metadata'
    return 1
  fi

  prefix_url="${blobs_base_url}/private/termux/${prefix_archive}"
  home_url="${blobs_base_url}/private/termux/${home_archive}"
  info 'Downloading package prefix (curl progress bar)'
  curl -qfSL --progress-bar --netrc-file "$tmpdir/netrc" -o "$tmpdir/$prefix_archive" "$prefix_url"
  info 'Downloading plugin and tool cache (curl progress bar)'
  curl -qfSL --progress-bar --netrc-file "$tmpdir/netrc" -o "$tmpdir/$home_archive" "$home_url"
  unset prefix_url home_url

  if ! printf '%s  %s\n' "$prefix_sha256" "$tmpdir/$prefix_archive" | sha256sum --check --status - ||
    ! printf '%s  %s\n' "$home_sha256" "$tmpdir/$home_archive" | sha256sum --check --status -
  then
    fail 'Downloaded Termux archive checksum does not match'
    return 1
  fi
  if ! validate_archive_paths "$tmpdir/$prefix_archive" prefix || ! validate_archive_paths "$tmpdir/$home_archive" home
  then
    fail 'Downloaded Termux archive contains an unsafe path'
    return 1
  fi

  step 'Verify and stage the prepared files'
  mkdir -p "$HOME/.local" "$files_dir"
  progress_bar 'Extracting plugin and tool cache' tar -xzf "$tmpdir/$home_archive" -C "$HOME/.local"
  success 'Plugin and tool cache extracted'
  mkdir -m 0700 "$stage_prefix"
  progress_bar 'Extracting Termux package prefix' tar -xzf "$tmpdir/$prefix_archive" --strip-components=1 -C "$stage_prefix"
  success 'Package prefix extracted'
  rm -f -- "$tmpdir/netrc" "$tmpdir/$prefix_archive" "$tmpdir/$home_archive" "$tmpdir/manifest"
  write_swap_helper "$tmpdir/swap-prefix.sh"
  trap - EXIT
  step 'Switch to the prepared Termux environment'
  info 'The installer keeps a rollback copy until basic startup checks pass'
  if [[ "$run_yadm" == 1 ]]
  then
    info 'After the switch, y.brkn.lol will clone your private yadm config and apply the Termux setup'
  fi
  success 'Archives passed checksum and path checks'
  exec /system/bin/sh "$tmpdir/swap-prefix.sh" "$stage_prefix" "$tmpdir" "$run_yadm"
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]
then
  main "$@"
fi

# vim: set ft=sh et ts=2 sw=2 :
