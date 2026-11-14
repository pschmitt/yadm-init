#!/usr/bin/env bash
# Targeted tests for bootstrap-termux-environment.sh: stock Termux and the
# TermuxPP fork (dev.pschmitt.termux). Needs no device and no network.

# shellcheck disable=SC2016  # single quotes keep literal shell text on purpose
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
bootstrap="$script_dir/bootstrap-termux-environment.sh"
tmp_root=$(mktemp -d)
trap 'rm -rf -- "$tmp_root"' EXIT

readonly stock_prefix=/data/data/com.termux/files/usr
readonly fork_prefix=/data/data/dev.pschmitt.termux/files/usr
store_path_nixpp=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixpp
store_path_prefix=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-prefix
store_path_native=/nix/store/cccccccccccccccccccccccccccccccc-native

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS %s\n' "$1"
}

# Run a snippet with the bootstrap sourced under the given PREFIX. The script
# marks files_dir readonly, so every case gets its own bash process.
with_bootstrap() {
  local prefix=$1 snippet=$2
  PREFIX=$prefix bash -c 'set -Eeuo pipefail; source "$1"; shift; eval "$1"' _ "$bootstrap" "$snippet"
}

write_manifest() {
  local path=$1
  shift
  : > "$path"
  while (($# > 0))
  do
    printf '%s\n' "$1" >> "$path"
    shift
  done
}

# --- flavor detection --------------------------------------------------------

[[ $(with_bootstrap "$stock_prefix" 'detect_termux_flavor; echo "$termux_flavor $nixpp_channel_prefix"') == \
  'stock termux-nix-cache-aarch64' ]] || fail 'stock prefix is detected as stock'
[[ $(with_bootstrap "$fork_prefix" 'detect_termux_flavor; echo "$termux_flavor $nixpp_channel_prefix"') == \
  'fork termuxpp-nix-cache-aarch64' ]] || fail 'fork prefix is detected as fork'
if with_bootstrap /data/data/org.example.termux/files/usr 'detect_termux_flavor' 2>/dev/null
then
  fail 'unknown prefixes are rejected'
fi
if with_bootstrap "$fork_prefix/" 'detect_termux_flavor' 2>/dev/null
then
  fail 'lookalike prefixes are rejected'
fi
pass 'prefix flavor detection'

# --- channel manifests -------------------------------------------------------

stock_manifest="$tmp_root/stock.manifest"
fork_manifest="$tmp_root/fork.manifest"
write_manifest "$stock_manifest" format=1 arch=aarch64 \
  "nixpp=$store_path_nixpp" "prefix=$store_path_prefix" "native=$store_path_native"
write_manifest "$fork_manifest" format=1 arch=aarch64 \
  "nixpp=$store_path_nixpp" "native=$store_path_native"

with_bootstrap "$stock_prefix" "detect_termux_flavor; read_cache_channel '$stock_manifest'" ||
  fail 'stock manifest with prefix is accepted'
if with_bootstrap "$stock_prefix" "detect_termux_flavor; read_cache_channel '$fork_manifest'" 2>/dev/null
then
  fail 'stock manifest without prefix is rejected'
fi
[[ $(with_bootstrap "$fork_prefix" \
  "detect_termux_flavor; read_cache_channel '$fork_manifest'; echo \"\$native_store_path\"") == "$store_path_native" ]] ||
  fail 'fork manifest without prefix is accepted'
with_bootstrap "$fork_prefix" "detect_termux_flavor; read_cache_channel '$stock_manifest'" ||
  fail 'fork manifest may carry a valid, ignored prefix'
bad_manifest="$tmp_root/bad.manifest"
write_manifest "$bad_manifest" format=1 arch=aarch64 \
  "nixpp=$store_path_nixpp" 'prefix=/tmp/not-a-store-path' "native=$store_path_native"
if with_bootstrap "$fork_prefix" "detect_termux_flavor; read_cache_channel '$bad_manifest'" 2>/dev/null
then
  fail 'fork manifest with an invalid prefix is rejected'
fi
write_manifest "$bad_manifest" format=1 arch=aarch64 "nixpp=$store_path_nixpp"
if with_bootstrap "$fork_prefix" "detect_termux_flavor; read_cache_channel '$bad_manifest'" 2>/dev/null
then
  fail 'fork manifest without a native output is rejected'
fi
pass 'channel manifests per flavor'

# --- generated helpers -------------------------------------------------------

stock_helper="$tmp_root/swap-prefix.sh"
fork_helper="$tmp_root/install-generation.sh"
with_bootstrap "$stock_prefix" "write_swap_helper '$stock_helper'"
with_bootstrap "$fork_prefix" "write_inplace_helper '$fork_helper'"
sh -n "$stock_helper" || fail 'stock helper parses'
sh -n "$fork_helper" || fail 'fork helper parses'

if grep -q 'com\.termux\|dev\.pschmitt\.termux' "$stock_helper" "$fork_helper"
then
  fail 'helpers do not hardcode an app package name'
fi
grep -Fq 'files_dir="${7:?' "$stock_helper" || fail 'stock helper takes files_dir as an argument'
grep -Fq 'unset LD_PRELOAD' "$stock_helper" || fail 'stock helper still drops LD_PRELOAD'
grep -Fq 'toybox" mv "$prefix" "$backup"' "$stock_helper" || fail 'stock helper still swaps the prefix'
if grep -Fq 'LD_PRELOAD' "$fork_helper" && grep -Fq 'unset LD_PRELOAD' "$fork_helper"
then
  fail 'fork helper keeps the fork LD_PRELOAD redirect'
fi
if grep -Fq 'export PATH=' "$fork_helper" || grep -Fq 'mv "$prefix"' "$fork_helper"
then
  fail 'fork helper does not reset PATH or move the prefix'
fi
if grep -Fq 'rm -rf "$backup"' "$fork_helper"
then
  fail 'fork helper never deletes its recovery backup'
fi
pass 'stock and fork helpers'

# --- fork snapshot and helper run against a fake prefix ----------------------

fake_prefix() {
  local root=$1
  mkdir -p "$root/files/usr/bin" "$root/files/usr/etc/apt" "$root/files/usr/etc/ssh" \
    "$root/files/usr/var/lib/dpkg" "$root/files/usr/tmp" "$root/files/home/.termux"
  printf 'Package: apt\n' > "$root/files/usr/var/lib/dpkg/status"
  printf 'sources\n' > "$root/files/usr/etc/apt/sources.list"
  printf 'secret-key\n' > "$root/files/usr/etc/ssh/ssh_host_ed25519_key"
  printf 'zshenv\n' > "$root/files/usr/etc/zshenv"
  ln -s /bin/zsh "$root/files/home/.termux/shell"
  printf 'apt\t2.7\nlibfoo\t1.0\nnano\t7.2\n' > "$root/pkg-versions.tsv"
  printf 'libfoo\n' > "$root/holds.current"

  ln -s "$(command -v bash)" "$root/files/usr/bin/bash"
  cat > "$root/files/usr/bin/apt-mark" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  showhold) cat "$FAKE_ROOT/holds.current" ;;
  hold) printf '%s\n' "$2" >> "$FAKE_ROOT/hold-calls" ;;
esac
EOF
  cat > "$root/files/usr/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *'${Package}'* ]]
then
  cat "$FAKE_ROOT/pkg-versions.tsv"
else
  awk -F '\t' -v name="${!#}" '$1 == name { printf "%s", $2 }' "$FAKE_ROOT/pkg-versions.tsv"
fi
EOF
  cat > "$root/files/usr/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$root/files/usr/bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$root/files/usr/bin/zsh" <<'EOF'
#!/usr/bin/env bash
printf 'zsh started LD_PRELOAD=%s\n' "${LD_PRELOAD:-}" > "$FAKE_ROOT/zsh-ran"
EOF
  chmod 0755 "$root/files/usr/bin/"{apt-mark,dpkg-query,curl,ssh-keygen,zsh}
}

