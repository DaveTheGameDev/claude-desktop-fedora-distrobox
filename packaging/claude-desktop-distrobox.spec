# Built by packaging/build-rpm.sh, which passes the version in from the git tag.
%{!?version: %define version 0.0.0}

Name:           claude-desktop-distrobox
Version:        %{version}
Release:        1%{?dist}
Summary:        Official Claude Desktop on Fedora via distrobox, privacy-hardened
License:        MIT
URL:            https://github.com/DaveTheGameDev/claude-desktop-fedora
BuildArch:      noarch

Source0:        install-claude-desktop-distrobox.sh
Source1:        claude-desktop-setup.desktop
Source2:        README.md
Source3:        LICENSE
Source4:        claude-desktop-setup.svg

BuildRequires:  desktop-file-utils
Requires:       bash
Requires:       distrobox
Requires:       podman
Requires:       zenity
# Native GTK4 setup window; falls back to zenity dialogs without these.
Recommends:     python3-gobject
Recommends:     libadwaita
Requires:       /usr/bin/notify-send
Requires:       xdg-utils
Requires:       curl
Requires:       polkit

%description
A setup tool that installs Anthropic's genuine, GPG-signed Claude Desktop .deb
inside an Ubuntu distrobox container and wires it into your Fedora desktop, with
privacy hardening (dedicated home directory, own network namespace).

This package only installs the setup tool and an app-menu entry
("Claude Desktop Setup"). The container and the Claude app themselves are
created rootless in your own home directory when you run it — nothing runs as
root at runtime. The Claude app is downloaded from Anthropic's apt repository
and its signing key fingerprint is verified before the repository is enabled.

%prep
%setup -q -c -T
cp -p %{SOURCE2} %{SOURCE3} .

%build
# nothing to compile

%install
install -Dpm 0755 %{SOURCE0} %{buildroot}%{_bindir}/claude-desktop-setup
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_datadir}/applications/claude-desktop-setup.desktop
install -Dpm 0644 %{SOURCE4} %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/claude-desktop-setup.svg

%check
desktop-file-validate %{buildroot}%{_datadir}/applications/claude-desktop-setup.desktop
bash -n %{buildroot}%{_bindir}/claude-desktop-setup
test "$(%{buildroot}%{_bindir}/claude-desktop-setup --version)" = "%{version}"

%files
%license LICENSE
%doc README.md
%{_bindir}/claude-desktop-setup
%{_datadir}/applications/claude-desktop-setup.desktop
%{_datadir}/icons/hicolor/scalable/apps/claude-desktop-setup.svg

%changelog
%autochangelog
