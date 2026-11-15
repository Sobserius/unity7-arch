# Unity 7 for Arch Linux

Build and install the **Unity 7.7 desktop** on Arch Linux from source, with the
**original Ubuntu look**: Ambiance/Radiance GTK themes, Humanity icons,
DMZ-White cursors, the Ubuntu font, the Ubuntu 17.04 wallpaper and the real
`unity-greeter` login screen.

This repository is a complete, self-contained package set plus an installer that
orders the ~47 source builds by their actual dependencies, installs them, configures
LightDM, and can cleanly undo everything.

```
  ┌──────────────────────────────────────────────────────────────┐
  │  Unity 7 for Arch Linux                                      │
  │                                                              │
  │  1) Install Unity 7 (build from source)                      │
  │  2) Install / update from prebuilt packages (no compiling)   │
  │  3) Uninstall Unity 7                                        │
  │  4) Build packages only (no desktop configuration)           │
  │  5) Choose / change the login greeter                        │
  │  6) Show status                                              │
  │  q) Quit                                                     │
  └──────────────────────────────────────────────────────────────┘
```

## What you get

| Component | Source |
| --- | --- |
| Unity 7.7.1 shell, Dash, Launcher, Panel, HUD | `gitlab.com/ubuntu-unity/unity` |
| Compiz 0.9.14.2 (Ubuntu build) | Ubuntu archive |
| Nux, Bamf, Dee, Geis, IdO, libunity, indicators, lenses | Ubuntu archive / upstream |
| Unity Control Center, Unity Settings Daemon | Ubuntu archive |
| `unity-greeter` 25.04 | `gitlab.com/ubuntu-unity/unity/unity-greeter` |
| Ambiance + Radiance (`light-themes`) | `ubuntu-themes` 24.04 |
| Humanity + Humanity-Dark | `humanity-icon-theme` 0.6.16 |
| ubuntu-mono panel icons | `ubuntu-themes` |
| DMZ-White / DMZ-Black cursors | `dmz-cursor-theme` (Debian source) |
| Ubuntu font family | `fonts-ubuntu` |
| Ubuntu 17.04 wallpaper (`warty-final-ubuntu.png`, last Unity release) | `ubuntu-wallpapers` |
| GTK2 + Murrine engine (for Ambiance GTK2 apps) | AUR recipes, vendored |

Unity runs on **X11**. Your existing Wayland sessions (GNOME, Sway, ...) are not
touched and remain selectable.

## Requirements

- Arch Linux, `x86_64`
- `base-devel` and `git` (`sudo pacman -S --needed base-devel git`)
- An OpenGL-capable GPU (Intel, AMD or NVIDIA with the proprietary driver)
- ~8–12 GB of free disk while building; 1–3 hours on a slow machine,
  about 40 minutes on a 12-core desktop
- `sudo` (the installer asks for your password **once** and keeps the sudo
  ticket alive for the whole build, so a long install does not prompt again)

## Quick start

```bash
git clone https://github.com/Sobserius/unity7-arch.git
cd unity7-arch
./install.sh
```

Pick **1) Install Unity 7**. The installer will:

1. Read every `pkgs/*/PKGBUILD`, resolve the real dependency graph with `tsort`
   and build in the correct order (`gtk2` → `nux` → `compiz-ubuntu` → `unity` → ...).
2. Build and install each package with `makepkg -si`; logs go to `logs/`.
3. Record every package it installed in `/var/lib/unity7-arch/packages`.
4. Install and configure LightDM, then let you **pick the greeter**.
   `unity-greeter` is the default; other installed LightDM greeters are listed too.
5. Apply the classic theme defaults, point the current user at the Ubuntu 17.04
   wallpaper (17.04 was the last release that shipped Unity) and verify the result.

Then reboot and choose **Unity** at the login screen.

