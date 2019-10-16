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

add_trusted_key() {
  # ssh-keyscan -H git.comreset.io -p 2022 >> ~/.ssh/authorized_keys
  cat > ~/.ssh/authorized_keys <<- "EOF"
|1|FOEbOeHQWYJvOEq6TuMCZeXpXBo=|p3PuYvNYbf5LNwzTeEjNdDBFl/s= ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOaSAsJXaxKjhtNSA7rWPtmCJYn/r0v7Xm/ZpC+Jn+pf1xt7TH7PeC6iczgCwL2q7uh7vUi7Yn1vGr5qcQy1K9aTF8xLVKWUD+H4Kh77oUFJ0p8pcSCTXkRl3cvWLfSSOVE5kjJgN4eUvUORzcY6jCg8HGh4rJIPeKgpTBGut0eMBPB9IvgnqxnSHiYz7GSqW//1Xj49ffR3H2pRIxe5ij75+X0yOqws65zIKtoUHq+bCXkr4VdBRZaq7ukJZ1/K/feuC52fbpR2ut8O0XgzF2NMl5jeG1oMOQBfDeVjyCSw8AmGoYt9ahKCRlNAdVUwnFrQl6v6W5x3ptbsqBreSB
|1|GzUn+Xv+mLRMNkkN1qL/QGnaxMY=|N4vLI9HYeQwKH1UlSi5uymEiidI= ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBL3hkYuoAvI66HTT/XRtHNPUWpGU0KP4Bz2VIJqMqguHLTeslXHihhuYzrIX2vyJ0C1O/ifKYxSq5fdN1wPeT6Q=
|1|RHKQ3eKrdoxnn7YDR2DocUNZuPE=|vM9qvumVnYJdHtLSZ8dmItWkwUo= ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHmqpF91ZH16AVCk8wnWoe/vCkizh0nGmVy2F8dT290A
EOF
}

yadm_init() {
  GIT_SSH_COMMAND="ssh -i ~/.ssh/id_yadm_init -F /dev/null" \
    yadm clone --bootstrap ssh://git@git.comreset.io:2022/pschmitt/yadm-config.git
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  install_deps
  get_ssh_key
  add_trusted_key
  yadm_init
fi

# vim: set et ts=2 sw=2 :
