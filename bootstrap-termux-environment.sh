#!/usr/bin/env bash

set -Eeuo pipefail

export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
readonly blobs_base_url='https://blobs.brkn.lol'
readonly bw_item='blobs.brkn.lol private downloads'
readonly bw_username='termux-cache'
readonly nixpp_binary_name='nixpp-aarch64-latest'
readonly nixpp_channel_name='termux-nix-cache-aarch64-latest.manifest'
readonly nixpp_cache_url="${blobs_base_url}/private/termux/cache"
readonly nixpp_cache_public_key='rofl-13:ESRCqy2jcftg690k98KSNqF6LgOqz1X7ZnXXE//WWD0='
readonly files_dir="${PREFIX%/usr}"
rbw_tmpdir=''
RBW_BIN=''
readonly total_steps=4
step_number=0
force_yes=0
prefix_confirmed=0
color_reset=''
color_bold=''
color_dim=''
color_blue=''
color_cyan=''
color_green=''
color_red=''
color_yellow=''

init_ui() {
  if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]]
  then
    color_reset=$'\033[0m'
    color_bold=$'\033[1m'
    color_dim=$'\033[2m'
    color_blue=$'\033[34m'
    color_cyan=$'\033[36m'
    color_green=$'\033[32m'
    color_red=$'\033[31m'
    color_yellow=$'\033[33m'
  fi
}

step() {
  step_number=$((step_number + 1))
  printf '\n%sStep %d of %d%s  %s\n' \
    "$color_blue$color_bold" "$step_number" "$total_steps" \
    "$color_reset" "$1" >&2
}

banner() {
  printf '%s%sTermux environment setup%s\n' "$color_cyan" "$color_bold" "$color_reset" >&2
  printf 'Downloads and verifies the prepared AArch64 environment, then starts setup.\n' >&2
}

success() {
  printf '  %s✓%s %s\n' "$color_green" "$color_reset" "$1" >&2
}

info() {
  printf '  %s›%s %s\n' "$color_cyan" "$color_reset" "$1" >&2
}

warn() {
  printf '  %s!%s %s\n' "$color_yellow" "$color_reset" "$1" >&2
}

fail() {
  printf '\n%s✗ %s%s\n' "$color_red$color_bold" "$1" "$color_reset" >&2
}

download_file() {
  local description="$1"
  local netrc_file="$2"
  local destination="$3"
  local url="$4"
  local -a curl_options=(-qfSL --netrc-file "$netrc_file")

  if [[ -t 2 && "${TERM:-}" != dumb ]]
  then
    curl_options+=(--progress-bar)
  else
    curl_options+=(-s)
  fi
  if ! curl "${curl_options[@]}" -o "$destination" "$url"
  then
    fail "Could not download $description. Check your network and try again."
    return 1
  fi
}

fetch_cache_output() {
  local description="$1"
  local store_path="$2"
  local destination="$3"

  info "Downloading $description; transfer progress appears when available"
  if ! "$tmpdir/nixpp" fetch \
    --cache "$nixpp_cache_url" \
    --store-path "$store_path" \
    --destination "$destination" \
    --netrc-file "$tmpdir/netrc" \
    --public-key "$nixpp_cache_public_key"
  then
    fail "Could not download or verify $description."
    info 'Check the network and Bitwarden access; the current package tree is still active.'
    return 1
  fi
  success "$description downloaded and verified"
}

