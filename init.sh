#!/usr/bin/env bash

usage() {
  printf 'Usage: %s [--legacy | --nixpp] [--archive-only] [--yes] [--no-color] [--local DIR] [--host NAME] [BW_PASSWORD]\n' "$(basename "$0")"
  printf 'Termux uses the nixpp setup by default; pass --legacy for the original setup.\n'
  printf 'Optional environment variables: RBW_EMAIL, RBW_MASTER_PASSWORD, RBW_TOTP\n'
}

# Bash's own `read` builtin, not pinentry -- see unlock_rbw for why.
query_secret() {
  local prompt="$1"
  local secret

  if [[ -n "$ZSH_VERSION" ]]
  then
    read -rs "secret?${prompt}: " < /dev/tty
  else
    read -rs -p "${prompt}: " secret < /dev/tty
  fi
  # read -s swallows the Enter keypress's newline, so back-to-back prompts
  # would otherwise run together on the same line.
  echo >&2

  if [[ -z "$secret" ]]
  then
    return 1
  fi

  echo "$secret"
}

# Runs a command with its output hidden, so setup doesn't drown in raw
# apt/pkg noise -- but the output is still shown (and the log kept) if the
# command actually fails, so it stays debuggable.
run_quiet() {
  local desc="$1"
  local log
  shift

  log="$(mktemp)"
  echo "${desc}..." >&2

  if ! "$@" >"$log" 2>&1
  then
    echo "Failed: ${desc}" >&2
    cat "$log" >&2
    rm -f "$log"
    return 1
  fi

  rm -f "$log"
}

install_deps() {
  if command -v termux-info >/dev/null
  then
    if [[ "${YADM_TERMUX_ARCHIVE_READY:-}" == 1 ]]
    then
      local dependency
      for dependency in curl git ssh ssh-keygen
      do
        if ! command -v "$dependency" >/dev/null 2>&1
        then
          echo "Prepared Termux environment is missing required command: $dependency" >&2
          return 1
        fi
      done
      return 0
    fi

    run_quiet "Upgrading packages" bash -c 'yes | pkg upgrade -y'
    run_quiet "Installing dependencies" pkg install -y curl git openssh pinentry
  elif command -v apt >/dev/null
  then
    run_quiet "Updating package lists" sudo apt update
    run_quiet "Installing dependencies" sudo apt install -y curl git openssh-client pinentry
  elif command -v dnf >/dev/null
  then
    run_quiet "Installing dependencies" sudo dnf install -y curl git openssh-clients pinentry
  elif command -v pacman >/dev/null
  then
    run_quiet "Installing dependencies" sudo pacman -Sy --noconfirm curl git openssh x11-ssh-askpass pinentry
  elif command -v apk >/dev/null
  then
    run_quiet "Updating package lists" sudo apk update
    run_quiet "Installing dependencies" sudo apk add git curl openssh-client pinentry
  elif command -v nixos-help >/dev/null
  then
    echo "Pro user detected: nixos"
    return 0
  elif uname -s | grep -q CYGWIN_NT
  then
    cygwin_install_apt-cyg
    cygwin_install_pkg curl git openssh zsh
  else
    echo "Unknown OS or distribution" >&2
    return 3
  fi
}

__get_tmpdir() {
  echo "${TMPDIR:-/tmp}/yadm"
}

cygwin_get_installed_pkgs() {
  awk '{ print $1 }' /etc/setup/installed.db
  # Alternative (SLOW)
  # apt-cyg show | grep -v 'The following packages are installed:' | awk '{ print $1 }'
}

cygwin_install_apt-cyg() {
  if command -v apt-cyg >/dev/null
  then
    return
  fi
  curl -qs -L -o /usr/bin/apt-cyg \
    https://raw.githubusercontent.com/kou1okada/apt-cyg/master/apt-cyg
  chmod +x /usr/bin/apt-cyg
}

cygwin_install_pkg() {
  local packages=("$@")
  local pkg pkg_list to_install=()

  # Check if the packages are already installed
  # Background: The install takes ages..! Let's avoid waiting forever for
  # apt-cyg to re-install existing packages.
  pkg_list="$(cygwin_get_installed_pkgs)"
  for pkg in "${packages[@]}"
  do
    if ! grep -Eq "^$pkg\$" <<< "$pkg_list"
    then
      to_install+=("$pkg")
    fi
  done

  # Install packages if there is something to install
  if [[ "${#to_install[@]}" -gt 0 ]]
  then
    apt-cyg install "${to_install[@]}"
  fi
}

