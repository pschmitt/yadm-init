#!/usr/bin/env bash

install_deps() {
  if command -v termux-info >/dev/null 2>&1
  then
    pkg install -y yadm git openssh
  elif command -v apt >/dev/null 2>&1
  then
    apt update
    apt install -y yadm git openssh-client
  elif command -v pacman >/dev/null 2>&1
  then
    pacman -Sy --noconfirm yadm git openssh
  fi
}

get_ssh_key() {
  local url="https://git.comreset.io/pschmitt/yadm-init.git"
  cd "$TMPDIR" || exit 9
  git clone "$url"
  mkdir -p ~/.ssh
  cp yadm-init/.ssh/id_yadm_init{,.pub} ~/.ssh
  rm -rf yadm-init
  chmod 600 ~/.ssh/id_yadm_init
}

yadm_init() {
  GIT_SSH_COMMAND="ssh -i ~/.ssh/id_yadm_init -F /dev/null" \
    yadm clone --bootstrap ssh://git@git.comreset.io:2022/pschmitt/yadm-config.git
}

install_deps
get_ssh_key
yadm_init

# vim: set et ts=2 sw=2 :