progress_bar() {
  local title="$1"
  shift
  local log rc spinner=$'|/-\\' spin=0 pid started elapsed animate=0

  log=$(mktemp "${PREFIX}/tmp/yadm-init-step.XXXXXXXX") || return
  started=$SECONDS
  if [[ -t 2 && "${TERM:-}" != dumb ]]
  then
    animate=1
  else
    info "$title is in progress..."
  fi
  "$@" >"$log" 2>&1 &
  pid=$!
  if ((animate))
  then
    while kill -0 "$pid" 2>/dev/null
    do
      elapsed=$((SECONDS - started))
      printf '\r  %s%s%s %s (%ds)' \
        "$color_dim" "${spinner:spin++%4:1}" "$color_reset" "$title" "$elapsed" >&2
      /system/bin/sleep 0.2
    done
    printf '\r\033[2K' >&2
  fi

  if wait "$pid"
  then
    elapsed=$((SECONDS - started))
    rm -f -- "$log"
    success "$title (${elapsed}s)"
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
Usage: $(basename "$0") [OPTIONS]

Install the prepared Termux environment, then run the existing yadm initializer.
This replaces the package tree under \$PREFIX; files in \$HOME are kept.

Options:
  --archive-only  Install the archives and open a fresh shell without yadm setup.
  --yes           Skip the package-tree replacement confirmation.
  --no-color      Disable colored output (also honors NO_COLOR).
  -h, --help      Show this help.

  curl -fsSL https://raw.githubusercontent.com/pschmitt/yadm-init/main/bootstrap-termux-environment.sh | bash
EOF
}

confirm_prefix_replacement() {
  local answer

  warn "This replaces the Termux package tree at $PREFIX."
  info 'Your home directory is kept; the yadm initializer may update its own files afterward.'
  if ((force_yes))
  then
    prefix_confirmed=1
    return 0
  fi
  if [[ ! -r /dev/tty ]]
  then
    fail 'A terminal is required for confirmation and Bitwarden unlock.'
    info 'Run this from the Termux app, or pass --yes to confirm replacement non-interactively.'
    return 1
  fi

  printf 'Continue? [y/N] ' >&2
  if ! IFS= read -r answer < /dev/tty
  then
    fail 'Could not read the confirmation response.'
    return 1
  fi
  if [[ "${answer,,}" != y && "${answer,,}" != yes ]]
  then
    info 'Cancelled. No package-tree changes were made.'
    return 0
  fi
  prefix_confirmed=1
}

query_secret() {
  local prompt="$1"
  local secret

  if ! read -r -s -p "${prompt}: " secret < /dev/tty
  then
    printf '\nCould not read input from the terminal. Run this in the Termux app.\n' >&2
    return 1
  fi
  printf '\n' >&2

  if [[ -z "$secret" ]]
  then
    return 1
  fi

  printf '%s' "$secret"
}

require_bootstrap_tools() {
  local command
  for command in curl tar sha256sum xz
  do
    if ! command -v "$command" >/dev/null 2>&1
    then
      fail "The initial Termux installation is missing '$command'."
      info 'Open Termux and install its standard bootstrap packages, then retry.'
      return 1
    fi
  done
}

install_rbw() {
  local tag version url

  rbw_tmpdir=$(mktemp -d "${PREFIX}/tmp/yadm-init-rbw.XXXXXXXX")
  tag=$(curl -fsSI 'https://github.com/pschmitt/rbw/releases/latest' |
    awk 'tolower($1) == "location:" { gsub("\r", "", $2); count = split($2, parts, "/"); print parts[count] }')
  if [[ -z "$tag" ]]
  then
    printf 'Could not determine the latest rbw release\n' >&2
    return 1
  fi

  version="${tag#v}"
  url="https://github.com/pschmitt/rbw/releases/download/${tag}/rbw-${version}-aarch64-linux-android.tar.gz"
  if ! curl -qfSL --progress-bar -o "$rbw_tmpdir/rbw.tar.gz" "$url"
  then
    printf 'Could not download rbw for Termux aarch64\n' >&2
    return 1
  fi

  tar -xzf "$rbw_tmpdir/rbw.tar.gz" -C "$rbw_tmpdir"
  install -m 700 "$rbw_tmpdir/rbw-${version}-aarch64-linux-android/rbw" "$rbw_tmpdir/rbw"
  install -m 700 "$rbw_tmpdir/rbw-${version}-aarch64-linux-android/rbw-agent" "$rbw_tmpdir/rbw-agent"
  RBW_BIN="$rbw_tmpdir/rbw"
  export PATH="$rbw_tmpdir:$PATH"
}