install_yadm() {
  local tmpdir
  tmpdir="$(__get_tmpdir)"
  mkdir -p "$tmpdir"
  curl -qsfLo "${tmpdir}/yadm" \
    https://github.com/TheLocehiliosan/yadm/raw/master/yadm
  chmod a+x "${tmpdir}/yadm"
  export PATH="${tmpdir}:${PATH}"
}

# Picks the prebuilt rbw release target for this platform, or nothing if
# there isn't one (caller decides whether that's fatal).
__rbw_release_target() {
  if command -v termux-info >/dev/null
  then
    echo "aarch64-linux-android"
    return 0
  fi

  case "$(uname -m)" in
    x86_64)
      echo "x86_64-unknown-linux-musl"
      ;;
  esac
}

# rbw is the secret store for everything this script needs (the yadm-init
# deploy key, this host's personal SSH key, and later the GPG import in the
# yadm bootstrap step). Skip the download if it's already on PATH -- e.g.
# NixOS hosts get it from home-manager instead.
install_rbw() {
  local tmpdir target tag version url

  # The Termux nixpp bootstrap starts an rbw agent before swapping the prefix.
  # Reuse it so the nested yadm initializer does not prompt for vault
  # credentials a second time. The swap helper keeps TMPDIR pointed at the
  # relocated old-prefix temp directory during yadm setup, preserving rbw's
  # Android agent socket path until the package-tree backup is removed.
  if [[ -n "${RBW_BIN:-}" && -x "$RBW_BIN" &&
    -n "${RBW_AGENT:-}" && -x "$RBW_AGENT" ]]
  then
    return 0
  fi

  # Termux Home Manager may expose a generated launcher even when rbw is not
  # installed in the package tree. Prefer the self-contained Android release
  # there so PATH cannot select a dangling launcher. On other hosts, only
  # reuse a system rbw if it exposes the fork-specific `termux` command.
  if ! command -v termux-info >/dev/null 2>&1 && command -v rbw >/dev/null 2>&1
  then
    if rbw termux --help >/dev/null 2>&1
    then
      RBW_BIN="$(command -v rbw)"
      return 0
    fi
  fi

  target="$(__rbw_release_target)"
  if [[ -z "$target" ]]
  then
    echo "No prebuilt rbw binary for $(uname -m), skipping rbw install" >&2
    return 1
  fi

  tmpdir="$(__get_tmpdir)"
  mkdir -p "$tmpdir"

  tag="$(curl -sI "https://github.com/pschmitt/rbw/releases/latest" |
    awk -F/ '/^[Ll]ocation:/ { print $NF }' | tr -d '\r')"
  if [[ -z "$tag" ]]
  then
    echo "Failed to resolve the latest rbw release" >&2
    return 1
  fi
  version="${tag#v}"
  url="https://github.com/pschmitt/rbw/releases/download/${tag}/rbw-${version}-${target}.tar.gz"

  curl -qsfL -o "${tmpdir}/rbw.tar.gz" "$url" || return 1
  tar -xzf "${tmpdir}/rbw.tar.gz" -C "$tmpdir"
  cp -f "${tmpdir}/rbw-${version}-${target}/rbw" "${tmpdir}/rbw"
  cp -f "${tmpdir}/rbw-${version}-${target}/rbw-agent" "${tmpdir}/rbw-agent"
  chmod a+x "${tmpdir}/rbw" "${tmpdir}/rbw-agent"
  RBW_BIN="${tmpdir}/rbw"
  export RBW_AGENT="${tmpdir}/rbw-agent"
  export PATH="${tmpdir}:${PATH}"
}

