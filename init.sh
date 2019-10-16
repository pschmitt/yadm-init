#!/usr/bin/env bash

get_ssh_key() {
  local url="https://git.comreset.io/yadm-init"
  mkdir -p ~/.ssh
  curl -qqs "$url" > ~/.ssh/id_yadm_init
}

if command -v termux-info >/dev/null 2>&1
then
  pkg install -y yadm
elif command -v apt >/dev/null 2>&1
then
  apt update
  apt install -y yadm
elif command -v pacman >/dev/null 2>&1
then
  pacman -Sy yadm
fi

yadm clone ssh://git@git.comreset.io:2022/pschmitt/yadm-config.git

# vim: set et ts=2 sw=2 :
