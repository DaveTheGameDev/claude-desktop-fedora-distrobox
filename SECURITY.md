# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Use GitHub's private reporting instead:
**[Report a vulnerability](https://github.com/DaveTheGameDev/claude-desktop-fedora-distrobox/security/advisories/new)**.
Only the maintainer sees it. You'll get an acknowledgement within a few days; fixes ship as a
tagged release with a CHANGELOG entry crediting you, unless you'd rather not be named.

## What's in scope

Anything in this repository:

- the installer / setup script (`install-claude-desktop-distrobox.sh`), including its `--gui` mode
- the generated host launcher, `.desktop` entry, and systemd user units
- the RPM spec and the release workflow
- documentation that would lead a user to a less safe configuration than they think they have

Examples of what we'd consider a vulnerability:

- the app gaining access to host paths, sockets or the host network that the README says it doesn't have
- the signing-key fingerprint check being bypassable
- the installer or timer running something with more privilege than documented
- a way for a malicious container image or apt response to execute code on the host

## What's out of scope

- **Claude Desktop itself.** The app is Anthropic's; report app vulnerabilities to
  [Anthropic's security team](https://www.anthropic.com/security). This project installs it unchanged.
- **distrobox / podman** — report upstream.
- The known limits documented in the README's *Security & trust model*: the host filesystem is
  reachable at `/run/host` (this is how distrobox works), Chromium's inner sandbox is disabled
  (the container is the boundary), and the host system D-Bus is passed through by default.
  These are design trade-offs, not bugs; see the README for the flags that change them.

## Supported versions

Only the latest tagged release gets fixes.