# Logs in and unlocks the primary rbw account non-interactively. Needed once
# per bootstrap run; the agent then stays unlocked for the rest of it
# (including the later GPG import in the yadm bootstrap step).
#
# Deliberately NOT relying on rbw's own pinentry prompt here: rbw-agent is a
# detached background daemon with no controlling terminal of its own
# (confirmed via `ps` -- TTY column is `?`), and on Termux specifically,
# pinentry fails to reopen the caller's /dev/pts/N by path ("pinentry error:
# No such device or address") -- a real-device-confirmed PTY/sandboxing
# quirk, not something fixable from this script. --stdin/--totp sidesteps
# pinentry entirely and is what's actually been verified to work here.
unlock_rbw() {
  local password="$1"
  local totp="$2"

  "$RBW_BIN" config set email "${RBW_EMAIL:-philipp@schmitt.co}"

  # Printed here (not just left to rbw's own output) so it's clear the TOTP
  # prompt is done and the script has moved on, rather than looking stuck.
  echo "Logging into Bitwarden..." >&2

  if ! echo "$password" | "$RBW_BIN" unlock --stdin --totp "$totp"
  then
    echo "Failed to unlock the Bitwarden vault" >&2
    return 1
  fi
}

# Prompts for the password/TOTP and unlocks rbw, retrying on a failed
# login (typo, stale/mistyped TOTP) instead of aborting the whole
# bootstrap over one bad keystroke.
login_rbw() {
  local attempt password totp

  # Lets a re-run (after an earlier step failed) skip straight past the
  # prompts instead of asking again for no reason.
  if "$RBW_BIN" unlocked 2>/dev/null
  then
    echo "Bitwarden is already unlocked" >&2
    return 0
  fi

  password="${RBW_MASTER_PASSWORD:-}"
  totp="${RBW_TOTP:-}"
  unset RBW_MASTER_PASSWORD RBW_TOTP

  for attempt in 1 2
  do
    if [[ -z "$password" ]]
    then
      password=$(query_secret "Bitwarden password")
    fi
    if ((attempt == 2))
    then
      echo "Bitwarden authentication failed; enter a fresh TOTP to retry once" >&2
      totp=$(query_secret "Bitwarden TOTP code (blank if none)") || true
    elif [[ -z "$totp" ]]
    then
      totp=$(query_secret "Bitwarden TOTP code (blank if none)") || true
    fi

    if unlock_rbw "$password" "$totp"
    then
      unset password totp
      return 0
    fi

    unset totp
  done

  unset password totp
  echo "Bitwarden login failed after one fresh-TOTP retry" >&2
  return 1
}

# Only ever needed transiently, to clone yadm-config below -- never meant to
# be a persistent file on disk. Registered as an EXIT trap so it's removed
# whether the script finishes normally or dies partway through.
cleanup_yadm_init_key() {
  rm -f "${HOME}/.ssh/id_yadm_init" "${HOME}/.ssh/id_yadm_init.pub"
}

# Fetches the yadm-init deploy key -- used only to clone the private
# yadm-config repo below -- directly from Bitwarden (item
# "yadm-init-deploy-key", stored unencrypted since rbw's own vault
# encryption is the protection here; no passphrase to manage).
get_ssh_key() {
  local item="${RBW_YADM_INIT_ITEM:-yadm-init-deploy-key}"

  mkdir -p "${HOME}/.ssh/agent"
  chmod 700 "${HOME}/.ssh" "${HOME}/.ssh/agent"
  "$RBW_BIN" get "$item" -f private_key > "${HOME}/.ssh/id_yadm_init"
  "$RBW_BIN" get "$item" -f public_key > "${HOME}/.ssh/id_yadm_init.pub"
  chmod 400 "${HOME}"/.ssh/id_yadm_init{,.pub}

  # Add key to agent to avoid being prompted multiple times
  if command -v ssh-add >/dev/null
  then
    if [[ -z "${SSH_AGENT_PID:-}" ]] || ! ssh-add -l >/dev/null 2>&1
    then
      unset SSH_AUTH_SOCK SSH_AGENT_PID
      eval "$(ssh-agent)"
    fi
    ssh-add "${HOME}/.ssh/id_yadm_init"
  fi
}