login_rbw() {
  local attempt email password totp

  if "$RBW_BIN" unlocked >/dev/null 2>&1
  then
    printf 'Bitwarden is already unlocked\n' >&2
    return 0
  fi

  email="${RBW_EMAIL:-$("$RBW_BIN" config get email 2>/dev/null || true)}"
  if [[ -z "$email" ]]
  then
    read -r -p 'Bitwarden email: ' email < /dev/tty
  fi
  "$RBW_BIN" config set email "$email"
  for attempt in 1 2 3
  do
    password=$(query_secret 'Bitwarden password')
    totp=$(query_secret 'Bitwarden TOTP code (blank if none)') || true

    if printf '%s\n' "$password" | "$RBW_BIN" unlock --stdin --totp "$totp"
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

valid_store_path() {
  [[ "$1" =~ ^/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9._+-]+$ ]]
}

read_cache_channel() {
  local channel_file="$1"
  local key value
  local format='' architecture=''
  local -A seen=()
  nixpp_store_path=''
  prefix_store_path=''
  native_store_path=''

  while IFS='=' read -r key value
  do
    if [[ -z "$key" || -z "$value" || "$key" =~ [^a-z_] || "$value" =~ [[:space:]] ]]
    then
      printf 'Invalid cache channel line\n' >&2
      return 1
    fi
    if [[ -n "${seen[$key]:-}" ]]
    then
      printf 'Duplicate cache channel field: %s\n' "$key" >&2
      return 1
    fi
    seen[$key]=1

    case "$key" in
      format)
        format=$value
        ;;
      arch)
        architecture=$value
        ;;
      nixpp)
        nixpp_store_path=$value
        ;;
      prefix)
        prefix_store_path=$value
        ;;
      native)
        native_store_path=$value
        ;;
      *)
        printf 'Unexpected cache channel field: %s\n' "$key" >&2
        return 1
        ;;
    esac
  done < "$channel_file"

  if [[ "$format" != 1 || "$architecture" != aarch64 ]] ||
    ! valid_store_path "$nixpp_store_path" ||
    ! valid_store_path "$prefix_store_path" ||
    ! valid_store_path "$native_store_path"
  then
    printf 'Cache channel is incomplete or targets an unsupported environment\n' >&2
    return 1
  fi
}

cleanup() {
  local exit_status=$?

  if [[ -n "${tmpdir:-}" ]]
  then
    rm -rf -- "$tmpdir"
  fi
  if [[ -n "${rbw_tmpdir:-}" ]]
  then
    rm -rf -- "$rbw_tmpdir"
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
native_archive="$4"
native_sha256="$5"
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

export PREFIX="$files_dir/usr"
export HOME="$files_dir/home"
export TMPDIR="$PREFIX/tmp"
export PATH="$PREFIX/bin:/system/bin"
export LD_PRELOAD="$PREFIX/lib/libtermux-exec.so"
cd "$HOME"

if ! "$PREFIX/bin/bash" "$tmpdir/native-package/bootstrap.sh" install "$native_archive" "$native_sha256"; then
  "$toybox" rm -rf "$tmpdir"
  echo 'The package tree is active, but the managed Termux generation could not be installed.' >&2
  echo "Your previous package tree is preserved at: $backup" >&2
  exit 1
fi

if [ "$run_yadm" = 1 ]; then
  export YADM_TERMUX_ARCHIVE_READY=1
  if ! "$PREFIX/bin/bash" -lc 'set -euo pipefail; curl -fsSL y.brkn.lol -L | bash'; then
    unset YADM_TERMUX_ARCHIVE_READY
    "$toybox" rm -rf "$tmpdir"
    echo 'The Termux environment is installed, but yadm setup did not finish.' >&2
    echo "Your previous package tree is preserved at: $backup" >&2
    echo 'To restore it from Termux, run:' >&2
    echo "  /system/bin/toybox rm -rf '$prefix'" >&2
    echo "  /system/bin/toybox mv '$backup' '$prefix'" >&2
    exit 1
  fi
  unset YADM_TERMUX_ARCHIVE_READY
  echo 'Termux and yadm setup are complete.' >&2
else
  echo 'The Termux archives are installed. Yadm setup was skipped.' >&2
fi

"$toybox" rm -rf "$backup" "$tmpdir"
echo 'Opening your Zsh session. Type exit to return to Termux.' >&2
exec "$PREFIX/bin/zsh" -li
EOF

  chmod 0700 "$helper"
}

