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
  local url="https://git.comreset.io/pschmitt/yadm-init.git"
  local alt_url="git@github.com:pschmitt/yadm-init.git"
  cd "$TMPDIR" || exit 9
  rm -rf yadm-init
  if ! git clone "$url"
  then
    git clone "$alt_url"
  fi
  mkdir -m 700 -p "${HOME}/.ssh"
  cp -fv yadm-init/.ssh/id_yadm_init{,.pub} "${HOME}/.ssh"
  rm -rf yadm-init
  chmod 400 "${HOME}"/.ssh/id_yadm_init{,.pub}
}

add_trusted_key() {
  # ssh-keyscan -H git.comreset.io -p 2022 >> ~/.ssh/known_hosts
  cat > ~/.ssh/known_hosts <<- "EOF"
[git.comreset.io]:2022 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDjzWxWTy/pAo3NsDyX6r0WM3sV1RLJ69uQ2SkGUAiX6ebhPREFdC3LkIm/UdlBDMGrRYf8kcpJ/xAatm3vrDX8HNqbe02YgL1S71G8ow0ShcCJswTpZmR2MN2XGRCvgnC4JdbkTUQWjS2L2T/H9iog64
tWCGrh67+/vqgI4wUoXPieEUHgisKWXQgOwpzzSKK+4Eeq0ekr2uds0zlbzIuPD9xN4EltiuYspPnGbx1zxznGoMBNn5vI/lHrjXXrb5U6CHnWRpFSN+u26zqkEu4DLfmrMHdnduJwfSxSYKQfhoAjiL79yI1DQPm/UHCAuJLhLxS/QAmb2n1yy7OWaT6V
[git.comreset.io]:2022 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBB0pGWBFLVTfT+4Uo5X/+/PIXrz81MK0HfLJTrE7PAGTXF9SKMtnOXKezP5alvGjMA34w9vWSeSzbp9vmm4QJGk=
[git.comreset.io]:2022 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL1uwv8wPaet+akmf9nFh4PnDiUjPR62SJYtH2OUXXbB
EOF
  chmod 600 ~/.ssh/known_hosts
}

yadm_deinit() {
  if ! yadm status >/dev/null
  then
    return
  fi
  for file in $(yadm ls-tree -r master --full-tree | awk '{ print $NF }')
  do
    rm -rf "$file"
  done
}

yadm_init() {
  local url="ssh://git@git.comreset.io:2022/pschmitt/yadm-config.git"
  local alt_url="git@github.com:pschmitt/yadm-config.git"
  yadm_deinit
  if [[ -n "$LOCAL_REPO" ]]
  then
    bash "$(__get_tmpdir)/yadm" clone -f --bootstrap "$LOCAL_REPO"
  else
    GIT_SSH_COMMAND="ssh -i ~/.ssh/id_yadm_init -F /dev/null" \
    bash "$(__get_tmpdir)/yadm" clone -f --bootstrap "$url"
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
yadm_init
yadm_cleanup
# fi

# vim: set et ts=2 sw=2 :