# Use the managed guest's yadm. Its normal clone checks out missing files and
# leaves existing files alone; the native bootstrap and alternatives are off.
clone_full_nix_dotfiles() {
  local host="$1" staging="$2"

  mkdir -m 700 "$staging/.ssh" || return 1
  HOME="$staging" add_trusted_key || return 1
  "$RBW_BIN" get "${RBW_YADM_INIT_ITEM:-yadm-init-deploy-key}" -f private_key \
    >"$staging/.ssh/deploy_key" || return 1

  # The quoted script runs with the guest environment.
  # shellcheck disable=SC2016
  tar -C "$staging/.ssh" -cf - deploy_key known_hosts |
    "$PREFIX/bin/nixpp" enter -- bash -c '
      set -euo pipefail
      umask 077
      if ! yadm rev-parse --verify HEAD >/dev/null 2>&1
      then
        staging=$(mktemp -d /tmp/yadm-init.XXXXXXXX)
        trap '"'"'rm -rf -- "$staging"'"'"' EXIT
        tar -xf - -C "$staging"
        export GIT_CONFIG_COUNT=2
        export GIT_CONFIG_KEY_0=yadm.auto-alt GIT_CONFIG_VALUE_0=false
        export GIT_CONFIG_KEY_1=yadm.auto-perms GIT_CONFIG_VALUE_1=false
        printf -v GIT_SSH_COMMAND "ssh -F /dev/null -oBatchMode=yes -oIdentitiesOnly=yes -oStrictHostKeyChecking=yes -oHostKeyAlias=ssh.github.com -oUserKnownHostsFile=%q -i %q" \
          "$staging/known_hosts" "$staging/deploy_key"
        export GIT_SSH_COMMAND
        yadm clone --no-bootstrap ssh://git@ssh.github.com:443/pschmitt/yadm-config.git
      fi
      yadm config yadm.auto-alt false
      yadm config local.hostname "$1"
      completion="$HOME/.config/zsh/completions/_yadm"
      managed="$HOME/.nix-profile/share/zsh/site-functions/_yadm"
      legacy="$HOME/.local/share/yadm.git/completion/zsh/_yadm"
      if [[ -L "$completion" && ! -e "$completion" && -r "$managed" &&
        "$(readlink "$completion")" == ../../../.local/share/yadm.git/completion/zsh/_yadm &&
        ! -e "$legacy" && ! -L "$legacy" ]]
      then
        mkdir -p "${legacy%/*}"
        ln -s "$managed" "$legacy"
      fi
    ' yadm-init "$host"
}

# Full-Nix TermuxPP has its own installer. Use rbw only for enrollment
# inputs, then leave remote builds and configuration activation to nixpp.
enroll_full_nix() (
  umask 077
  local host="$1"
  local staging ssh_item enrollment_item field

  install_rbw || return 1
  login_rbw || return 1

  staging=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/nixpp-enrollment.XXXXXXXX") || return 1
  trap 'rm -rf -- "$staging"' EXIT
  ssh_item="pschmitt@${host}"
  enrollment_item="${YADM_NIXPP_ITEM:-nixpp-enrollment-${host}}"
  "$RBW_BIN" get "$ssh_item" -f private_key >"$staging/id_ed25519" || return 1
  "$RBW_BIN" get "$ssh_item" -f public_key >"$staging/id_ed25519.pub" || return 1

  for field in ssh_config known_hosts build_host
  do
    "$RBW_BIN" get "$enrollment_item" -f "$field" >"$staging/$field" || return 1
  done
  if "$RBW_BIN" get "$enrollment_item" -f age_key >"$staging/age_key" 2>/dev/null &&
    [[ -s "$staging/age_key" ]]
  then
    chmod 600 "$staging/age_key" || return 1
  else
    rm -f "$staging/age_key" || return 1
  fi

  "$PREFIX/bin/nixpp" bootstrap \
    --host "$host" --user "${YADM_NIXPP_USER:-pschmitt}" \
    --flake "${YADM_NIXPP_FLAKE:-github:pschmitt/nixos-config?ref=agent/full-nix-hosts}" \
    --credentials "$staging" || return 1
  clone_full_nix_dotfiles "$host" "$staging"
)

# Maps a Termux device's Android codename (getprop ro.product.device) to the
# short hostname its Bitwarden items are named after (pschmitt@<host>).
# `hostname`/$HOSTNAME on Android returns nothing usable (see --host's help),
# so this is the only real signal available at bootstrap time. Mirrors
# ~/.config/zsh/custom/os/termux/zboot.zsh's table -- keep them in sync.
__detect_termux_host() {
  if ! command -v getprop >/dev/null
  then
    return
  fi

  case "$(getprop ro.product.device)" in
    clover) echo "mp4" ;;
    redfin) echo "px5" ;;
    lynx) echo "p7a" ;;
    grizzly) echo "p11" ;;
    ASUS_AI2302) echo "zf10" ;;
  esac
}

