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
    if [[ "${2:-}" == --add ]]
    then
      printf '%s\n' "$4" >> "$YADM_TEST_CLASSES"
    fi
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
  unset LOCAL_REPO YADM_HOST YADM_INIT_NIXPP YADM_TERMUX_ARCHIVE_READY
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

new_case conflicting_modes
if bash "$script_dir/init.sh" --legacy --nixpp >"$CASE_DIR/output" 2>&1
then
  printf 'Conflicting mode flags unexpectedly succeeded\n' >&2
  exit 1
fi
assert_file_contains "$CASE_DIR/output" '--nixpp and --legacy cannot be used together'
printf '%s\n' 'PASS conflicting mode flags fail clearly'

# vim: set ft=sh et ts=2 sw=2 :
