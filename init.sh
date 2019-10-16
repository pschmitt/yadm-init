#!/usr/bin/env bash

install_deps() {
  local packages="yadm git"
  if command -v termux-info >/dev/null 2>&1
  then
    pkg install -y $packages
  elif command -v apt >/dev/null 2>&1
  then
    apt update
    apt install -y $packages
  elif command -v pacman >/dev/null 2>&1
  then
    pacman -Sy --noconfirm $packages
  fi
}

get_ssh_key() {
  local url="https://git.comreset.io/pschmitt/yadm-init.git"
  cd "$TMPDIR" || exit 9
  git clone "$url"
  mkdir -p ~/.ssh
  mv .ssh/id_yadm_init* ~/.ssh
  rm -rf yadm-init
}

yadm_init() {
  yadm clone ssh://git@git.comreset.io:2022/pschmitt/yadm-config.git
}

install_deps
get_ssh_key
yadm_init

# vim: set et ts=2 sw=2 :