# Fetches this host's own personal SSH key from Bitwarden (item
# "pschmitt@<host>"), if one exists. A host that's never been enrolled
# before won't have one yet -- the Termux setup or Ansible bootstrap
# generates a fresh key after the dotfiles are cloned.
get_host_ssh_key() {
  local host="$1"
  local name

  if [[ -z "$host" ]]
  then
    echo "No --host given (and none auto-detected)," \
      "skipping personal SSH key fetch from Bitwarden" >&2
    return 0
  fi

  if [[ -f "${HOME}/.ssh/id_ed25519" ]]
  then
    echo "${HOME}/.ssh/id_ed25519 already present, skipping Bitwarden fetch"
    return 0
  fi

  name="pschmitt@${host}"
  if ! "$RBW_BIN" get "$name" >/dev/null 2>&1
  then
    echo "No '${name}' SSH key in Bitwarden -- a new one will be generated" >&2
    return 0
  fi

  # shellcheck disable=SC2174
  mkdir -m 700 -p "${HOME}/.ssh"
  "$RBW_BIN" get "$name" -f private_key > "${HOME}/.ssh/id_ed25519"
  "$RBW_BIN" get "$name" -f public_key > "${HOME}/.ssh/id_ed25519.pub"
  chmod 600 "${HOME}/.ssh/id_ed25519"
  chmod 644 "${HOME}/.ssh/id_ed25519.pub"
  echo "Fetched SSH key '${name}' from Bitwarden"
}

add_trusted_key() {
  # ssh-keyscan -H git.brkn.lol >> ~/.ssh/known_hosts
  # ssh-keyscan -H github.com -p 22 >> ~/.ssh/known_hosts
  # ssh-keyscan -H ssh.github.com -p 443 >> ~/.ssh/known_hosts
  cat > ~/.ssh/known_hosts <<- "EOF"
git.brkn.lol ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDO/XpQS7Mf9YVAExYflgiFizndTGa8KcCEGvcUp9Luov2wYzqYaeLDGk+MWY4UKryiGoKkNt4OY1lTddH2LxpWv9mRo7i+AOS4Qw20/ERXZ5jMrkvOeWfKhBuQuFnATXJyYHzqQhT2r5Ban8wpxyqMJnOZUx4Er/SK+2eYm9Q/rgOshruuJlC6u1zLJqGlsqEX8oOBCKhqQcz5/riP8CF0Bf8pLJnG5TaqAFi77sYG5YbK61zkx9VX45eXgeiBnAgB66RNUlMPvYqca4K9CHcQeG9h075XuouCbi3vZqFmaA81lYH5lQZWK5tcz3lAIfE+ZweJ4lv6dHAKCv3Yk/sIecrhy38HDxb5df5n1ERISKHs7dRkjXIHBY9kKJsiU/sCuHcMamO6bD33ZbrsrUcX8rZ8Uhs8ARuZRIUFgJrnm5l/GpiG/W6K31WmXDc0hpgQ7geA7fSPimvLT6NqaSqLmLGO6vyiqknL3aJT5Jj3KyefqT78AMZPgpBjkYCyTUE=
git.brkn.lol ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOSMurkElc1C0mgQM97reY6D8bIg6cDX3TRx6mjd5Cru
ssh.github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
ssh.github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
ssh.github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
EOF
  chmod 600 ~/.ssh/known_hosts
}

yadm_deinit() {
  if ! command -v yadm >/dev/null
  then
    return
  fi

  # Delete tracked files
  local branch
  local file
  branch=$(yadm branch --show-current 2>/dev/null || true)

  if [[ -n "$branch" ]]
  then
    for file in $(yadm ls-tree -r "$branch" --full-tree | awk '{ print $NF }')
    do
      rm -rf "$file"
    done

    # Delete submodules
    # Disable check since we want to expand $(pwd) at "runtime"
    # shellcheck disable=2016
    # FIXME Why is the below command leaving us with broken submodules that
    # cannot be cloned over?
    # yadm submodule foreach 'rm -rf $(pwd)' || true
    if [[ -f "${HOME}/.gitmodules" ]]
    then
      awk "/^\s*path\s*=/ { print \"${HOME}/\" \$3 }" \
        "${HOME}/.gitmodules" | xargs rm -rfv
    fi
  fi

  rm -rf "${HOME}/.local/share/yadm" "${HOME}/.gitmodules"
}

