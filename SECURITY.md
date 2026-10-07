# Security policy

## Reporting a vulnerability

Report a vulnerability privately through GitHub's advisory form at https://github.com/thomaslaurenson/pass-env/security/advisories/new. Do not open a public issue for a security report. You will get an acknowledgement within a week, and a fix or a decision before anything is disclosed.

## Supported versions

Only the latest release receives security fixes. Upgrade before reporting if you are on an older version.

## What is in scope

- The `pass env` extension in `src/`
- The `passenv` shell loader and the uninstaller in `contrib/`
- The installer in `scripts/`
- The shell completions in `completion/`

The trust boundary, and what the tool deliberately does not defend against, is described under Security Notes in the README. A report that an entry in a store the attacker can write to can execute code is expected behaviour rather than a vulnerability, unless it bypasses a control the README says is in place.
