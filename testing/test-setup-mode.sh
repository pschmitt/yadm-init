#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_root=$(mktemp -d)
trap 'rm -rf -- "$tmp_root"' EXIT

fake_bin="$tmp_root/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/termux-info" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$fake_bin/getprop" <<'EOF'
#!/usr/bin/env bash
printf 'ASUS_AI2302\n'
EOF

cat > "$fake_bin/pkg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

output=''
url="${!#}"
while (($# > 0))
do
  case "$1" in
    -qsfLo)
      output="$2"
      shift 2
      ;;
    -o)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

case "$url" in
  */bootstrap-termux-environment.sh)
    cat <<'BOOTSTRAP'
printf 'nixpp\n' > "$YADM_TEST_MODE"
printf '%s\n' "$@" > "$YADM_TEST_ARGS"
BOOTSTRAP
    ;;
  */yadm)
    cat > "$output" <<'YADM'
#!/usr/bin/env bash

set -euo pipefail

case "$1" in
  clone)
    mkdir -p "$HOME/.config/yadm"
    cat > "$HOME/.config/yadm/bootstrap" <<'BOOTSTRAP'
#!/usr/bin/env bash
printf 'bootstrapped\n' > "$YADM_TEST_BOOTSTRAP"
BOOTSTRAP
    chmod 700 "$HOME/.config/yadm/bootstrap"
    ;;
  config)
    case "${2:-}" in
      --add)
        printf '%s\n' "$4" >> "$YADM_TEST_CLASSES"
        ;;
      --get-all)
        [[ -f "$YADM_TEST_CLASSES" ]] && cat "$YADM_TEST_CLASSES"
        ;;
      --unset-all)
        grep -Fvx -- termux "$YADM_TEST_CLASSES" > "$YADM_TEST_CLASSES.tmp" || true
        mv "$YADM_TEST_CLASSES.tmp" "$YADM_TEST_CLASSES"
        ;;
    esac
    ;;
  branch)
    ;;
esac
YADM
    chmod 700 "$output"
    ;;
  *)
    printf 'Unexpected curl URL in setup-mode test\n' >&2
    exit 1
    ;;
esac
EOF

chmod 700 "$fake_bin"/*

new_case() {
  local name="$1"
  CASE_DIR="$tmp_root/$name"
  mkdir -p "$CASE_DIR/home/.ssh" "$CASE_DIR/tmp"
  export HOME="$CASE_DIR/home"
  export TMPDIR="$CASE_DIR/tmp"
  export YADM_TEST_MODE="$CASE_DIR/mode"
  export YADM_TEST_ARGS="$CASE_DIR/args"
  export YADM_TEST_BOOTSTRAP="$CASE_DIR/bootstrap"
  export YADM_TEST_CLASSES="$CASE_DIR/classes"
  export PATH="$fake_bin:$PATH"
  unset LOCAL_REPO YADM_HOST YADM_INIT_NIXPP YADM_TERMUX_ARCHIVE_READY TERMUX_APP__DATA_DIR PREFIX
}

assert_file_contains() {
  local path="$1"
  local expected="$2"

  if ! grep -Fqx -- "$expected" "$path"
  then
    printf 'Expected %s to contain %s\n' "$path" "$expected" >&2
    exit 1
  fi
}

new_case default
bash "$script_dir/init.sh"
assert_file_contains "$YADM_TEST_MODE" nixpp
printf '%s\n' 'PASS Termux defaults to nixpp'

new_case explicit_nixpp
bash "$script_dir/init.sh" --nixpp --archive-only --yes --no-color
assert_file_contains "$YADM_TEST_MODE" nixpp
assert_file_contains "$YADM_TEST_ARGS" --archive-only
assert_file_contains "$YADM_TEST_ARGS" --yes
assert_file_contains "$YADM_TEST_ARGS" --no-color
printf '%s\n' 'PASS --nixpp forwards nixpp options'

new_case full_nix
export PREFIX="$CASE_DIR/prefix"
mkdir -p "$PREFIX/bin"
cat > "$PREFIX/bin/nixpp" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ ${2:-} == --help ]]
then
  exit 0
fi
printf '%s\n' "$@" > "$YADM_TEST_ARGS"
staging="${!#}"
for name in id_ed25519 id_ed25519.pub ssh_config known_hosts build_host
do
  test -s "$staging/$name"
  test "$(stat -c %a "$staging/$name")" = 600
done
printf '%s\n' "$staging" > "$YADM_TEST_MODE"
EOF
cat > "$CASE_DIR/rbw" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  unlocked) exit 0 ;;
  get)
    [[ ${!#} != rbw_config ]] || exit 1
    printf '%s\n' fixture
    ;;
  *) exit 1 ;;
esac
EOF
chmod 700 "$PREFIX/bin/nixpp" "$CASE_DIR/rbw"
RBW_BIN="$CASE_DIR/rbw" RBW_AGENT="$CASE_DIR/rbw" bash "$script_dir/init.sh"
assert_file_contains "$YADM_TEST_ARGS" bootstrap
assert_file_contains "$YADM_TEST_ARGS" zf10
assert_file_contains "$YADM_TEST_ARGS" pschmitt
test ! -e "$(cat "$YADM_TEST_MODE")"
printf '%s\n' 'PASS full-Nix TermuxPP hands credentials to nixpp and cleans up'

new_case legacy
mkdir -p "$CASE_DIR/local-repo"
bash "$script_dir/init.sh" --legacy --local "$CASE_DIR/local-repo"
assert_file_contains "$YADM_TEST_BOOTSTRAP" bootstrapped
assert_file_contains "$YADM_TEST_CLASSES" termux
assert_file_contains "$YADM_TEST_CLASSES" zinit
if [[ -e "$YADM_TEST_MODE" ]]
then
  printf 'The --legacy option unexpectedly selected nixpp\n' >&2
  exit 1
fi
printf '%s\n' 'PASS --legacy retains the original yadm path'

new_case termuxpp_class
mkdir -p "$CASE_DIR/local-repo"
printf '%s\n' termux custom > "$YADM_TEST_CLASSES"
export TERMUX_APP__DATA_DIR=/data/data/dev.pschmitt.termux
bash "$script_dir/init.sh" --legacy --local "$CASE_DIR/local-repo"
assert_file_contains "$YADM_TEST_CLASSES" termuxpp
assert_file_contains "$YADM_TEST_CLASSES" custom
if grep -Fqx -- termux "$YADM_TEST_CLASSES"
then
  printf 'The old Termux class was not removed\n' >&2
  exit 1
fi
printf '%s\n' 'PASS TermuxPP migrates the old class without removing others'

new_case conflicting_modes
if bash "$script_dir/init.sh" --legacy --nixpp >"$CASE_DIR/output" 2>&1
then
  printf 'Conflicting mode flags unexpectedly succeeded\n' >&2
  exit 1
fi
assert_file_contains "$CASE_DIR/output" '--nixpp and --legacy cannot be used together'
printf '%s\n' 'PASS conflicting mode flags fail clearly'

# vim: set ft=sh et ts=2 sw=2 :