yadm_set_local_classes() {
  local yadm_bin="$1"
  local class classes
  local classes_to_add=()

  if ! command -v termux-info >/dev/null 2>&1
  then
    return 0
  fi

  if [[ "${TERMUX_APP__DATA_DIR:-}" == /data/data/dev.pschmitt.termux || "${PREFIX:-}" == /data/data/dev.pschmitt.termux/files/usr ]]
  then
    classes="$(bash "$yadm_bin" config --get-all local.class 2>/dev/null || true)"
    if grep -Exq -- 'termux(pp)?' <<< "$classes"
    then
      bash "$yadm_bin" config --unset-all local.class '^termux(pp)?$'
    fi
  else
    classes_to_add+=(termux)
  fi
  if ((NIXPP_MODE))
  then
    classes_to_add+=(nixpp)
  else
    classes_to_add+=(zinit)
  fi

  for class in "${classes_to_add[@]}"
  do
    classes="$(bash "$yadm_bin" config --get-all local.class 2>/dev/null || true)"
    if ! grep -Fqx -- "$class" <<< "$classes"
    then
      bash "$yadm_bin" config --add local.class "$class"
    fi
  done
}

yadm_init() {
  local url log yadm_bin
  local urls=(
    "git@github.com:pschmitt/yadm-config.git"
    "ssh://git@ssh.github.com:443/pschmitt/yadm-config.git"
    "ssh://git@git.brkn.lol/pschmitt/yadm-config.git"
    "https://github.com/pschmitt/yadm-config.git"
  )
  yadm_bin="$(__get_tmpdir)/yadm"

  if [[ -n "$LOCAL_REPO" ]]
  then
    run_quiet "Cloning dotfiles" bash "$yadm_bin" clone -f --no-bootstrap "$LOCAL_REPO"
    yadm_set_local_classes "$yadm_bin"
    "${HOME}/.config/yadm/bootstrap"
  else
    # Trying each remote in turn is expected to fail a few times before
    # one works (e.g. no outbound SSH on this network) -- that's not a
    # real error, so keep each attempt quiet and only dump the combined
    # log if every remote fails.
    echo "Cloning dotfiles..." >&2
    log="$(mktemp)"

    for url in "${urls[@]}"
    do
      if GIT_SSH_COMMAND="ssh -i ~/.ssh/id_yadm_init -F /dev/null" \
        bash "$yadm_bin" clone -f --no-bootstrap "$url" >>"$log" 2>&1
      then
        rm -f "$log"
        yadm_set_local_classes "$yadm_bin"
        "${HOME}/.config/yadm/bootstrap"
        return 0
      fi
    done

    echo "Failed to clone dotfiles from any remote" >&2
    cat "$log" >&2
    rm -f "$log"
    return 1
  fi
}

yadm_cleanup() {
  rm -rf "$(__get_tmpdir)"
}