Prefer not to compile? `./install.sh --install --prebuilt` installs the same
package set from the binary release in a few minutes. See
[Fast install and updates](#fast-install-and-updates-no-compiling).

### Keeping your current display manager

If you already use GDM/SDDM and do not want LightDM, answer **no** when asked, or
run:

```bash
./install.sh --install --keep-dm
```

Unity still appears in the session menu of GDM/SDDM. You just won't see
`unity-greeter` at boot.

### Non-interactive

```bash
./install.sh --install --yes --greeter unity-greeter
./install.sh --install --yes --keep-dm
```

## Fast install and updates (no compiling)

The whole package set is also published as prebuilt binaries on the `repo`
release of this repository. Use them to install in a few minutes, or to update
later without rebuilding anything:

```bash
./install.sh --install --prebuilt   # install from the binary release
./install.sh --update               # update installed packages only
```

Both actions download `unity-arch.db` plus the packages, compare versions with
what is installed, preinstall any missing official Arch dependencies, and then
let `pacman -U` upgrade only the packages that actually changed. Your config,
themes and display-manager setup are left alone.

The release URL can be pointed at a mirror or a local directory for testing:

```bash
UNITY7_ARCH_PREBUILT_URL=file:///srv/unity7-mirror ./install.sh --update
```

If you prefer the interactive menu, option **2** does the same thing.

## The greeter

`install.sh` lists every `/usr/share/xgreeters/*.desktop` it can find:

```
Available greeters:
   1) unity-greeter                Unity Greeter
   2) lightdm-gtk-greeter          LightDM GTK+ Greeter
Greeter [1]:
```

`unity-greeter` comes from this repository. If you pick another greeter that is
not installed, the script offers to install it from the official repositories.
The choice is written to:

```
/etc/lightdm/lightdm.conf.d/50-unity7-arch.conf
```

```ini
[Seat:*]
greeter-session=unity-greeter
user-session=unity
```

Change it later with `./install.sh --greeter`.

## Recovering a broken graphical login

If LightDM or Compiz fails, switch to a TTY with **Ctrl+Alt+F3** and run:

```bash
sudo systemctl disable lightdm
sudo systemctl enable gdm       # or sddm, or whichever you used before
sudo reboot
```

The installer saved the previous `display-manager.service` link in
`/var/lib/unity7-arch/backup/`. Uninstalling restores it automatically.

## Uninstall

```bash
./install.sh --uninstall
# or
./uninstall.sh
```

This removes exactly the packages listed in `/var/lib/unity7-arch/packages`,
restores the previous LightDM configuration and display manager, and deletes the
state directory. It deliberately **does not** remove official dependency packages
(`gtk3`, `xorg-server`, `lightdm`, ...) or your personal config in `~/.config`.

## Options

```
Usage: ./install.sh [action] [options] [package...]

Actions
  -i, --install        build and install Unity 7 from source
  -U, --update         update installed packages from the prebuilt release
  -u, --uninstall      remove everything this script installed
  -b, --build          build/install packages, skip desktop configuration
  -g, --greeter        choose / change the LightDM greeter
  -s, --status         print installation status
      --list           list packages in dependency build order

Options
  -y, --yes            assume yes, never prompt
      --prebuilt       with --install, use prebuilt binaries (no compiling)
      --keep-dm        install without switching the display manager
      --greeter NAME   greeter to use (default: unity-greeter)
      --rebuild        rebuild packages even if already installed
```

Build only a few packages (their dependencies must already be installed):

```bash
./install.sh --build nux unity
```

## Repository layout

```
install.sh              installer / uninstaller / greeter picker
uninstall.sh            wrapper for install.sh --uninstall
build.sh                wrapper for install.sh --build
makepkg.conf            reproducible build flags
mirror-sources.sh       upstream helper (kept for reference)
pkgs/<name>/PKGBUILD    one directory per package, patches next to it
logs/                   build logs (gitignored)
repo/                   built packages (gitignored)
```

## Customising the look

`unity-control-center appearance` (System Settings → **Appearance**) is the
main panel: it switches between **Ambiance** and **Radiance**, changes the icon
colour set (Ubuntu Mono Dark/Light, Humanity), adjusts the launcher and picks a
wallpaper. The Ubuntu 17.04 background (the last Unity-era default) is selected
by the installer.

For the rest of Unity's options use **CompizConfig Settings Manager**:

```bash
ccsm          # launcher, expo, scale, effects, window decorations
```

`ccsm` is installed with `compiz-ubuntu`. There is no `unity-tweak-tool` package
for Arch; launcher autohide and icon size are in the Appearance panel, and the
remaining Unity keys are readable with
`gsettings list-recursively com.canonical.Unity`.

## Notes and known issues

- **X11 only.** Compiz is an X11 compositor; there is no Wayland session for Unity 7.
- **First login** can be slow while Compiz compiles its shader cache and the
  daemons initialise. Log out and back in once if the panel looks empty.
- **NVIDIA**: use the proprietary driver. Nouveau may work but Compiz needs solid
  GLX. On hybrid laptops, run the X server on the discrete GPU or use
  `__GLX_VENDOR_LIBRARY_NAME=nvidia`.
- **VMs**: VirtualBox/VMware need 3D acceleration enabled, otherwise Compiz falls
  back to a blank desktop.
- **No Unity session in the greeter?** Check that `unity-session` is installed and
  `/usr/share/xsessions/unity.desktop` exists. `./install.sh --status` shows this.
- **No password dialog for admin actions** (Nemo "Open as Root", GNOME Disks,
  mounting drives)? The Unity session needs a running polkit agent. `unity-session`
  ships the `polkit-gnome` autostart entry, so it starts at login; if you upgraded
  from an older build, run `sudo pacman -S unity-session` from this repo, or start
  `/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1` once.
- **Nyarch/CachyOS flags**: `makepkg.conf` pins generic `-march=x86-64` so packages
  built on tuned systems stay portable.
- **Package build failure**: the exact log path is printed. Most failures are a
  missing optional dependency or an upstream tarball that moved; rerun
  `./install.sh --install` after fixing, already-built packages are skipped.

## Credits

This project stands on the shoulders of:

- **[unity-arch/packages](https://github.com/unity-arch/packages)** by Charlie —
  the original and meticulously maintained Arch package set that this repository
  is derived from. Most PKGBUILDs and patches originate there.
- The **[Ubuntu Unity](https://gitlab.com/ubuntu-unity)** project and Canonical's
  Unity 7 sources.
- Arch AUR maintainers of `gtk2`, `gtk-engine-murrine` and `xcursor-dmz`, whose
  recipes are vendored under `pkgs/` so the build is self-contained.

Unity, Ambiance, Radiance, Humanity and the Ubuntu name are trademarks of
Canonical Ltd. This is an unofficial community project, not affiliated with or
endorsed by Canonical.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). Individual packages keep the licenses
declared in their own `PKGBUILD` and upstream sources.
