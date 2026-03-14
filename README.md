# pass-env

A passwordstore extension to export secrets as environment variables

## Requirements

- pass
- gnupg (dependency of pass)
- fzf

## Installation

On Debian-based systems:

```
sudo apt install -y pass fzf
curl -fsSL https://github.com/thomaslaurenson/pass-env/releases/latest/download/install.sh | bash
```

## Testing

Tests use [bats-core](https://github.com/bats-core/bats-core), included as a git submodule.

```bash
git submodule update --init
make test
```
