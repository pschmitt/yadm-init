#!/usr/bin/env bash

set -Eeuo pipefail

readonly stock_prefix='/data/data/com.termux/files/usr'
readonly fork_prefix='/data/data/dev.pschmitt.termux/files/usr'
export PREFIX="${PREFIX:-$stock_prefix}"
export RBW_PROFILE='yadm-init'
readonly nixpp_s3_base_url='https://s3.openstack.de-west-01.wiit-cloud.io/nix-cache-brkn-lol/termux-bootstrap'
readonly nixpp_s3_credentials_item='nixpp Niks3 cache'
readonly nixpp_binary_name='nixpp-aarch64-latest'
readonly nixpp_channel_prefix_stock='termux-nix-cache-aarch64'
readonly nixpp_channel_prefix_fork='termuxpp-nix-cache-aarch64'
nixpp_channel_prefix=''
nixpp_channel_name=''
# stock: official Termux app (replaces the package tree).
# fork: TermuxPP, dev.pschmitt.termux (keeps its package tree).
termux_flavor=''
fork_backup_dir=''
readonly nixpp_s3_substituter='s3://nix-cache-brkn-lol?endpoint=s3.openstack.de-west-01.wiit-cloud.io&region=default&scheme=https&profile=niks3&priority=30'
readonly nixpp_s3_public_key_rofl10='rofl-10:vYRBSypcO/0NnPsDxgSELIcJotU/LmZ1f6vZUKUmty0='
readonly nixpp_s3_public_key_rofl13='rofl-13:ESRCqy2jcftg690k98KSNqF6LgOqz1X7ZnXXE//WWD0='
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
  printf 'Download and verify the prepared AArch64 environment, then start setup.\n' >&2
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

fetch_cache_output() {
  local description="$1"
  local store_path="$2"
  local destination="$3"

  info "Downloading $description; transfer progress appears when available"
  if ! NIXPP_CONFIG="$tmpdir/nixpp-bootstrap.toml" "$tmpdir/nixpp" fetch \
    --store-path "$store_path" \
    --destination "$destination"
  then
    fail "Could not download or verify $description."
    info 'Check the network, Bitwarden access, and Niks3 cache credentials; the current package tree is still active.'
    return 1
  fi
  success "$description downloaded and verified from the Niks3 S3 cache"
}

download_s3_object() {
  local description="$1"
  local destination="$2"
  local object_name="$3"
  local access_key secret_key

  if ! access_key=$("$RBW_BIN" get --exact "$nixpp_s3_credentials_item" -f username) ||
    ! secret_key=$("$RBW_BIN" get --exact "$nixpp_s3_credentials_item" -f password)
  then
    unset access_key secret_key
    fail "Could not read Niks3 credentials from Bitwarden to download $description."
    info "Check the Bitwarden item named '$nixpp_s3_credentials_item'."
    return 1
  fi

  if ! {
    printf 'aws-sigv4 = "aws:amz:default:s3"\n'
    printf 'user = "%s:%s"\n' "$access_key" "$secret_key"
  } | curl -qfsSL --config - -o "$destination" \
    "${nixpp_s3_base_url}/${object_name}"
  then
    unset access_key secret_key
    fail "Could not download $description from the Niks3 S3 cache."
    return 1
  fi
  unset access_key secret_key
}

write_nixpp_bootstrap_config() {
  local config="$tmpdir/nixpp-bootstrap.toml"

  cat > "$config" <<EOF
[defaults]
substituter = "$nixpp_s3_substituter"
public_keys = ["$nixpp_s3_public_key_rofl10", "$nixpp_s3_public_key_rofl13"]
aws_credentials_command = ["rbw", "get", "--raw", "--exact", "nixpp Niks3 cache"]
EOF
  chmod 0600 "$config"
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
In the official Termux app this replaces the package tree under \$PREFIX; files
in \$HOME are kept. In TermuxPP (dev.pschmitt.termux) the existing package tree
is kept: only the managed shell generation and its missing APT packages are
installed, and held packages stay held.

Options:
  --archive-only  Install the archives and open a fresh shell without yadm setup.
  --yes           Skip the confirmation prompt.
  --no-color      Disable colored output (also honors NO_COLOR).
  -h, --help      Show this help.

  curl -fsSL https://raw.githubusercontent.com/pschmitt/yadm-init/main/bootstrap-termux-environment.sh | bash
EOF
  cat <<'EOF'

Optional Bitwarden environment variables for unattended setup:
  RBW_EMAIL, RBW_MASTER_PASSWORD, and RBW_TOTP

The environment values are consumed for the first login attempt, then unset.
If unlock fails, the script keeps the password in memory and prompts once for
a fresh TOTP before retrying.
EOF
}