make_native_stub() {
  local dir=$1
  mkdir -p "$dir/native-package"
  cat > "$dir/native-package/bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_ROOT/native-args"
printf '%s\n' "${TERMUX_NATIVE_SKIP_SOPS_SETUP:-}" > "$FAKE_ROOT/native-skip-sops"
if [[ "${FAKE_DROP_HOLD:-0}" == 1 ]]
then
  : > "$FAKE_ROOT/holds.current"
fi
if [[ "${FAKE_BUMP_HELD:-0}" == 1 ]]
then
  sed -i 's/^libfoo\t1.0$/libfoo\t2.0/' "$FAKE_ROOT/pkg-versions.tsv"
fi
exit "${FAKE_NATIVE_STATUS:-0}"
EOF
}

run_fork_case() {
  local name=$1
  shift
  CASE_ROOT="$tmp_root/$name"
  fake_prefix "$CASE_ROOT"
  mkdir -p "$CASE_ROOT/work"
  make_native_stub "$CASE_ROOT/work"
  CASE_STATUS=0
  (
    export FAKE_ROOT="$CASE_ROOT"
    export PATH="$CASE_ROOT/files/usr/bin:$PATH"
    export PREFIX="$CASE_ROOT/files/usr"
    export HOME="$CASE_ROOT/files/home"
    export TMPDIR="$CASE_ROOT/files/usr/tmp"
    export LD_PRELOAD=fork-redirect.so
    export "${@?}"
    PREFIX="$CASE_ROOT/files/usr" bash -c '
      set -Eeuo pipefail
      source "$1"
      snapshot_fork_state "$PREFIX" "$2"
      write_inplace_helper "$3"
      printf "%s\n" "$fork_backup_dir" > "$4"
    ' _ "$bootstrap" "$CASE_ROOT/files/backup" "$CASE_ROOT/work/helper.sh" "$CASE_ROOT/backup-dir"
    backup=$(<"$CASE_ROOT/backup-dir")
    sh "$CASE_ROOT/work/helper.sh" '' "$CASE_ROOT/work" 0 archive.tar.gz "$(printf 'a%.0s' {1..64})" \
      "$TMPDIR" "$CASE_ROOT/files" "$backup"
  ) > "$CASE_ROOT/out" 2>&1 || CASE_STATUS=$?
}

