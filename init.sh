#!/usr/bin/env bash

usage() {
  echo "Usage: $(basename "$0") [--local DIR] [--host NAME] [BW_PASSWORD]"
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

  if command -v rbw >/dev/null
  then
    return 0
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

  rbw config set email "${RBW_EMAIL:-philipp@schmitt.co}"

  # Printed here (not just left to rbw's own output) so it's clear the TOTP
  # prompt is done and the script has moved on, rather than looking stuck.
  echo "Logging into Bitwarden..." >&2

  if ! echo "$password" | rbw unlock --stdin --totp "$totp"
  then
    echo "Failed to unlock the Bitwarden vault" >&2
    return 1
  fi
}

# Prompts for the password/TOTP and unlocks rbw, retrying on a failed
# login (typo, stale/mistyped TOTP) instead of aborting the whole
# bootstrap over one bad keystroke.
login_rbw() {
  local attempt

  for attempt in 1 2 3
  do
    if [[ -z "$RBW_MASTER_PASSWORD" ]]
    then
      RBW_MASTER_PASSWORD=$(query_secret "Bitwarden password")
    fi
    if [[ -z "$RBW_TOTP" ]]
    then
      RBW_TOTP=$(query_secret "Bitwarden TOTP code (blank if none)") || true
    fi

    if unlock_rbw "$RBW_MASTER_PASSWORD" "$RBW_TOTP"
    then
      return 0
    fi

    # Both get cleared so a bad value is never silently reused - the next
    # loop iteration always re-prompts for both.
    RBW_MASTER_PASSWORD=""
    RBW_TOTP=""
    echo "Login attempt ${attempt}/3 failed, let's try again" >&2
  done

  echo "Too many failed Bitwarden login attempts, giving up" >&2
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

  # shellcheck disable=SC2174
  mkdir -m 700 -p "${HOME}/.ssh"
  rbw get "$item" -f private_key > "${HOME}/.ssh/id_yadm_init"
  rbw get "$item" -f public_key > "${HOME}/.ssh/id_yadm_init.pub"
  chmod 400 "${HOME}"/.ssh/id_yadm_init{,.pub}

  # Add key to agent to avoid being prompted multiple times
  if command -v ssh-add >/dev/null
  then
    if [[ -z "$SSH_AGENT_PID" ]]
    then
      eval "$(ssh-agent)"
    fi
    ssh-add "${HOME}/.ssh/id_yadm_init"
  fi
}

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
    ASUS_AI2302) echo "zf10" ;;
  esac
}

# Fetches this host's own personal SSH key from Bitwarden (item
# "pschmitt@<host>"), if one exists. A host that's never been enrolled
# before won't have one yet -- that's fine, the ansible ssh.yml role
# generates a fresh key in that case, same as before this existed.
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
  if ! rbw get "$name" >/dev/null 2>&1
  then
    echo "No '${name}' SSH key in Bitwarden -- a new one will be generated" >&2
    return 0
  fi

  # shellcheck disable=SC2174
  mkdir -m 700 -p "${HOME}/.ssh"
  rbw get "$name" -f private_key > "${HOME}/.ssh/id_ed25519"
  rbw get "$name" -f public_key > "${HOME}/.ssh/id_ed25519.pub"
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
  branch=$(yadm branch --show-current || true)

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
    awk "/^\s*path\s*=/ { print \"${HOME}/\" \$3 }" \
      "${HOME}/.gitmodules" | xargs rm -rfv
  fi

  rm -rf "${HOME}/.local/share/yadm" "${HOME}/.gitmodules"
}

yadm_init() {
  local url
  local urls=(
    "git@github.com:pschmitt/yadm-config.git"
    "ssh://git@ssh.github.com:443/pschmitt/yadm-config.git"
    "ssh://git@git.brkn.lol/pschmitt/yadm-config.git"
    "https://github.com/pschmitt/yadm-config.git"
  )

  if [[ -n "$LOCAL_REPO" ]]
  then
    bash "$(__get_tmpdir)/yadm" clone -f --bootstrap "$LOCAL_REPO"
  else
    for url in "${urls[@]}"
    do
      if GIT_SSH_COMMAND="ssh -i ~/.ssh/id_yadm_init -F /dev/null" \
        bash "$(__get_tmpdir)/yadm" clone -f --no-bootstrap "$url"
      then
        "${HOME}/.config/yadm/bootstrap"
        break
      fi
    done
  fi
}

yadm_cleanup() {
  rm -rf "$(__get_tmpdir)"
}

# https://stackoverflow.com/a/28776166/1872036
if ! (return 2>/dev/null)
then
  set -e

  # This script is normally run as `curl ... | bash -s -- ...`, which leaves
  # stdin attached to curl's pipe instead of the terminal. rbw's pinentry
  # needs a real tty on stdin to know where to prompt (see `ttyname(stdin)`
  # in rbw's client) -- reattach it here so `rbw unlock` can find it.
  if ! [[ -t 0 ]] && [[ -r /dev/tty ]]
  then
    exec < /dev/tty
  fi

  cd "$HOME" || return 9

  while [[ -n "$*" ]]
  do
    case "$1" in
      local|--local|-l|l|-L)
        if [[ -z "$2" ]]
        then
          usage
          exit 2
        fi
        LOCAL_REPO="$2"
        shift 2
        ;;
      host|--host|-H)
        if [[ -z "$2" ]]
        then
          usage
          exit 2
        fi
        YADM_HOST="$2"
        shift 2
        ;;
      *)
        RBW_MASTER_PASSWORD="$1"
        shift
        break
        ;;
    esac
  done

  if [[ -z "$YADM_HOST" ]]
  then
    YADM_HOST="$(__detect_termux_host)"
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
fi

# vim: set et ts=2 sw=2 :
