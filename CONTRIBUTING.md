# Contributing

Bug reports, documentation corrections, and compatibility test results are welcome.

When opening an issue, include:

- Distribution and desktop environment
- CPU architecture
- PIA client version
- The command that failed
- Relevant terminal output with usernames, tokens, and other private details removed

Please do not submit PIA credentials, account numbers, VPN tokens, or complete logs that may contain private network information.

For code changes:

1. Keep the installer readable and auditable.
2. Avoid downloading executable files from unofficial hosts.
3. Do not collect or store PIA credentials.
4. Run `bash -n install.sh install-stage1.sh install-stage2.sh uninstall.sh` before submitting.
5. Explain which Fedora Atomic distribution you tested.
