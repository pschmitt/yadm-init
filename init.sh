#!/usr/bin/env bash

usage() {
  echo "Usage: $(basename "$0") [--local DIR] [PASSPHRASE]"
}

query_passphrase() {
  local secret

  if [[ -n "$ZSH_VERSION" ]]
  then
    read -rs "secret?Passphrase: " < /dev/tty
  else
    read -rs -p "Passphrase: " secret < /dev/tty
  fi

  if [[ -z "$secret" ]]
  then
    return 1
  fi

  echo "$secret"
}

install_deps() {
  if command -v termux-info >/dev/null
  then
    yes | pkg upgrade -y
    pkg install -y curl git openssh sshpass
  elif command -v apt >/dev/null
  then
    sudo apt update
    sudo apt install -y curl git openssh-client sshpass
  elif command -v dnf >/dev/null
  then
    sudo dnf install -y curl git openssh-clients sshpass
  elif command -v pacman >/dev/null
  then
    sudo pacman -Sy --noconfirm curl git openssh sshpass x11-ssh-askpass
  elif command -v apk >/dev/null
  then
    sudo apk update
    sudo apk add git curl openssh-client sshpass
  elif command -v nixos-help >/dev/null
  then
    nix-env -iA nixos.curl nixos.git nixos.openssh nixos.sshpass
  elif uname -s | grep -q CYGWIN_NT
  then
    cygwin_install_apt-cyg
    cygwin_install_pkg curl git openssh zsh sshpass
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

get_ssh_key() {
  local urls=(
    "https://github.com/pschmitt/yadm-init.git"
    "https://git.heimat.dev/pschmitt/yadm-init.git"
  )
  local PASSPHRASE="${1:-$PASSPHRASE}"

  cd "$TMPDIR" || exit 9
  rm -rf yadm-init

  # Attempt to clone
  for url in "${urls[@]}"
  do
    if git clone "$url"
    then
      break
    fi
  done

  mkdir -m 700 -p "${HOME}/.ssh"
  cp -fv yadm-init/.ssh/id_yadm_init{,.pub} "${HOME}/.ssh"
  rm -rf yadm-init
  chmod 400 "${HOME}"/.ssh/id_yadm_init{,.pub}

  # Add key to agent to avoid being prompted multiple times
  if command -v ssh-add >/dev/null
  then
    if [[ -z "$SSH_AGENT_PID" ]]
    then
      eval "$(ssh-agent)"
    fi

    local ssh_key="${HOME}/.ssh/id_yadm_init"
    if [[ -n "$PASSPHRASE" ]]
    then
      if ! timeout 10 \
        sshpass -p "$PASSPHRASE" -P "Enter passphrase" \
          ssh-add "$ssh_key"
      then
        echo "Invalid passphrase. Please correct." >&2
        ssh-add "$ssh_key"
      fi
    else
      ssh-add "$ssh_key"
    fi
  fi
}

add_trusted_key() {
  # ssh-keyscan -H git.heimat.dev -p 2022 >> ~/.ssh/known_hosts
  # ssh-keyscan -H github.com -p 22 >> ~/.ssh/known_hosts
  # ssh-keyscan -H ssh.github.com -p 443 >> ~/.ssh/known_hosts
  cat > ~/.ssh/known_hosts <<- "EOF"
[git.heimat.dev]:2022 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDjzWxWTy/pAo3NsDyX6r0WM3sV1RLJ69uQ2SkGUAiX6ebhPREFdC3LkIm/UdlBDMGrRYf8kcpJ/xAatm3vrDX8HNqbe02YgL1S71G8ow0ShcCJswTpZmR2MN2XGRCvgnC4JdbkTUQWjS2L2T/H9iog64tWCGrh67+/vqgI4wUoXPieEUHgisKWXQgOwpzzSKK+4Eeq0ekr2uds0zlbzIuPD9xN4EltiuYspPnGbx1zxznGoMBNn5vI/lHrjXXrb5U6CHnWRpFSN+u26zqkEu4DLfmrMHdnduJwfSxSYKQfhoAjiL79yI1DQPm/UHCAuJLhLxS/QAmb2n1yy7OWaT6V
[git.heimat.dev]:2022 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBB0pGWBFLVTfT+4Uo5X/+/PIXrz81MK0HfLJTrE7PAGTXF9SKMtnOXKezP5alvGjMA34w9vWSeSzbp9vmm4QJGk=
[git.heimat.dev]:2022 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL1uwv8wPaet+akmf9nFh4PnDiUjPR62SJYtH2OUXXbB
github.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==
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
    "ssh://git@git.heimat.dev:2022/pschmitt/yadm-config.git"
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
      *)
        PASSPHRASE="$1"
        shift
        break
        ;;
    esac
  done

  # Ask for passphrase if not already provided
  if [[ -z "$PASSPHRASE" ]]
  then
    PASSPHRASE=$(query_passphrase)
  fi

  install_deps
  install_yadm

  if [[ -z "$LOCAL_REPO" ]]
  then
    get_ssh_key "$PASSPHRASE"
  fi

  add_trusted_key
  yadm_deinit
  yadm_init
  yadm_cleanup
fi

# vim: set et ts=2 sw=2 :