confirm_prefix_replacement() {
  local answer

  if [[ "$termux_flavor" == fork ]]
  then
    warn "This keeps the TermuxPP package tree at $PREFIX and installs the managed shell generation."
    info 'Missing APT packages are installed with apt; held packages are kept as they are.'
    info 'A backup of the package state is retained; your home directory is kept.'
  else
    warn "This replaces the Termux package tree at $PREFIX."
    info 'Your home directory is kept; the yadm initializer may update its own files afterward.'
  fi
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
    info 'Cancelled. No changes were made.'
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
  local -a required=(curl tar sha256sum xz)

  if [[ "$termux_flavor" == fork ]]
  then
    # The fork keeps its own package tree, so APT and dpkg must already work.
    required+=(pkg apt-mark dpkg-query)
  fi
  for command in "${required[@]}"
  do
    if ! command -v "$command" >/dev/null 2>&1
    then
      fail "The initial Termux installation is missing '$command'."
      info 'Open Termux and install its standard bootstrap packages, then retry.'
      return 1
    fi
  done
  if ! curl --help all | grep -q -- '--aws-sigv4'
  then
    fail 'The installed Termux curl does not support AWS SigV4 requests.'
    return 1
  fi
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
  export RBW_BIN
  export RBW_AGENT="$rbw_tmpdir/rbw-agent"
  export PATH="$rbw_tmpdir:$PATH"
}

login_rbw() {
  local attempt email password totp

  if "$RBW_BIN" unlocked >/dev/null 2>&1
  then
    unset RBW_EMAIL RBW_MASTER_PASSWORD RBW_TOTP
    printf 'Bitwarden is already unlocked\n' >&2
    return 0
  fi

  email="${RBW_EMAIL:-$("$RBW_BIN" config get email 2>/dev/null || true)}"
  password="${RBW_MASTER_PASSWORD:-}"
  totp="${RBW_TOTP:-}"
  unset RBW_EMAIL RBW_MASTER_PASSWORD RBW_TOTP
  if [[ -z "$email" ]]
  then
    read -r -p 'Bitwarden email: ' email < /dev/tty
  fi
  "$RBW_BIN" config set email "$email"
  unset email
  for attempt in 1 2
  do
    if [[ -z "$password" ]]
    then
      password=$(query_secret 'Bitwarden password')
    fi
    if ((attempt == 2)) || [[ -z "$totp" ]]
    then
      totp=$(query_secret 'Bitwarden TOTP code (blank if none)') || true
    fi

    if printf '%s\n' "$password" | "$RBW_BIN" unlock --stdin --totp "$totp"
    then
      unset password totp
      return 0
    fi

    unset totp
    if ((attempt == 1))
    then
      printf 'Bitwarden authentication failed; enter a fresh TOTP to retry once\n' >&2
    fi
  done

  unset password totp
  printf 'Bitwarden login failed after one fresh-TOTP retry\n' >&2
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

  # The fork keeps its own package tree, so its channel needs no prefix output.
  # One that carries it is tolerated, validated, and never downloaded.
  if [[ "$format" != 1 || "$architecture" != aarch64 ]] ||
    ! valid_store_path "$nixpp_store_path" ||
    ! valid_store_path "$native_store_path" ||
    {
      [[ "$termux_flavor" != fork || -n "$prefix_store_path" ]] &&
        ! valid_store_path "$prefix_store_path"
    }
  then
    printf 'Cache channel is incomplete or targets an unsupported environment\n' >&2
    return 1
  fi
}

