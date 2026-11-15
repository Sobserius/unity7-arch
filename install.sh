#!/usr/bin/env bash
#
# unity7-arch — install, build and remove Unity 7 on Arch Linux.
#
# Copyright (C) 2026 Sobserius
# SPDX-License-Identifier: GPL-3.0-or-later
#
# This script is intentionally self contained: it reads the PKGBUILDs in ./pkgs,
# orders them by their real dependencies, builds them from source with makepkg and
# remembers exactly what it installed so uninstall can undo it.
#
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PKGS=$ROOT/pkgs
LOGDIR=$ROOT/logs

STATE_DIR=/var/lib/unity7-arch
MANIFEST=$STATE_DIR/packages
BACKUP=$STATE_DIR/backup

LIGHTDM_DIR=/etc/lightdm
LIGHTDM_CONF=$LIGHTDM_DIR/lightdm.conf.d/50-unity7-arch.conf
DM_LINK=/etc/systemd/system/display-manager.service

# Build the complete desktop, including the classic Ubuntu look.
TARGET_PACKAGES=(
  unity-desktop
  unity-greeter
  unity-ambiance-settings
  light-themes
  ubuntu-mono
  humanity-icon-theme
  ttf-ubuntu-font-family
  ubuntu-wallpapers
  xcursor-dmz
  gtk-engine-murrine
  lightdm
  nemo
)

ACTION=
ASSUME_YES=0
KEEP_DM=0
REBUILD=0
GREETER=
INSTALL_PACKAGES=0
declare -a FILTER=()

if [[ -t 1 ]]; then
  B=$'\033[1m' R=$'\033[31m' G=$'\033[32m' Y=$'\033[33m' C=$'\033[36m' N=$'\033[0m'
else
  B= R= G= Y= C= N=
fi

msg()  { printf '%s==>%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s==>%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s==>%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
${B}unity7-arch${N} — Unity 7 for Arch Linux, built from source

Usage: ./install.sh [action] [options] [package...]

Actions (pick one; without one an interactive menu is shown):
  -i, --install        build and install Unity 7
  -u, --uninstall      remove everything this script installed
  -b, --build          build packages, do not configure the desktop
  -g, --greeter        choose / change the LightDM greeter
  -s, --status         print installation status
  -h, --help           this text

Options:
  -y, --yes            assume yes, never prompt
      --keep-dm        install without switching the display manager
      --greeter NAME   greeter to use (default: unity-greeter)
      --rebuild        rebuild packages even if they are already installed
      --list           list packages in dependency build order

Examples:
  ./install.sh                       # interactive menu
  ./install.sh --install             # full install
  ./install.sh --install --keep-dm   # keep GDM/SDDM, only add the Unity session
  ./install.sh --build nux unity     # build just these packages
  ./install.sh --greeter lightdm-gtk-greeter
EOF
}

cleanup() {
  if [[ -n ${TMP:-} && -d ${TMP:-} ]]; then
    rm -rf -- "$TMP"
  fi
  return 0
}
trap cleanup EXIT

require_user() {
  (( EUID != 0 )) || die "Run this as your normal user, not as root (makepkg refuses to run as root)."
}

require_arch() {
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == arch || ${ID_LIKE:-} == *arch* ]] ||
    die "this script targets Arch Linux (detected: ${PRETTY_NAME:-unknown})."
}

have() { command -v "$1" >/dev/null 2>&1; }

require_sudo() {
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  msg "sudo is needed to install packages and write /etc"
  if [[ -n ${SUDO_ASKPASS:-} ]]; then
    sudo -A -v || die "sudo authentication failed"
  else
    sudo -v || die "sudo authentication failed"
  fi
}