run_fork_case ok FAKE_X=1
((CASE_STATUS == 0)) || { cat "$CASE_ROOT/out" >&2; fail 'fork helper succeeds on a healthy prefix'; }
backup=$(<"$CASE_ROOT/backup-dir")
[[ "$backup" == "$CASE_ROOT/files/backup/"* ]] || fail 'snapshot goes under the retained backup root'
for file in dpkg-status holds.txt packages.tsv etc-apt.tar ssh-host-keys.tar zshenv termux-shell-target
do
  [[ -s "$backup/$file" ]] || fail "snapshot contains $file"
done
[[ $(<"$backup/holds.txt") == libfoo ]] || fail 'snapshot records APT holds'
[[ $(stat -c %a "$backup") == 700 ]] || fail 'snapshot directory is private'
[[ $(<"$CASE_ROOT/native-skip-sops") == 1 ]] || fail 'native install skips SOPS setup'
grep -Fq 'install archive.tar.gz' "$CASE_ROOT/native-args" || fail 'native bootstrap gets archive and checksum'
grep -Fq 'LD_PRELOAD=fork-redirect.so' "$CASE_ROOT/zsh-ran" || fail 'fork LD_PRELOAD survives the helper'
[[ -d "$backup" ]] || fail 'recovery backup survives success'
[[ -e "$CASE_ROOT/files/usr/bin/bash" ]] || fail 'prefix is kept in place'
[[ ! -e "$CASE_ROOT/work" ]] || fail 'helper cleans its temporary directory'
pass 'fork helper installs in place and keeps the backup'

run_fork_case dropped_hold FAKE_DROP_HOLD=1
((CASE_STATUS != 0)) || fail 'a lost APT hold fails the install'
grep -Fq 'libfoo' "$CASE_ROOT/hold-calls" || fail 'a lost APT hold is re-applied'
[[ ! -e "$CASE_ROOT/zsh-ran" ]] || fail 'no shell is started after a hold failure'
[[ -d "$(<"$CASE_ROOT/backup-dir")" ]] || fail 'backup survives a hold failure'
pass 'fork helper protects APT holds'

run_fork_case bumped_hold FAKE_BUMP_HELD=1
((CASE_STATUS != 0)) || fail 'a changed held package version fails the install'
grep -Fq 'Held package libfoo changed' "$CASE_ROOT/out" || fail 'the held version change is reported'
pass 'fork helper detects held version changes'

run_fork_case native_failure FAKE_NATIVE_STATUS=7
((CASE_STATUS != 0)) || fail 'native bootstrap failure fails the helper'
grep -Fq 'could not be installed' "$CASE_ROOT/out" || fail 'native failure is reported'
grep -Fq 'Package state backup' "$CASE_ROOT/out" || fail 'native failure points to the backup'
[[ -d "$(<"$CASE_ROOT/backup-dir")" ]] || fail 'backup survives a native failure'
pass 'fork helper keeps the backup when the generation fails'

printf '%s\n' 'All Termux bootstrap tests passed.'
