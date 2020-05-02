#!/usr/bin/env bash

usage() {
  echo "Usage: $(basename "$0") [--local DIR]"
}

install_deps() {
  if command -v termux-info >/dev/null
  then
    pkg install -y git openssh
  elif command -v apt >/dev/null
  then
    sudo apt update
    sudo apt install -y git openssh-client
  elif command -v dnf >/dev/null
  then
    sudo dnf install -y git openssh-clients
  elif command -v pacman >/dev/null
  then
    sudo pacman -Sy --noconfirm git openssh
  elif uname -s | grep -q CYGWIN_NT
  then
    cygwin_install_apt-cyg
    cygwin_install_pkg git openssh zsh
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
    "https://git.comreset.io/pschmitt/yadm-init.git"
  )

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
}

add_trusted_key() {
  # ssh-keyscan -H git.comreset.io -p 2022 >> ~/.ssh/known_hosts
  # ssh-keyscan -H github.com -p 22 >> ~/.ssh/known_hosts
  # ssh-keyscan -H ssh.github.com -p 443 >> ~/.ssh/known_hosts
  cat > ~/.ssh/known_hosts <<- "EOF"
[git.comreset.io]:2022 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDjzWxWTy/pAo3NsDyX6r0WM3sV1RLJ69uQ2SkGUAiX6ebhPREFdC3LkIm/UdlBDMGrRYf8kcpJ/xAatm3vrDX8HNqbe02YgL1S71G8ow0ShcCJswTpZmR2MN2XGRCvgnC4JdbkTUQWjS2L2T/H9iog64tWCGrh67+/vqgI4wUoXPieEUHgisKWXQgOwpzzSKK+4Eeq0ekr2uds0zlbzIuPD9xN4EltiuYspPnGbx1zxznGoMBNn5vI/lHrjXXrb5U6CHnWRpFSN+u26zqkEu4DLfmrMHdnduJwfSxSYKQfhoAjiL79yI1DQPm/UHCAuJLhLxS/QAmb2n1yy7OWaT6V
[git.comreset.io]:2022 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBB0pGWBFLVTfT+4Uo5X/+/PIXrz81MK0HfLJTrE7PAGTXF9SKMtnOXKezP5alvGjMA34w9vWSeSzbp9vmm4QJGk=
[git.comreset.io]:2022 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL1uwv8wPaet+akmf9nFh4PnDiUjPR62SJYtH2OUXXbB
github.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==
[ssh.github.com]:443 ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==
EOF
  chmod 600 ~/.ssh/known_hosts
}

yadm_deinit() {
  local file
  if ! yadm status >/dev/null
  then
    return
  fi
  # Delete submodules
  # Disable check since we want to expand $(pwd) at "runtime"
  # shellcheck disable=2016
  yadm submodule foreach 'rm -rf $(pwd)'
  # Delete tracked files
  for file in $(yadm ls-tree -r master --full-tree | awk '{ print $NF }')
  do
    rm -rf "$file"
  done
  rm -rf "${HOME}/.config/yadm" "${HOME}/.gitmodules"
}

yadm_init() {
  local url
  local urls=(
    "git@github.com:pschmitt/yadm-config.git"
    "ssh://git@ssh.github.com:443/pschmitt/yadm-config.git"
    "ssh://git@git.comreset.io:2022/pschmitt/yadm-config.git"
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

# FIXME This breaks piping into bash
# if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
# then
set -ex

case "$1" in
  local|--local|-l|l|-L)
    if [[ -z "$2" ]]
    then
      usage
      exit 2
    fi
    LOCAL_REPO="$2"
    ;;
esac

install_deps
install_yadm
if [[ -z "$LOCAL_REPO" ]]
then
  get_ssh_key
fi
add_trusted_key
yadm_deinit
yadm_init
yadm_cleanup
# fi

# vim: set et ts=2 sw=2 :