require_tools() {
  local missing=() t
  for t in git makepkg pacman sudo tsort; do
    have "$t" || missing+=("$t")
  done
  if ((${#missing[@]})); then
    die "missing tools: ${missing[*]} — install base-devel and git first (sudo pacman -S --needed base-devel git)"
  fi
  pacman -Q base-devel >/dev/null 2>&1 ||
    warn "the base-devel group is not installed; makepkg may fail (sudo pacman -S --needed base-devel)"
}

check_network() {
  if have curl; then
    curl -fsS --max-time 15 -o /dev/null https://aur.archlinux.org/ ||
      warn "cannot reach aur.archlinux.org; git and launchpad sources may still work"
  fi
}

# ---------------------------------------------------------------- package graph

declare -a DIRS=()
declare -A PKG_NAMES=() PKG_DEPS=() PROVIDES=()

discover_packages() {
  local dir line info names deps name
  DIRS=()
  PKG_NAMES=()
  PKG_DEPS=()
  PROVIDES=()

  for dir in "$PKGS"/*/; do
    dir=${dir%/}
    dir=${dir##*/}
    [[ -f $PKGS/$dir/PKGBUILD ]] || continue
    DIRS+=("$dir")

    info=$( cd "$PKGS/$dir" && makepkg --printsrcinfo 2>/dev/null ) ||
      die "cannot parse $dir/PKGBUILD"

    names= deps=
    while IFS= read -r line; do
      # srcinfo indents every field with a tab
      line=${line#"${line%%[![:space:]]*}"}
      case $line in
        'pkgname = '*)                    names+=" ${line#pkgname = }" ;;
        'depends = '*|'depends_x86_64 = '*) deps+=" ${line#* = }" ;;
        'makedepends = '*|'makedepends_x86_64 = '*) deps+=" ${line#* = }" ;;
      esac
    done <<<"$info"

    PKG_NAMES[$dir]=$names
    PKG_DEPS[$dir]=$deps
    for name in $names; do
      PROVIDES[$name]=$dir
    done
  done

  ((${#DIRS[@]})) || die "no packages found under $PKGS"
}

build_order() {
  local d dep dir edges=""
  for d in "${DIRS[@]}"; do
    edges+="__root__ $d"$'\n'
    for dep in ${PKG_DEPS[$d]}; do
      dep=${dep%%[<>=]*}
      [[ -n ${PROVIDES[$dep]:-} ]] || continue
      dir=${PROVIDES[$dep]}
      [[ $dir == "$d" ]] && continue
      edges+="$dir $d"$'\n'
    done
  done

  local order
  if ! order=$(printf '%s' "$edges" | tsort); then
    die "dependency cycle in pkgs/ — run ./install.sh --list to inspect"
  fi
  printf '%s\n' "$order" | grep -vx '__root__' || true
}

filter_order() {
  local order=$1 f keep
  ((${#FILTER[@]})) || { printf '%s\n' "$order"; return; }
  printf '%s\n' "$order" | while IFS= read -r f; do
    for keep in "${FILTER[@]}"; do
      [[ $f == "$keep" ]] && { printf '%s\n' "$f"; break; }
    done
  done
}

pkg_installed() { pacman -Q "$1" >/dev/null 2>&1; }

dir_installed() {
  local n
  for n in ${PKG_NAMES[$1]}; do
    pkg_installed "$n" || return 1
  done
}

record_manifest() {
  local dir=$1 n
  (( INSTALL_PACKAGES )) || return 0
  sudo install -d -m 755 "$STATE_DIR"
  for n in ${PKG_NAMES[$dir]}; do
    if ! sudo test -f "$MANIFEST" || ! sudo grep -qxF "$n" "$MANIFEST"; then
      printf '%s\n' "$n" | sudo tee -a "$MANIFEST" >/dev/null
    fi
  done
}

# -------------------------------------------------------------------- building

build_packages() {
  local order dir log force=()
  discover_packages
  order=$(build_order)

  if ((${#FILTER[@]})); then
    local f ok
    for f in "${FILTER[@]}"; do
      ok=0
      for dir in "${DIRS[@]}"; do [[ $f == "$dir" ]] && ok=1; done
      (( ok )) || die "unknown package: $f"
    done
    order=$(filter_order "$order")
  fi

  mkdir -p "$ROOT/repo" "$LOGDIR"
  (( REBUILD )) && force=(--force)

  local built=0 skipped=0
  while IFS= read -r dir; do
    [[ -n $dir ]] || continue
    if (( ! REBUILD )) && dir_installed "$dir"; then
      msg "skip  $dir (already installed)"
      record_manifest "$dir"
      skipped=$((skipped + 1))
      continue
    fi

    log=$LOGDIR/$dir-$(date +%Y%m%d-%H%M%S).log
    msg "build $dir"
    if ! ( cd "$PKGS/$dir" &&
           makepkg --config "$ROOT/makepkg.conf" --noprogressbar -si --noconfirm "${force[@]}" ) \
           2>&1 | tee "$log"; then
      printf '\n' >&2
      warn "build failed: $dir"
      warn "log: $log"
      die "fix the error above or run: (cd pkgs/$dir && makepkg -si)"
    fi
    record_manifest "$dir"
    built=$((built + 1))
  done <<<"$order"

  msg "done: $built built, $skipped skipped"
}

# ------------------------------------------------------------------- desktop

setup_state() {
  sudo install -d -m 755 "$STATE_DIR" "$BACKUP"

  if [[ -e $DM_LINK ]] && ! sudo test -e "$BACKUP/display-manager.service.target"; then
    readlink "$DM_LINK" | sudo tee "$BACKUP/display-manager.service.target" >/dev/null
  fi

  if [[ -f $LIGHTDM_DIR/lightdm.conf ]] && ! sudo test -e "$BACKUP/lightdm.conf"; then
    sudo cp -a "$LIGHTDM_DIR/lightdm.conf" "$BACKUP/lightdm.conf"
  fi

  if [[ -d $LIGHTDM_DIR/lightdm.conf.d ]] && ! sudo test -e "$BACKUP/lightdm.conf.d"; then
    sudo cp -a "$LIGHTDM_DIR/lightdm.conf.d" "$BACKUP/lightdm.conf.d"
  fi
}

install_lightdm() {
  if ! pkg_installed lightdm; then
    msg "installing lightdm"
    sudo pacman -S --needed --noconfirm --asdeps lightdm
  fi
}

# Greeters this script can provide. unity-greeter is built from this repo; the
# others live in [extra] and are offered when they are not installed yet.
GREETER_CANDIDATES=(unity-greeter lightdm-gtk-greeter lightdm-slick-greeter lightdm-webkit2-greeter)

greeter_installed() {
  [[ -f /usr/share/xgreeters/$1.desktop ]]
}

greeter_desc() {
  local f=/usr/share/xgreeters/$1.desktop
  if [[ -f $f ]]; then
    sed -n 's/^Name=//p' "$f" | head -n1
    return
  fi
  case $1 in
    unity-greeter)           printf 'Unity Greeter' ;;
    lightdm-gtk-greeter)     printf 'LightDM GTK+ Greeter' ;;
    lightdm-slick-greeter)   printf 'LightDM Slick Greeter' ;;
    lightdm-webkit2-greeter) printf 'LightDM WebKit2 Greeter' ;;
    *)                       printf '%s' "$1" ;;
  esac
}

list_greeters() {
  local f name desc
  for f in /usr/share/xgreeters/*.desktop; do
    [[ -f $f ]] || continue
    name=$(basename "$f" .desktop)
    desc=$(sed -n 's/^Name=//p' "$f" | head -n1)
    printf '%s\t%s\n' "$name" "${desc:-$name}"
  done | sort
}

# installed greeters first, then the official ones we can install on demand
list_greeter_choices() {
  local name
  list_greeters
  for name in "${GREETER_CANDIDATES[@]}"; do
    greeter_installed "$name" && continue
    printf '%s\t%s (not installed)\n' "$name" "$(greeter_desc "$name")"
  done
}

install_greeter() {
  local g=$1
  greeter_installed "$g" && return 0
  case $g in
    unity-greeter)
      # built by this repo, so a missing one means the install is incomplete
      die "unity-greeter is not installed; run ./install.sh --install first"
      ;;
    lightdm-gtk-greeter|lightdm-slick-greeter|lightdm-webkit2-greeter)
      msg "installing $g"
      sudo pacman -S --needed --noconfirm "$g"
      ;;
    *)
      die "unknown greeter: $g"
      ;;
  esac
}

pick_greeter() {
  local choice default_idx=1 idx name desc
  local -a names=() descs=()

  while IFS=$'\t' read -r name desc; do
    [[ -n $name ]] || continue
    names+=("$name")
    descs+=("${desc:-$name}")
  done < <(list_greeter_choices)

  if ((${#names[@]} == 0)); then
    warn "no greeter found in /usr/share/xgreeters"
    printf 'unity-greeter\n'
    return
  fi

  {
    printf '%sAvailable greeters:%s\n' "$B" "$N"
    for idx in "${!names[@]}"; do
      [[ ${names[$idx]} == unity-greeter ]] && default_idx=$((idx + 1))
      printf '  %2d) %-28s %s\n' "$((idx + 1))" "${names[$idx]}" "${descs[$idx]}"
    done
  } >&2

  if (( ASSUME_YES )); then
    printf '%s\n' "${names[$((default_idx - 1))]}"
    return
  fi

  read -rp "Greeter [$default_idx]: " choice
  [[ -z $choice ]] && choice=$default_idx
  [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )) ||
    die "invalid selection: $choice"
  printf '%s\n' "${names[$((choice - 1))]}"
}

configure_greeter() {
  local g=$1 tmp
  install_greeter "$g"
  if ! pkg_installed unity-session; then
    warn "unity-session is not installed; the Unity session will not appear"
  fi

  sudo install -d -m 755 "$LIGHTDM_DIR/lightdm.conf.d"
  tmp=$(mktemp)
  cat >"$tmp" <<EOF
# Managed by unity7-arch. Remove with ./install.sh --uninstall.
[Seat:*]
greeter-session=$g
user-session=unity
EOF
  sudo install -m 644 "$tmp" "$LIGHTDM_CONF"
  rm -f "$tmp"
  msg "greeter set to $g ($LIGHTDM_CONF)"
}

current_dm() {
  local target
  target=$(readlink -f "$DM_LINK" 2>/dev/null || true)
  [[ -n $target ]] && basename "$target"
}

switch_display_manager() {
  local cur old
  cur=$(current_dm || true)

  if (( KEEP_DM )); then
    warn "keeping the current display manager (${cur:-none}); Unity will still be selectable as a session"
    return 0
  fi

  if [[ $cur == lightdm.service ]]; then
    msg "LightDM is already the display manager"
    return 0
  fi

  if ! confirm "Enable LightDM as the display manager (currently: ${cur:-none})?"; then
    warn "display manager left unchanged; unity-greeter will not be shown at boot"
    return 0
  fi

  setup_state
  if [[ -n $cur && $cur != lightdm.service ]]; then
    sudo systemctl disable "$cur" >/dev/null 2>&1 || true
  fi
  sudo systemctl enable lightdm.service
  msg "LightDM enabled; the change takes effect on the next reboot"
}

apply_theme_defaults() {
  msg "compiling schemas and caches"
  sudo glib-compile-schemas /usr/share/glib-2.0/schemas || warn "glib-compile-schemas failed"
  local icons=(Humanity Humanity-Dark ubuntu-mono-dark ubuntu-mono-light hicolor)
  local i
  for i in "${icons[@]}"; do
    [[ -f /usr/share/icons/$i/index.theme ]] || continue
    sudo gtk-update-icon-cache -f -t "/usr/share/icons/$i" >/dev/null 2>&1 || true
  done
  have fc-cache && sudo fc-cache -f >/dev/null 2>&1 || true
  have update-desktop-database && sudo update-desktop-database >/dev/null 2>&1 || true
}

verify_install() {
  local bad=0 b
  msg "verifying"
  for b in unity compiz unity-greeter unity-settings-daemon unity-control-center; do
    if have "$b"; then
      printf '  ok   %s\n' "$b"
    else
      printf '  %sMISS%s %s\n' "$R" "$N" "$b"; bad=1
    fi
  done
  local paths=(
    /usr/share/xsessions/unity.desktop
    /usr/share/themes/Ambiance
    /usr/share/themes/Radiance
    /usr/share/icons/Humanity
    /usr/share/icons/ubuntu-mono-dark
    /usr/share/backgrounds/warty-final-ubuntu.png
    "$LIGHTDM_CONF"
  )
  local p
  for p in "${paths[@]}"; do
    if [[ -e $p ]]; then
      printf '  ok   %s\n' "$p"
    else
      printf '  %sMISS%s %s\n' "$R" "$N" "$p"; bad=1
    fi
  done
  if have fc-match && fc-match -f '%{family}\n' Ubuntu | grep -q Ubuntu; then
    printf '  ok   Ubuntu font\n'
  else
    printf '  %swarn%s Ubuntu font not resolved by fontconfig\n' "$Y" "$N"
  fi
  (( bad == 0 )) || warn "some components are missing — check logs/ and rerun ./install.sh --install"
}

summary() {
  local cur
  cur=$(current_dm || true)
  cat <<EOF

${B}Unity 7 is installed.${N}

  Session:   Unity (X11) — select it at the login screen
  Greeter:   $(grep -s '^greeter-session=' "$LIGHTDM_CONF" 2>/dev/null | cut -d= -f2 || echo 'not configured')
  Display:   ${cur:-none}
  Logs:      $LOGDIR
  Manifest:  $MANIFEST

${B}Next:${N}
  1. Reboot (or log out) and pick ${C}Unity${N} in the session menu.
  2. If LightDM was enabled, the unity-greeter is what you will see.

${B}If the graphical login breaks${N}, switch to a TTY (Ctrl+Alt+F3) and run:
  sudo systemctl disable lightdm
  sudo systemctl enable gdm        # or sddm, whichever you used before
  sudo reboot

Uninstall everything with: ${C}./install.sh --uninstall${N}
EOF
}

do_install() {
  require_user
  require_arch
  require_tools
  require_sudo
  check_network
  discover_packages

  local order count
  order=$(build_order)
  count=$(printf '%s\n' "$order" | grep -c . || true)

  cat <<EOF
${B}Unity 7 for Arch Linux${N}

  packages : $count (built from source, dependency ordered)
  desktop  : Unity 7.7 + Compiz + Nux + indicators
  look     : Ambiance/Radiance, Humanity icons, DMZ-White cursors,
             Ubuntu font, warty wallpaper, original unity-greeter
  install  : ${TARGET_PACKAGES[*]}
  disk     : ~8-12 GB while building
  time     : roughly 1-3 hours on a modern machine

EOF

  confirm "Continue?" || die "cancelled"

  INSTALL_PACKAGES=1
  setup_state
  build_packages

  msg "installing desktop meta packages"
  local p missing_targets=()
  for p in "${TARGET_PACKAGES[@]}"; do
    pkg_installed "$p" || missing_targets+=("$p")
  done
  if ((${#missing_targets[@]})); then
    sudo pacman -S --needed --noconfirm "${missing_targets[@]}"
  fi

  apply_theme_defaults

  local greeter=${GREETER:-}
  [[ -n $greeter ]] || greeter=$(pick_greeter)
  configure_greeter "$greeter"
  switch_display_manager
  verify_install
  summary
}

# ------------------------------------------------------------------ uninstall

do_uninstall() {
  require_user
  require_arch
  require_tools
  require_sudo

  if ! sudo test -f "$MANIFEST"; then
    warn "no manifest at $MANIFEST — nothing recorded by this script"
    [[ -f $LIGHTDM_CONF ]] || die "nothing to uninstall"
  fi

  local -a installed=() keep=()
  local p
  if sudo test -f "$MANIFEST"; then
    while IFS= read -r p; do
      [[ -n $p ]] || continue
      if pkg_installed "$p"; then installed+=("$p"); fi
    done < <(sudo cat "$MANIFEST")
  fi

  if ((${#installed[@]})); then
    printf '%sPackages to remove:%s\n' "$B" "$N"
    printf '  %s\n' "${installed[*]}"
    printf '\n'
  fi

  confirm "Uninstall Unity 7 and restore the previous display manager?" ||
    die "cancelled"

  if ((${#installed[@]})); then
    # reverse install order so dependents go first; one transaction lets pacman
    # resolve the dependencies between them
    mapfile -t installed < <(printf '%s\n' "${installed[@]}" | tac)
    msg "removing ${#installed[@]} packages"
    if ! sudo pacman -R --noconfirm "${installed[@]}"; then
      warn "pacman refused; retry with: sudo pacman -R ${installed[*]}"
    fi
  fi

  msg "restoring lightdm configuration"
  sudo rm -f "$LIGHTDM_CONF"
  if sudo test -f "$BACKUP/lightdm.conf"; then
    sudo cp -a "$BACKUP/lightdm.conf" "$LIGHTDM_DIR/lightdm.conf"
  fi
  if sudo test -d "$BACKUP/lightdm.conf.d"; then
    sudo install -d -m 755 "$LIGHTDM_DIR/lightdm.conf.d"
    sudo cp -a "$BACKUP/lightdm.conf.d/." "$LIGHTDM_DIR/lightdm.conf.d/"
  fi

  msg "restoring display manager"
  sudo systemctl disable lightdm.service >/dev/null 2>&1 || true
  if sudo test -f "$BACKUP/display-manager.service.target"; then
    local target unit
    target=$(sudo cat "$BACKUP/display-manager.service.target")
    if [[ -n $target ]]; then
      sudo ln -sfn "$target" "$DM_LINK"
      unit=$(basename "$target")
      [[ $unit != display-manager.service ]] &&
        sudo systemctl enable "$unit" >/dev/null 2>&1 || true
      msg "display manager restored: $unit"
    else
      sudo rm -f "$DM_LINK"
    fi
  else
    sudo rm -f "$DM_LINK"
    warn "no previous display manager recorded; enable yours manually (systemctl enable gdm)"
  fi

  msg "removing state"
  sudo rm -rf "$STATE_DIR"

  cat <<EOF

${B}Unity 7 has been removed.${N}
Your user configuration in ~/.config, ~/.local and ~/.cache was left alone.
Official dependencies that were pulled in (gtk3, lightdm, xorg-server, ...) were
not removed. If you want them gone: ${C}sudo pacman -Qtdq${N} then remove what you recognise.

Reboot to get back to your previous desktop.
EOF
}

# --------------------------------------------------------------------- status

do_status() {
  require_arch
  local cur
  cur=$(current_dm || true)

  printf '%sSystem%s\n' "$B" "$N"
  printf '  distro      : %s\n' "$(. /etc/os-release; echo "${PRETTY_NAME:-Arch}")"
  printf '  kernel      : %s\n' "$(uname -r)"
  printf '  session     : %s / %s\n' "${XDG_SESSION_TYPE:-?}" "${XDG_CURRENT_DESKTOP:-?}"
  printf '  display mgr : %s\n' "${cur:-none}"

  printf '\n%sPackages%s\n' "$B" "$N"
  local p
  for p in "${TARGET_PACKAGES[@]}"; do
    if pkg_installed "$p"; then
      printf '  %sok%s   %s\n' "$G" "$N" "$p"
    else
      printf '  %s--%s   %s\n' "$Y" "$N" "$p"
    fi
  done

  printf '\n%sFiles%s\n' "$B" "$N"
  local f
  for f in /usr/share/xsessions/unity.desktop \
           /usr/share/themes/Ambiance /usr/share/icons/Humanity \
           /usr/share/backgrounds/warty-final-ubuntu.png \
           /usr/share/xgreeters/unity-greeter.desktop; do
    [[ -e $f ]] && printf '  %sok%s   %s\n' "$G" "$N" "$f" ||
      printf '  %s--%s   %s\n' "$Y" "$N" "$f"
  done

  printf '\n%sGreeters%s\n' "$B" "$N"
  list_greeters | sed 's/^/  /'

  printf '\n%sLightDM%s\n' "$B" "$N"
  if [[ -f $LIGHTDM_CONF ]]; then
    printf '  config      : %s\n' "$LIGHTDM_CONF"
    grep -E '^(greeter-session|user-session)=' "$LIGHTDM_CONF" | sed 's/^/  /'
  else
    printf '  config      : not configured\n'
  fi

  if sudo -n true 2>/dev/null && sudo test -f "$MANIFEST"; then
    printf '\n%sManifest%s (%s packages)\n' "$B" "$N" "$(sudo wc -l <"$MANIFEST")"
  fi
}

do_greeter() {
  require_user
  require_arch
  require_tools
  require_sudo
  pkg_installed lightdm || die "LightDM is not installed; run ./install.sh --install first"

  local greeter=${GREETER:-}
  [[ -n $greeter ]] || greeter=$(pick_greeter)
  setup_state
  configure_greeter "$greeter"
  switch_display_manager
  msg "done"
}

# ----------------------------------------------------------------------- menu

confirm() {
  (( ASSUME_YES )) && return 0
  local answer
  read -rp "$1 [y/N] " answer
  [[ $answer =~ ^[Yy]$ ]]
}

show_menu() {
  cat <<EOF
${B}Unity 7 for Arch Linux${N}

  1) Install Unity 7 (build from source)
  2) Uninstall Unity 7
  3) Build packages only
  4) Choose / change the login greeter
  5) Show status
  q) Quit
EOF
}

menu() {
  local choice
  show_menu
  read -rp $'\nChoose [1-5, q]: ' choice
  case $choice in
    1) ACTION=install ;;
    2) ACTION=uninstall ;;
    3) ACTION=build ;;
    4) ACTION=greeter ;;
    5) ACTION=status ;;
    q|Q) exit 0 ;;
    *) die "invalid choice: $choice" ;;
  esac
}

# ----------------------------------------------------------------------- main

while (($#)); do
  case $1 in
    -i|--install)   ACTION=install ;;
    -u|--uninstall) ACTION=uninstall ;;
    -b|--build)     ACTION=build ;;
    -s|--status)    ACTION=status ;;
    -y|--yes)       ASSUME_YES=1 ;;
    --keep-dm)      KEEP_DM=1 ;;
    --rebuild)      REBUILD=1 ;;
    --greeter=*)    GREETER=${1#*=}; [[ -n $ACTION ]] || ACTION=greeter ;;
    --greeter)
      shift
      [[ $# -gt 0 ]] || die "--greeter needs a value"
      GREETER=$1
      [[ -n $ACTION ]] || ACTION=greeter
      ;;
    -g)             [[ -n $ACTION ]] || ACTION=greeter ;;
    --list)
      discover_packages
      build_order
      exit 0
      ;;
    -h|--help) usage; exit 0 ;;
    --) shift; FILTER+=("$@"); break ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) FILTER+=("$1") ;;
  esac
  shift
done

if [[ -z $ACTION && -n $GREETER ]]; then
  ACTION=greeter
fi

if [[ -z $ACTION ]]; then
  [[ -t 0 ]] || die "no action given and stdin is not a terminal (try --install --yes)"
  menu
fi

case $ACTION in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  build)     require_user; require_arch; require_tools; require_sudo
             INSTALL_PACKAGES=0; build_packages ;;
  greeter)   do_greeter ;;
  status)    do_status ;;
  *)         die "unknown action: $ACTION" ;;
esac