main() {
  local run_yadm=1 architecture password prefix_archive native_archive native_sha256 native_filename nixpp_sha256
  local arg

  while (($# > 0))
  do
    case "$1" in
      --archive-only)
        run_yadm=0
        ;;
      --yes)
        force_yes=1
        ;;
      --no-color)
        NO_COLOR=1
        export NO_COLOR
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        arg=$1
        printf 'Unknown option: %s\n' "$arg" >&2
        usage >&2
        return 2
        ;;
    esac
    shift
  done

  init_ui

  if [[ ! -x "$PREFIX/bin/pkg" ]]
  then
    fail 'This provisioner only runs inside Termux'
    return 1
  fi

  banner
  if [[ "$PREFIX" != /data/data/com.termux/files/usr ]]
  then
    fail "Unexpected Termux prefix: $PREFIX"
    info 'This release is built for the official Termux app with its standard package prefix.'
    return 1
  fi

  if [[ -e "$files_dir/usr.bootstrap-backup" ]]
  then
    fail 'A previous setup left the original package tree backed up.'
    info "Backup: $files_dir/usr.bootstrap-backup"
    info 'Restore it in Termux with:'
    printf '  /system/bin/toybox rm -rf %q && /system/bin/toybox mv %q %q\n' \
      "$PREFIX" "$files_dir/usr.bootstrap-backup" "$PREFIX" >&2
    return 1
  fi
  if [[ -e "$files_dir/usr.bootstrap-new" ]]
  then
    fail 'An interrupted setup left a staged package tree.'
    info 'The staged tree is inactive. Remove it in Termux, then retry:'
    printf '  /system/bin/toybox rm -rf %q\n' "$files_dir/usr.bootstrap-new" >&2
    return 1
  fi

  architecture=$(dpkg --print-architecture)
  if [[ "$architecture" != aarch64 ]]
  then
    fail "The published environment requires Termux aarch64; found $architecture"
    return 1
  fi

  info "Detected Termux aarch64; $(df -h "$HOME" | awk 'END { print $4 " available on app storage" }')"
  confirm_prefix_replacement || return
  if ((!prefix_confirmed))
  then
    return 0
  fi

  step 'Prepare Termux and Bitwarden access'
  require_bootstrap_tools || return
  trap cleanup EXIT
  install_rbw
  success 'Bitwarden CLI is ready'
  login_rbw
  success 'Bitwarden is unlocked'

  step 'Connect to your private download cache'
  mkdir -p "$HOME/.cache"
  chmod 0700 "$HOME/.cache"
  tmpdir=$(mktemp -d "${HOME}/.cache/yadm-init-environment.XXXXXXXX")
  chmod 0700 "$tmpdir"
  stage_prefix="${files_dir}/usr.bootstrap-new"
  if [[ -e "$stage_prefix" ]]
  then
    printf 'Refusing to overwrite an existing staged prefix: %s\n' "$stage_prefix" >&2
    return 1
  fi

  if ! password=$("$RBW_BIN" get "$bw_item" -f password)
  then
    fail 'Could not read the private-download password from Bitwarden.'
    info "Unlock rbw and check the Bitwarden item named '$bw_item'."
    return 1
  fi
  if [[ ! "$password" =~ ^[[:alnum:]]{32,}$ ]]
  then
    unset password
    printf 'Bitwarden item has no supported password; expected at least 32 alphanumeric characters\n' >&2
    return 1
  fi

  printf 'machine blobs.brkn.lol login %s password %s\n' "$bw_username" "$password" > "$tmpdir/netrc"
  chmod 0600 "$tmpdir/netrc"
  unset password

  info 'Checking your private download access'
  if ! curl -qfsSL --netrc-file "$tmpdir/netrc" \
    -o "$tmpdir/$nixpp_channel_name" \
    "${blobs_base_url}/private/termux/${nixpp_channel_name}"
  then
    fail 'Could not reach the private download channel.'
    info 'Check your network and Bitwarden download credentials, then rerun the command.'
    return 1
  fi
  if ! read_cache_channel "$tmpdir/$nixpp_channel_name"
  then
    fail 'The private Nix cache channel manifest is invalid'
    return 1
  fi

  info 'Downloading the small cache verifier'
  download_file 'the cache verifier' "$tmpdir/netrc" "$tmpdir/nixpp" \
    "${blobs_base_url}/private/termux/${nixpp_binary_name}"
  curl -qfsSL --netrc-file "$tmpdir/netrc" \
    -o "$tmpdir/nixpp.sha256" \
    "${blobs_base_url}/private/termux/${nixpp_binary_name}.sha256"
  nixpp_sha256=$(awk 'NR == 1 { print $1 }' "$tmpdir/nixpp.sha256")
  if [[ ! "$nixpp_sha256" =~ ^[[:xdigit:]]{64}$ ]] ||
    ! printf '%s  %s\n' "$nixpp_sha256" "$tmpdir/nixpp" | sha256sum --check --status -
  then
    fail 'The first-stage nixpp checksum is invalid'
    return 1
  fi
  chmod 0700 "$tmpdir/nixpp"
  "$tmpdir/nixpp" --help >/dev/null

  fetch_cache_output 'the Termux package archive' \
    "$prefix_store_path" "$tmpdir/prefix-package"
  fetch_cache_output 'the managed Termux shell generation' \
    "$native_store_path" "$tmpdir/native-package"

  prefix_archive="$tmpdir/prefix-package/share/termux/termux-prefix.tar.gz"
  native_archive="$tmpdir/native-package/environment.tar.gz"
  if [[ ! -s "$prefix_archive" || ! -s "$native_archive" || ! -s "$tmpdir/native-package/SHA256SUMS" ]]
  then
    fail 'The signed Nix outputs do not contain the expected Termux archives'
    return 1
  fi
  native_sha256=''
  native_filename=''
  IFS=' ' read -r native_sha256 native_filename < "$tmpdir/native-package/SHA256SUMS"
  if [[ ! "$native_sha256" =~ ^[[:xdigit:]]{64}$ || "$native_filename" != environment.tar.gz ]] ||
    [[ "$(wc -l < "$tmpdir/native-package/SHA256SUMS")" -ne 1 ]]
  then
    fail 'The managed generation has an invalid archive checksum manifest'
    return 1
  fi
  if ! printf '%s  %s\n' "$native_sha256" "$native_archive" | sha256sum --check --status -
  then
    fail 'The managed generation archive checksum does not match'
    return 1
  fi
  success 'Both archives passed signature and integrity checks'

  if ! validate_archive_paths "$prefix_archive" prefix || ! validate_archive_paths "$native_archive" generation
  then
    fail 'Downloaded Termux archive contains an unsafe path'
    return 1
  fi

  if ! bash "$tmpdir/native-package/activate.sh" preflight "$native_archive" "$native_sha256"
  then
    fail 'The managed Termux generation failed its preflight check'
    return 1
  fi

  step 'Prepare the new environment'
  mkdir -p "$files_dir"
  mkdir -m 0700 "$stage_prefix"
  progress_bar 'Preparing Termux packages' tar -xzf "$prefix_archive" --strip-components=1 -C "$stage_prefix"
  rm -f -- "$tmpdir/netrc" "$tmpdir/nixpp" "$tmpdir/nixpp.sha256" "$tmpdir/$nixpp_channel_name"
  write_swap_helper "$tmpdir/swap-prefix.sh"
  trap - EXIT
  step 'Switch to the prepared Termux environment'
  info 'The old package tree stays available until startup and yadm setup succeed.'
  if [[ "$run_yadm" == 1 ]]
  then
    info 'After the switch, y.brkn.lol will clone your private yadm config and apply the Termux setup'
  fi
  success 'Ready to switch to the verified environment'
  exec /system/bin/sh "$tmpdir/swap-prefix.sh" "$stage_prefix" "$tmpdir" "$run_yadm" "$native_archive" "$native_sha256"
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]
then
  main "$@"
fi

# vim: set ft=sh et ts=2 sw=2 :
