# Contributing

Thanks for taking an interest. This is a small project with one maintainer, so keep things simple.

## Reporting a bug

Open an issue with:

- Fedora version (`cat /etc/os-release`), `podman --version`, `distrobox --version`
- How you installed (RPM / script) and what you ran
- The full output. For update problems: `journalctl --user -u claude-desktop-update`
- Whether it reproduces with `--recreate`

**Security issues go to [SECURITY.md](SECURITY.md), not the issue tracker.**

## Changing the code

Everything lives in one script, `install-claude-desktop-distrobox.sh`. The GUI setup app is the
same script with `--gui`. Packaging is in `packaging/`, and the release workflow builds the RPM
from a tag.

Before opening a PR:

1. `bash -n install-claude-desktop-distrobox.sh` and `shellcheck` it — keep it clean.
2. Test the path you touched for real: `--recreate` for install changes, `--update` for update
   changes, `--remove` then reinstall if you touched cleanup. Test both `--gui` and terminal
   modes if the change affects prompts.
3. If you change a flag, update the **usage text in the script**, the **Command reference** table
   in the README, and `CHANGELOG.md`.
4. One change per PR. Say what you tested in the description.

## Ground rules

- **No repackaging.** The whole point is that the app is Anthropic's signed `.deb` from Anthropic's
  apt repo. Anything that downloads a binary from somewhere else, or patches the app, won't be merged.
- **Don't weaken the isolation by default.** New host access (mounts, sockets, host network) must
  be opt-in with a flag, documented in the *Security & trust model* section, and justified.
- **Fedora / RHEL first.** Other distros are welcome as long as they don't complicate the main path.
- No new dependencies unless they're in the Fedora repos.

## Releasing (maintainer)

See *Releasing (maintainers)* in the README: bump `VERSION` in the script, update
`CHANGELOG.md`, tag `vX.Y.Z`, push the tag. The workflow builds and attaches the RPM.
