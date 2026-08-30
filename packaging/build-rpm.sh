#!/usr/bin/env bash
# Build the noarch RPM. Usage: packaging/build-rpm.sh [version]
# Version defaults to the nearest git tag (vX.Y.Z -> X.Y.Z). Prints the rpm path.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

version="${1:-}"
if [[ -z "$version" ]]; then
  version="$(git -C "$root" describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)"
fi
version="${version#v}"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "bad version: $version" >&2; exit 1; }

script_version="$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$root/install-claude-desktop-distrobox.sh" | head -n1)"
if [[ "$script_version" != "$version" ]]; then
  echo "error: VERSION in install-claude-desktop-distrobox.sh is '$script_version' but building '$version'." >&2
  echo "       Bump VERSION= in the script (and CHANGELOG.md) before tagging." >&2
  exit 1
fi

topdir="${RPM_TOPDIR:-$(mktemp -d)}"
mkdir -p "$topdir"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cp "$root/install-claude-desktop-distrobox.sh" \
   "$root/packaging/claude-desktop-setup.desktop" \
   "$root/packaging/icons/claude-desktop-setup.svg" \
   "$root/README.md" "$root/LICENSE" "$topdir/SOURCES/"

# %autochangelog needs rpmautospec; substitute a plain entry when it is absent.
spec="$topdir/SPECS/claude-desktop-distrobox.spec"
if command -v rpmautospec >/dev/null 2>&1; then
  cp "$root/packaging/claude-desktop-distrobox.spec" "$spec"
else
  sed "s|^%autochangelog|* $(date +'%a %b %d %Y') Release Bot <noreply@github.com> - $version-1\n- Release $version|" \
    "$root/packaging/claude-desktop-distrobox.spec" > "$spec"
fi

rpmbuild -bb --define "_topdir $topdir" --define "version $version" "$spec" >&2
rpm="$(find "$topdir/RPMS" -name '*.rpm' -print -quit)"
out="${OUT_DIR:-$root/dist}"
mkdir -p "$out"
cp "$rpm" "$out/"
echo "$out/$(basename "$rpm")"
