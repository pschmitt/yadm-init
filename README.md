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
clone or bootstrap the yadm configuration.
