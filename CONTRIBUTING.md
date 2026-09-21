# Contributing

Bug reports, documentation corrections, and compatibility test results are all
welcome. Compatibility reports are the most useful thing you can send: this
project is verified on Bazzite KDE, and every other Fedora Atomic desktop is
unverified until somebody reports back.

## Before opening an issue

Run the health check and include its output:

```bash
./install.sh --verify
```

It makes no changes, needs no `sudo`, and reports the state of every piece of
the integration. Also include:

- Distribution and desktop environment
- CPU architecture
- PIA client version
- The command that failed
- Relevant terminal output with usernames, tokens, and other private details
  removed

Never post PIA credentials, account numbers, VPN tokens, or complete logs that
may contain private network information.

## Code changes

1. Keep the installer readable and auditable. Someone should be able to read the
   whole script before running it.
2. Never download executable files from anywhere other than PIA's official
   installer storage.
3. Never collect, store, or transmit PIA credentials.
4. Prefer failing loudly over guessing. If a step cannot be completed safely,
   stop and explain what the user should check.
5. Anything written outside the user's home directory should be recorded in the
   state directory so `uninstall.sh` can remove exactly what was added, and
   nothing else.

### Checks to run before submitting

```bash
for script in install.sh install-stage1.sh install-stage2.sh uninstall.sh; do
  bash -n "$script"
done
shellcheck -S style install.sh install-stage1.sh install-stage2.sh uninstall.sh
desktop-file-validate desktop/private-internet-access.desktop
```

The same checks run in CI on every pull request. If you change behaviour, add a
line to `CHANGELOG.md` under an Unreleased heading, and say which Fedora Atomic
distribution you tested on.