detect_termux_flavor() {
  case "$PREFIX" in
    "$stock_prefix")
      termux_flavor=stock
      nixpp_channel_prefix=$nixpp_channel_prefix_stock
      ;;
    "$fork_prefix")
      termux_flavor=fork
      nixpp_channel_prefix=$nixpp_channel_prefix_fork
      ;;
    *)
      return 1
      ;;
  esac
}

# Save everything needed to recover the retained fork prefix before apt runs:
# the dpkg database, APT holds and configuration, SSH host keys, and the login
# shell. The directory is never deleted by this script.
snapshot_fork_state() {
  local prefix=$1 backup_root=$2
  local stamp dir host_key
  local -a host_keys=()

  stamp=$(date -u +%Y%m%dT%H%M%SZ) || return
  dir="$backup_root/$stamp"
  mkdir -p "$backup_root" || return
  chmod 0700 "$backup_root" || return
  if ! mkdir -m 0700 "$dir"
  then
    printf 'Could not create the recovery backup directory: %s\n' "$dir" >&2
    return 1
  fi

  if ! cp -p "${DPKG_ADMINDIR:-$prefix/var/lib/dpkg}/status" "$dir/dpkg-status" ||
    ! apt-mark showhold | LC_ALL=C sort > "$dir/holds.txt" ||
    ! dpkg-query -W -f='${Package}\t${Version}\n' | LC_ALL=C sort > "$dir/packages.tsv" ||
    [[ ! -s "$dir/packages.tsv" ]]
  then
    rm -rf -- "$dir"
    printf 'Could not record the current package state.\n' >&2
    return 1
  fi
  if [[ -d "$prefix/etc/apt" ]] &&
    ! tar -C "$prefix" -cf "$dir/etc-apt.tar" etc/apt
  then
    rm -rf -- "$dir"
    return 1
  fi
  for host_key in "$prefix"/etc/ssh/ssh_host_*
  do
    [[ -e "$host_key" ]] && host_keys+=("etc/ssh/${host_key##*/}")
  done
  if ((${#host_keys[@]})) &&
    ! tar -C "$prefix" -cf "$dir/ssh-host-keys.tar" "${host_keys[@]}"
  then
    rm -rf -- "$dir"
    return 1
  fi
  if [[ -e "$prefix/etc/zshenv" ]]
  then
    cp -p "$prefix/etc/zshenv" "$dir/zshenv" || {
      rm -rf -- "$dir"
      return 1
    }
  fi
  if [[ -L "$HOME/.termux/shell" ]]
  then
    readlink "$HOME/.termux/shell" > "$dir/termux-shell-target" || {
      rm -rf -- "$dir"
      return 1
    }
  fi
  chmod -R go-rwx "$dir"
  fork_backup_dir=$dir
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

write_helper_stock_preamble() {
  cat <<'EOF'
#!/system/bin/sh

set -eu

unset LD_PRELOAD

stage_prefix="$1"
tmpdir="$2"
run_yadm="$3"
native_archive="$4"
native_sha256="$5"
files_dir="${7:?missing Termux files directory}"
prefix="$files_dir/usr"
backup="$files_dir/usr.bootstrap-backup"
rbw_runtime_tmpdir="${6:-$prefix/tmp}"
toybox='/system/bin/toybox'

case "$rbw_runtime_tmpdir" in
  "$prefix"/*)
    rbw_runtime_tmpdir="$backup/${rbw_runtime_tmpdir#"$prefix"/}"
    ;;
esac

remove_tree() {
  "$toybox" rm -rf "$@"
}

restore_previous() {
  "$toybox" rm -rf "$prefix"
  "$toybox" mv "$backup" "$prefix"
  remove_tree "$tmpdir"
  echo "$1; restored the previous package tree" >&2
}

report_previous_tree() {
  echo "Your previous package tree is preserved at: $backup" >&2
}

print_restore_hint() {
  echo 'To restore it from Termux, run:' >&2
  echo "  /system/bin/toybox rm -rf '$prefix'" >&2
  echo "  /system/bin/toybox mv '$backup' '$prefix'" >&2
}

verify_package_state() {
  return 0
}

discard_previous() {
  remove_tree "$backup"
}

if [ -e "$backup" ]; then
  echo "A previous prefix backup exists at $backup; refusing to replace it" >&2
  exit 1
fi

if ! "$toybox" mv "$prefix" "$backup"; then
  echo 'Could not move the current Termux prefix aside' >&2
  exit 1
fi

case "${RBW_BIN:-}" in
  "$prefix"/*)
    RBW_BIN="$backup/${RBW_BIN#"$prefix"/}"
    export RBW_BIN
    ;;
esac
case "${RBW_AGENT:-}" in
  "$prefix"/*)
    RBW_AGENT="$backup/${RBW_AGENT#"$prefix"/}"
    export RBW_AGENT
    ;;
esac

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

export PREFIX="$files_dir/usr"
export HOME="$files_dir/home"
export TMPDIR="$PREFIX/tmp"
export PATH="$PREFIX/bin:/system/bin"
export LD_PRELOAD="$PREFIX/lib/libtermux-exec.so"
cd "$HOME"

second_stage_fallback="$PREFIX/etc/profile.d/01-termux-bootstrap-second-stage-fallback.sh"
if [ -f "$second_stage_fallback" ]; then
  echo 'Completing Termux first-run package setup.' >&2
  if ! "$PREFIX/bin/bash" -c '. "$PREFIX/etc/profile.d/01-termux-bootstrap-second-stage-fallback.sh"'; then
    restore_previous 'Termux first-run setup failed'
    exit 1
  fi
fi

EOF
}

# TermuxPP keeps its own package tree, LD_PRELOAD (the fork's path redirect),
# and PATH. Nothing is moved, replaced, or unset here.
write_helper_fork_preamble() {
  cat <<'EOF'
#!/system/bin/sh

set -eu

tmpdir="$2"
run_yadm="$3"
native_archive="$4"
native_sha256="$5"
files_dir="${7:?missing Termux files directory}"
fork_backup="${8:?missing recovery backup directory}"
prefix="$files_dir/usr"
rbw_runtime_tmpdir="${6:-$prefix/tmp}"

remove_tree() {
  rm -rf "$@"
}

restore_previous() {
  remove_tree "$tmpdir"
  echo "$1; the package tree was kept in place" >&2
  report_previous_tree
}

report_previous_tree() {
  echo "Package state backup (dpkg database, APT holds and configuration, SSH host keys): $fork_backup" >&2
}

print_restore_hint() {
  echo 'The package tree was not replaced; nothing needs to be moved back.' >&2
}

# apt must not have touched held packages, whatever it installed alongside.
verify_package_state() {
  holds_before="$fork_backup/holds.txt"
  packages_before="$fork_backup/packages.tsv"
  if [ ! -r "$holds_before" ] || [ ! -r "$packages_before" ]; then
    echo "The package state backup is incomplete: $fork_backup" >&2
    return 1
  fi
  holds_after=$("$PREFIX/bin/apt-mark" showhold) || return 1
  state_ok=0
  while IFS= read -r held; do
    [ -n "$held" ] || continue
    if ! printf '%s\n' "$holds_after" | grep -Fxq -- "$held"; then
      echo "The APT hold on $held was lost; restoring it" >&2
      "$PREFIX/bin/apt-mark" hold "$held" >/dev/null || true
      state_ok=1
    fi
    version_before=$(awk -F '\t' -v name="$held" '$1 == name { print $2 }' "$packages_before")
    version_after=$("$PREFIX/bin/dpkg-query" -W -f='${Version}' "$held" 2>/dev/null || true)
    if [ "$version_before" != "$version_after" ]; then
      echo "Held package $held changed from '$version_before' to '$version_after'" >&2
      state_ok=1
    fi
  done < "$holds_before"
  return "$state_ok"
}

discard_previous() {
  echo "Package state backup retained at: $fork_backup" >&2
  echo 'Remove it yourself once you no longer need it.' >&2
}

if [ "${PREFIX:-}" != "$prefix" ]; then
  echo "Refusing to run: PREFIX is not $prefix" >&2
  exit 1
fi
HOME="${HOME:-$files_dir/home}"
TMPDIR="${TMPDIR:-$prefix/tmp}"
export HOME TMPDIR
cd "$HOME"

if ! "$prefix/bin/bash" -c 'command -v dpkg-query >/dev/null && command -v apt-mark >/dev/null && command -v curl >/dev/null'; then
  remove_tree "$tmpdir"
  echo 'The TermuxPP package tree failed its startup check; nothing was changed' >&2
  exit 1
fi

EOF
}

write_helper_tail() {
  cat <<'EOF'
if ! "$PREFIX/bin/ssh-keygen" -A; then
  restore_previous 'Could not generate device-specific SSH host keys'
  exit 1
fi

native_status=0
TERMUX_NATIVE_SKIP_SOPS_SETUP=1 \
  "$PREFIX/bin/bash" "$tmpdir/native-package/bootstrap.sh" \
  install "$native_archive" "$native_sha256" || native_status=$?
if ! verify_package_state; then
  remove_tree "$tmpdir"
  echo 'APT changed held packages while installing the managed generation.' >&2
  report_previous_tree
  exit 1
fi
if [ "$native_status" -ne 0 ]; then
  remove_tree "$tmpdir"
  echo 'The package tree is active, but the managed Termux generation could not be installed.' >&2
  report_previous_tree
  exit 1
fi

if [ "$run_yadm" = 1 ]; then
  export YADM_TERMUX_ARCHIVE_READY=1
  export YADM_INIT_NIXPP=1
  # rbw derives its agent socket from TMPDIR on Android. Keep the old prefix's
  # relocated temp directory while yadm-init talks to the already-unlocked
  # agent; the new prefix has a different socket path.
  if ! RBW_BIN="${RBW_BIN:-}" RBW_AGENT="${RBW_AGENT:-}" \
    RBW_PROFILE="${RBW_PROFILE:-yadm-init}" TMPDIR="$rbw_runtime_tmpdir" \
    "$PREFIX/bin/bash" -lc 'set -euo pipefail; curl -fsSL y.brkn.lol -L | bash'; then
    unset YADM_TERMUX_ARCHIVE_READY
    unset YADM_INIT_NIXPP
    remove_tree "$tmpdir"
    echo 'The Termux environment is installed, but yadm setup did not finish.' >&2
    report_previous_tree
    print_restore_hint
    exit 1
  fi
  unset YADM_TERMUX_ARCHIVE_READY
  unset YADM_INIT_NIXPP

  if ! "$PREFIX/bin/bash" -s <<'INSTALL_TERMUX_HOST_KEYS'
#!/usr/bin/env bash

set -euo pipefail

case "${YADM_HOST:-}" in
  mp4 | zf10 | p11)
    ;;
  *)
    printf 'Cannot restore SSH host keys for unsupported Termux host: %s\n' "${YADM_HOST:-unknown}" >&2
    exit 1
    ;;
esac

generation=$(readlink -f "$HOME/.local/share/termux-native/current")
ciphertext="$generation/home/.local/share/termux-native/ssh-host-keys.sops.yaml"
sops="$generation/bin/sops"
ssh_to_age="$generation/bin/ssh-to-age"
if [[ ! -s "$ciphertext" || ! -x "$sops" || ! -x "$ssh_to_age" ]]; then
  printf 'The managed generation is missing the encrypted SSH host keys or SOPS tools.\n' >&2
  exit 1
fi
if [[ ! -s "$HOME/.ssh/id_ed25519" ]]; then
  printf "The per-host SSH identity is missing; cannot decrypt this host's keys.\n" >&2
  exit 1
fi

age_key=$("$ssh_to_age" --private-key -i "$HOME/.ssh/id_ed25519")
if [[ -z "$age_key" ]]; then
  printf 'Could not derive the SOPS identity from the per-host SSH key.\n' >&2
  exit 1
fi
umask 077
key_stage=$(mktemp -d "$PREFIX/tmp/termux-host-keys.XXXXXXXX")
cleanup_host_keys() {
  rm -rf -- "$key_stage"
}
trap cleanup_host_keys EXIT

for type in ed25519 rsa; do
  private_key_path='["ssh"]["host_keys"]["'"$type"'"]["privkey"]'
  public_key_path='["ssh"]["host_keys"]["'"$type"'"]["pubkey"]'
  SOPS_AGE_KEY="$age_key" "$sops" decrypt \
    --extract "$private_key_path" \
    "$ciphertext" > "$key_stage/ssh_host_${type}_key"
  SOPS_AGE_KEY="$age_key" "$sops" decrypt \
    --extract "$public_key_path" \
    "$ciphertext" > "$key_stage/ssh_host_${type}_key.pub"
  chmod 0600 "$key_stage/ssh_host_${type}_key"
  chmod 0644 "$key_stage/ssh_host_${type}_key.pub"
  "$PREFIX/bin/ssh-keygen" -y -f "$key_stage/ssh_host_${type}_key" > "$key_stage/derived_${type}.pub"
  awk '{ print $1, $2 }' "$key_stage/ssh_host_${type}_key.pub" > "$key_stage/expected_${type}.pub"
  awk '{ print $1, $2 }' "$key_stage/derived_${type}.pub" > "$key_stage/actual_${type}.pub"
  if ! cmp -s "$key_stage/expected_${type}.pub" "$key_stage/actual_${type}.pub"; then
    printf 'The encrypted %s SSH host key pair does not match.\n' "$type" >&2
    exit 1
  fi
done

for type in ed25519 rsa; do
  mv -f "$key_stage/ssh_host_${type}_key" "$PREFIX/etc/ssh/ssh_host_${type}_key"
  mv -f "$key_stage/ssh_host_${type}_key.pub" "$PREFIX/etc/ssh/ssh_host_${type}_key.pub"
done
printf 'Restored the existing SSH host keys from the encrypted host configuration.\n' >&2
generation=$(readlink -f "$HOME/.local/share/termux-native/current")
TERMUX_GENERATION="$generation" \
  PATH="$generation/bin:$PATH" \
  "$PREFIX/bin/bash" "$generation/setup-known-hosts.sh" "$generation"
TERMUX_GENERATION="$generation" \
  PATH="$generation/bin:$PATH" \
  "$PREFIX/bin/bash" "$generation/setup-gpg-keys.sh" "$generation"
INSTALL_TERMUX_HOST_KEYS
  then
    unset YADM_TERMUX_ARCHIVE_READY
    unset YADM_INIT_NIXPP
    remove_tree "$tmpdir"
    echo 'The Termux environment is installed, but SSH host keys could not be restored.' >&2
    report_previous_tree
    print_restore_hint
    exit 1
  fi

  generation=$(readlink -f "$HOME/.local/share/termux-native/current")
  if [[ -f "$generation/setup-nixpp-cache.sh" ]] &&
    ! TERMUX_GENERATION="$generation" \
      PATH="$generation/bin:$PATH" \
      "$PREFIX/bin/bash" "$generation/setup-nixpp-cache.sh" "$generation"
  then
    unset YADM_TERMUX_ARCHIVE_READY
    unset YADM_INIT_NIXPP
    remove_tree "$tmpdir"
    echo 'The Termux environment is installed, but Niks3 credentials could not be configured.' >&2
    report_previous_tree
    exit 1
  fi

  echo 'Termux and yadm setup are complete.' >&2
else
  echo 'The Termux archives are installed. Yadm setup was skipped.' >&2
fi

unset RBW_BIN RBW_AGENT RBW_PROFILE
discard_previous
remove_tree "$tmpdir"
echo 'Opening your Zsh session. Type exit to return to Termux.' >&2
exec "$PREFIX/bin/zsh" -li
EOF
}

write_swap_helper() {
  local helper="$1"

  {
    write_helper_stock_preamble
    write_helper_tail
  } > "$helper"
  chmod 0700 "$helper"
}

write_inplace_helper() {
  local helper="$1"

  {
    write_helper_fork_preamble
    write_helper_tail
  } > "$helper"
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
  if ! detect_termux_flavor
  then
    fail "Unexpected Termux prefix: $PREFIX"
    info "This release supports the official Termux app ($stock_prefix) and TermuxPP ($fork_prefix)."
    return 1
  fi
  if [[ "$termux_flavor" == fork ]]
  then
    info 'Detected TermuxPP; its package tree is kept and only the managed generation is installed.'
  fi

  if [[ "$termux_flavor" == stock && -e "$files_dir/usr.bootstrap-backup" ]]
  then
    fail 'A previous setup left the original package tree backed up.'
    info "Backup: $files_dir/usr.bootstrap-backup"
    info 'Restore it in Termux with:'
    printf '  /system/bin/toybox rm -rf %q && /system/bin/toybox mv %q %q\n' \
      "$PREFIX" "$files_dir/usr.bootstrap-backup" "$PREFIX" >&2
    return 1
  fi
  if [[ "$termux_flavor" == stock && -e "$files_dir/usr.bootstrap-new" ]]
  then
    fail 'An interrupted setup left a staged package tree.'
    info 'The staged tree is inactive. Remove it in Termux, then retry:'
    printf '  /system/bin/toybox rm -rf %q\n' "$files_dir/usr.bootstrap-new" >&2
    return 1
  fi
  if [[ "$termux_flavor" == fork && "${HOME:-}" != "$files_dir/home" ]]
  then
    fail "Unexpected home directory for TermuxPP: ${HOME:-unset}"
    return 1
  fi

  architecture=$(dpkg --print-architecture)
  if [[ "$architecture" != aarch64 ]]
  then
    fail "The published environment requires Termux aarch64; found $architecture"
    return 1
  fi

  case "${YADM_HOST:-}" in
    mp4 | zf10 | p11)
      nixpp_channel_name="${nixpp_channel_prefix}-${YADM_HOST}-latest.manifest"
      ;;
    *)
      fail "No published Termux host profile for ${YADM_HOST:-unknown}"
      return 1
      ;;
  esac

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

  step 'Connect to the Niks3 S3 cache'
  mkdir -p "$HOME/.cache"
  chmod 0700 "$HOME/.cache"
  tmpdir=$(mktemp -d "${HOME}/.cache/yadm-init-environment.XXXXXXXX")
  chmod 0700 "$tmpdir"
  write_nixpp_bootstrap_config
  if [[ "$termux_flavor" == stock ]]
  then
    stage_prefix="${files_dir}/usr.bootstrap-new"
    if [[ -e "$stage_prefix" ]]
    then
      printf 'Refusing to overwrite an existing staged prefix: %s\n' "$stage_prefix" >&2
      return 1
    fi
  fi

  info 'Reading the Termux channel manifest from Niks3'
  if ! download_s3_object 'the Termux channel manifest' \
    "$tmpdir/$nixpp_channel_name" "$nixpp_channel_name"
  then
    return 1
  fi
  if ! read_cache_channel "$tmpdir/$nixpp_channel_name"
  then
    fail 'The private Nix cache channel manifest is invalid'
    return 1
  fi

  info 'Downloading the small cache verifier'
  if ! download_s3_object 'the cache verifier' "$tmpdir/nixpp" "$nixpp_binary_name" ||
    ! download_s3_object 'the cache verifier checksum' "$tmpdir/nixpp.sha256" \
      "${nixpp_binary_name}.sha256"
  then
    return 1
  fi
  nixpp_sha256=$(awk 'NR == 1 { print $1 }' "$tmpdir/nixpp.sha256")
  if [[ ! "$nixpp_sha256" =~ ^[[:xdigit:]]{64}$ ]] ||
    ! printf '%s  %s\n' "$nixpp_sha256" "$tmpdir/nixpp" | sha256sum --check --status -
  then
    fail 'The first-stage nixpp checksum is invalid'
    return 1
  fi
  chmod 0700 "$tmpdir/nixpp"
  "$tmpdir/nixpp" --help >/dev/null

  if [[ "$termux_flavor" == stock ]]
  then
    fetch_cache_output 'the Termux package archive' \
      "$prefix_store_path" "$tmpdir/prefix-package"
  fi
  fetch_cache_output 'the managed Termux shell generation' \
    "$native_store_path" "$tmpdir/native-package"

  prefix_archive="$tmpdir/prefix-package/share/termux/termux-prefix.tar.gz"
  native_archive="$tmpdir/native-package/environment.tar.gz"
  if [[ ! -s "$native_archive" || ! -s "$tmpdir/native-package/SHA256SUMS" ]] ||
    [[ "$termux_flavor" == stock && ! -s "$prefix_archive" ]]
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
  if [[ "$termux_flavor" == stock ]]
  then
    success 'Both archives passed signature and integrity checks'
  else
    success 'The managed generation passed signature and integrity checks'
  fi

  if [[ "$termux_flavor" == stock ]] && ! validate_archive_paths "$prefix_archive" prefix ||
    ! validate_archive_paths "$native_archive" generation
  then
    fail 'Downloaded Termux archive contains an unsafe path'
    return 1
  fi

  if ! bash "$tmpdir/native-package/activate.sh" preflight "$native_archive" "$native_sha256"
  then
    fail 'The managed Termux generation failed its preflight check'
    return 1
  fi

  if [[ "$run_yadm" == 1 ]]
  then
    if ! tar -xOf "$native_archive" ./home/.local/share/termux-native/ssh-host-keys.sops.yaml \
      > "$tmpdir/ssh-host-keys.sops.yaml" ||
      ! grep -Eq 'privkey:[[:space:]]*ENC\[AES256_GCM' "$tmpdir/ssh-host-keys.sops.yaml" ||
      ! grep -Eq 'pubkey:[[:space:]]*ENC\[AES256_GCM' "$tmpdir/ssh-host-keys.sops.yaml"
    then
      fail 'The managed generation does not contain encrypted SSH host keys for this device.'
      info 'No Termux package changes have been made. Add the preserved host keys to SOPS, rebuild the archive, and retry.'
      return 1
    fi
    success 'Encrypted SSH host keys are present in the generation'
  fi

  if [[ "$termux_flavor" == fork ]]
  then
    step 'Back up the TermuxPP package state'
    if ! snapshot_fork_state "$PREFIX" "$files_dir/termuxpp-bootstrap-backup"
    then
      fail 'Could not back up the TermuxPP package state; nothing was changed.'
      return 1
    fi
    success "Package state saved to $fork_backup_dir"
    rm -f -- "$tmpdir/nixpp" "$tmpdir/nixpp.sha256" "$tmpdir/$nixpp_channel_name"
    write_inplace_helper "$tmpdir/install-generation.sh"
    trap - EXIT
    step 'Install the managed generation'
    info 'The TermuxPP package tree stays in place; missing APT packages are installed and holds are verified.'
    if [[ "$run_yadm" == 1 ]]
    then
      info 'Afterward, y.brkn.lol will clone your private yadm config and apply the Termux setup'
    fi
    success 'Ready to install the verified generation'
    # The helper inherits PATH and LD_PRELOAD: the fork's path redirect stays on.
    exec "$PREFIX/bin/sh" "$tmpdir/install-generation.sh" '' "$tmpdir" "$run_yadm" \
      "$native_archive" "$native_sha256" "${TMPDIR:-$PREFIX/tmp}" "$files_dir" "$fork_backup_dir"
  fi

  step 'Prepare the new environment'
  mkdir -p "$files_dir"
  mkdir -m 0700 "$stage_prefix"
  progress_bar 'Preparing Termux packages' tar -xzf "$prefix_archive" --strip-components=1 -C "$stage_prefix"
  rm -f -- "$tmpdir/nixpp" "$tmpdir/nixpp.sha256" "$tmpdir/$nixpp_channel_name"
  write_swap_helper "$tmpdir/swap-prefix.sh"
  trap - EXIT
  step 'Switch to the prepared Termux environment'
  info 'The old package tree stays available until startup and yadm setup succeed.'
  if [[ "$run_yadm" == 1 ]]
  then
    info 'After the switch, y.brkn.lol will clone your private yadm config and apply the Termux setup'
  fi
  success 'Ready to switch to the verified environment'
  exec /system/bin/sh "$tmpdir/swap-prefix.sh" "$stage_prefix" "$tmpdir" "$run_yadm" "$native_archive" "$native_sha256" "${TMPDIR:-$PREFIX/tmp}" "$files_dir"
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]
then
  main "$@"
fi

# vim: set ft=sh et ts=2 sw=2 :
