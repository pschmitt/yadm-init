#!/usr/bin/env bash

install_deps() {
  if command -v termux-info >/dev/null 2>&1
  then
    pkg install -y git openssh
  elif command -v apt >/dev/null 2>&1
  then
    sudo apt update
    sudo apt install -y git openssh-client
  elif command -v pacman >/dev/null 2>&1
  then
    sudo pacman -Sy --noconfirm git openssh
  else
    echo "Unknown OS or distribution" >&2
    return 3
  fi
}

__get_tmpdir() {
  echo "${TMPDIR:-/tmp}/yadm"
}

install_yadm() {
  local tmpdir="$(__get_tmpdir)"
  mkdir -p "$tmpdir"
  curl -qsfLo "${tmpdir}/yadm" \
    https://github.com/TheLocehiliosan/yadm/raw/master/yadm
  chmod a+x "${tmpdir}/yadm"
  export PATH="${tmpdir}:${PATH}"
}

get_ssh_key() {
  local url="https://git.comreset.io/pschmitt/yadm-init.git"
  cd "$TMPDIR" || exit 9
  rm -rf yadm-init
  git clone "$url"
  mkdir -m 700 -p ~/.ssh
  cp -fv yadm-init/.ssh/id_yadm_init{,.pub} "${HOME}/.ssh"
  rm -rf yadm-init
  chmod 400 ~/.ssh/id_yadm_init{,.pub}
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

yadm_init() {
  local url="ssh://git@git.comreset.io:2022/pschmitt/yadm-config.git"
  rm -rf "${HOME}/.gitmodules"
  GIT_SSH_COMMAND="ssh -i ~/.ssh/id_yadm_init -F /dev/null" \
    bash "$(__get_tmpdir)/yadm" clone -f --bootstrap "$url"
}

yadm_cleanup() {
  rm -rf "$(__get_tmpdir)"
}

# FIXME This breaks piping into bash
# if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
# then
set -ex

install_deps
install_yadm
get_ssh_key
add_trusted_key
yadm_init
yadm_cleanup
# fi

# vim: set et ts=2 sw=2 :
