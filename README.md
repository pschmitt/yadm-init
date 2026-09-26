# Usage

```
curl -fsSL y.brkn.lol | bash
```

## Preload Termux zsh and tmux cache

On Termux aarch64, run this first to fetch the private cache using the
`blobs.brkn.lol private downloads` Bitwarden item, then run the existing
initializer above:

```
curl -fsSL https://raw.githubusercontent.com/pschmitt/yadm-init/main/preseed-termux-cache.sh | bash
curl -fsSL y.brkn.lol | bash
```

The preseed script installs the verified cache under `~/.local`; it does not
clone or bootstrap the yadm configuration. On a fresh Termux install, it first
updates and fully upgrades the Termux packages so the bundled `curl` and its
shared libraries are compatible before the script downloads anything else.

For a complete prepared environment, use the separate provisioner below. It
installs the private AArch64 `$PREFIX` image and the non-dotfile home cache,
then runs the existing yadm initializer:

```
curl -fsSL https://raw.githubusercontent.com/pschmitt/yadm-init/main/bootstrap-termux-environment.sh | bash
```

The home archive contains only `.local/{bin,lib,share}` cache data. The prefix
archive contains the Termux package tree and package database. Neither archive
contains `$HOME` dotfiles or Bitwarden data. Pass `--archive-only` to install
the archives without running the yadm initializer. The provisioner downloads
the first-stage `nixpp` client and a private cache channel using the existing
Bitwarden-backed basic-auth credentials. `nixpp` then fetches the prefix and
home outputs from the signed Nix cache, validating the builder signature,
archive hashes, and NAR paths before extraction. The stable channel and client
paths point to immutable published outputs. It shows colored phase status and
download bars on an interactive terminal; set
`NO_COLOR=1` to disable color:

```
curl -fsSL https://raw.githubusercontent.com/pschmitt/yadm-init/main/bootstrap-termux-environment.sh | NO_COLOR=1 bash
```

With the prepared-environment marker set, yadm applies the Termux local
classes and runs Termux-specific setup from its bootstrap script without
installing Ansible. The ordinary yadm initializer continues to use Ansible.
