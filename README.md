# Termux setup

Install the official Termux app, open it once, and wait until you reach its
shell prompt. Then paste this command **inside the Termux app**:

```sh
curl -fsSL https://raw.githubusercontent.com/pschmitt/yadm-init/main/bootstrap-termux-environment.sh | bash
```

The installer will explain that it replaces Termux's package tree and ask
before continuing. It keeps your home directory, updates the shared tool cache
under `~/.local`, and runs the existing yadm initializer after the new package
tree passes its startup checks. Keep Termux open on a reliable network; the
measured cold run was about 11 minutes, though download speed and package
updates can change that.

## What you will see

The setup is shown as four numbered phases. Longer package and extraction
steps show a spinner with elapsed time; archive downloads show transfer
progress when the terminal supports it. Bitwarden prompts are hidden while you
type. When the setup finishes, it opens Zsh. Type `exit` to return to Termux.

To disable color while keeping the same progress messages:

```sh
curl -fsSL https://raw.githubusercontent.com/pschmitt/yadm-init/main/bootstrap-termux-environment.sh | NO_COLOR=1 bash
```

## Options

`--archive-only` installs the archives and opens Zsh without cloning or
bootstrapping yadm. It still replaces the Termux package tree:

```sh
curl -fsSL https://raw.githubusercontent.com/pschmitt/yadm-init/main/bootstrap-termux-environment.sh | bash -s -- --archive-only
```

`--yes` skips the package-tree confirmation. Use it only when you intend to
replace the current Termux packages; Bitwarden still needs an interactive
terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/pschmitt/yadm-init/main/bootstrap-termux-environment.sh | bash -s -- --yes
```

For help, pass `--help` the same way. `--no-color` is also available; setting
`NO_COLOR` is usually more convenient for the `curl | bash` command.

## Recovery

- Answer `n` at the confirmation prompt to cancel before the installer changes
  packages or downloads the archives.
- If a download or integrity check fails, the current package tree is not
  replaced. Package updates performed at the start may already have completed.
- The installer keeps the previous package tree until the new Termux startup
  and yadm setup succeed. If yadm setup fails, the installer prints the backup
  path and exact commands to restore it.
- `--archive-only` is useful for separating Termux archive installation from
  yadm setup when troubleshooting.

## What gets installed

The installer upgrades Termux's initial packages, unlocks the Bitwarden item
for private download access, downloads the small `nixpp` verifier, then fetches
the signed Termux package and shell/tool archives. It validates the signed
cache outputs and archive paths before switching to the prepared package tree.

The archives contain no yadm dotfiles or Bitwarden credentials. The home
archive holds shared tool cache files; the private yadm repository is cloned
and bootstrapped separately by the existing initializer. No custom APK, Nix,
Ansible, compiler, or proot is needed on the phone.

This release is for the official Termux app on AArch64. The cache download
requires the configured Bitwarden access. `nixpp` verifies signed Nix cache
outputs; it does not evaluate Home Manager or install arbitrary Nix packages.

## Other setup paths

To preload only the older zinit cache before using the existing initializer:

```sh
curl -fsSL https://raw.githubusercontent.com/pschmitt/yadm-init/main/preseed-termux-cache.sh | bash
curl -fsSL y.brkn.lol | bash
```

That path does not replace the Termux package tree. The regular
`curl -fsSL y.brkn.lol | bash` command remains available for existing hosts and
continues to use its normal Ansible bootstrap.