# https://stackoverflow.com/a/28776166/1872036
if ! (return 2>/dev/null)
then
  set -e

  cd "$HOME" || return 9

  NIXPP_MODE=0
  if [[ "${YADM_INIT_NIXPP:-0}" == 1 ]]
  then
    NIXPP_MODE=1
  fi
  if command -v termux-info >/dev/null 2>&1
  then
    NIXPP_MODE=1
  fi
  nixpp_requested=0
  legacy_requested=0
  nixpp_args=()
  nixpp_incompatible_args=0

  while [[ -n "$*" ]]
  do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --nixpp)
        nixpp_requested=1
        shift
        ;;
      --legacy)
        legacy_requested=1
        shift
        ;;
      --archive-only | --yes | --no-color)
        nixpp_args+=("$1")
        shift
        ;;
      local|--local|-l|l|-L)
        if [[ -z "$2" ]]
        then
          usage
          exit 2
        fi
        LOCAL_REPO="$2"
        nixpp_incompatible_args=1
        shift 2
        ;;
      host|--host|-H)
        if [[ -z "$2" ]]
        then
          usage
          exit 2
        fi
        YADM_HOST="$2"
        nixpp_incompatible_args=1
        shift 2
        ;;
      *)
        RBW_MASTER_PASSWORD="$1"
        nixpp_incompatible_args=1
        shift
        break
        ;;
    esac
  done

  if ((nixpp_requested && legacy_requested))
  then
    printf '%s\n' '--nixpp and --legacy cannot be used together' >&2
    usage >&2
    exit 2
  fi
  if ((legacy_requested))
  then
    NIXPP_MODE=0
  elif ((nixpp_requested))
  then
    NIXPP_MODE=1
  fi

  # This script is normally run as `curl ... | bash -s -- ...`, which leaves
  # stdin attached to curl's pipe. Reattach to a tty only after parsing so
  # help and argument errors work in non-interactive contexts too. rbw's
  # pinentry needs a real tty on stdin to know where to prompt.
  if ! [[ -t 0 ]] && [[ -r /dev/tty ]]
  then
    exec < /dev/tty
  fi

  if ((NIXPP_MODE)) && [[ "${YADM_TERMUX_ARCHIVE_READY:-}" != 1 ]]
  then
    if ((nixpp_incompatible_args))
    then
      printf '%s\n' '--local, --host, and a positional Bitwarden password require --legacy' >&2
      usage >&2
      exit 2
    fi
    if ! command -v termux-info >/dev/null 2>&1
    then
      echo '--nixpp is only supported inside the official Termux app' >&2
      exit 1
    fi

    if [[ -z "${YADM_HOST:-}" ]]
    then
      YADM_HOST=$(__detect_termux_host)
    fi
    if [[ "$YADM_HOST" != mp4 && "$YADM_HOST" != zf10 && "$YADM_HOST" != p11 ]]
    then
      echo "--nixpp does not have a host profile for this Termux device: ${YADM_HOST:-unknown}" >&2
      exit 1
    fi
    export YADM_HOST

    if [[ -n "${PREFIX:-}" && -x "$PREFIX/bin/nixpp" ]] &&
          "$PREFIX/bin/nixpp" bootstrap --help >/dev/null 2>&1
    then
      if [[ "$YADM_HOST" != zf10 && "$YADM_HOST" != p11 ]]
      then
        printf 'No full-Nix guest configuration for %s\n' "$YADM_HOST" >&2
        exit 2
      fi
      for option in "${nixpp_args[@]}"
      do
        if [[ "$option" == --archive-only ]]
        then
          printf '%s\n' '--archive-only applies only to the legacy native bundle' >&2
          exit 2
        fi
      done
      export RBW_PROFILE=yadm-init
      enroll_full_nix "$YADM_HOST"
      exit $?
    fi

    set -o pipefail
    curl -fsSL https://raw.githubusercontent.com/pschmitt/yadm-init/main/bootstrap-termux-environment.sh |
      bash -s -- "${nixpp_args[@]}"
    exit $?
  fi

  if ((${#nixpp_args[@]} > 0))
  then
    printf '%s\n' 'Use --archive-only, --yes, and --no-color with the nixpp setup, not --legacy' >&2
    usage >&2
    exit 2
  fi

  if [[ -z "$YADM_HOST" ]]
  then
    YADM_HOST="$(__detect_termux_host)"
  fi

  if command -v termux-info >/dev/null 2>&1
  then
    export RBW_PROFILE='yadm-init'
  fi

  install_deps
  install_yadm

  if [[ -z "$LOCAL_REPO" ]]
  then
    install_rbw

    # rbw is now the secret store for the yadm-init deploy key, this
    # host's personal SSH key, and (later, in the yadm bootstrap step)
    # the GPG key -- one unlock covers all of it.
    login_rbw
    trap cleanup_yadm_init_key EXIT
    get_ssh_key
    get_host_ssh_key "$YADM_HOST"
  fi

  add_trusted_key
  yadm_deinit
  yadm_init
  yadm_cleanup
  # This script may run from a curl pipe. It reattaches stdin to the terminal
  # for Bitwarden prompts, so restore EOF before Bash reads past the script.
  exec </dev/null
fi

# vim: set et ts=2 sw=2 :
