# pass-env

A passwordstore extension to export secrets as environment variables

## Requirements

- pass
- gnupg (dependency of pass)
- fzf

## Testing

Tests use [bats-core](https://github.com/bats-core/bats-core), included as a git submodule.

```bash
git submodule update --init
make test
```
