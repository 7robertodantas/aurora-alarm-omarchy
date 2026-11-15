#!/bin/bash
# Omarchy's desktop on Aurora ALARM, with Aurora keeping the kernel, Mesa, boot
# chain, initramfs, LUKS and audio. Run on the Mac as the normal user (sudo is
# used where needed), one phase at a time:
#
#   ./omarchy-on-aurora.sh check       preconditions (read-only)
#   ./omarchy-on-aurora.sh dryrun      resolve everything against a temporary DB (read-only)
#   ./omarchy-on-aurora.sh snapshot    rollback points
#   ./omarchy-on-aurora.sh repo        add [omarchy] (last) + Omarchy key
#   ./omarchy-on-aurora.sh packages    install the desktop packages
#   ./omarchy-on-aurora.sh initramfs   compare the initramfs with the snapshot
#   ./omarchy-on-aurora.sh system      the reviewed root setup steps
#   ./omarchy-on-aurora.sh user        per-user setup
#   ./omarchy-on-aurora.sh verify      Aurora packages unchanged, services, firewall
#
# Every run re-checks Omarchy upstream: a setup step or a boot/initramfs file
# this script has not reviewed stops it (see README.md, "When upstream changes").
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/reviewed.conf"
OMARCHY_REF=${OMARCHY_REF:-HEAD}   # HEAD = default branch (quattro for 4.x)
CHANNEL=${OMARCHY_CHANNEL:-edge}
WORK=${WORK:-/tmp/omarchy-on-aurora}
STATE=${STATE:-$HOME/.local/state/omarchy-on-aurora}
OM=/usr/share/omarchy
RAW=https://raw.githubusercontent.com/omacom/omarchy/$OMARCHY_REF
KEY_FPR=40DFB630FF42BCFFB047046CF0134EE680CAC571
PROTECTED_RE='^(.*-aurora|.*-aurora-.*|linux-aurora.*|mesa-aurora|vulkan-aurora|aura|uboot-aurora|uboot-asahi|alsa-ucm-conf|alsa-ucm-conf-aurora|aurora-.*|speakersafetyd.*|speakerguardd.*|asahi-.*|pipewire|wireplumber|mkinitcpio|grub|plymouth-theme-aurora|networkmanager|linux|linux-asahi|mesa|vulkan-asahi|m1n1.*|omarchy-mac|omarchy-mac-boot|omarchy-aurora-firmware|omarchy-ane.*|limine.*)$'

say() { printf '\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\033[31mSTOP: %s\033[0m\n' "$*" >&2; exit 1; }
mkdir -p "$WORK" "$STATE"

# ---- helpers ---------------------------------------------------------------

pacman_conf_with_omarchy() { # stdout: /etc/pacman.conf with [omarchy] appended last (if missing)
  cat /etc/pacman.conf
  grep -q '^\[omarchy\]' /etc/pacman.conf ||
    printf '\n# Omarchy desktop packages: last, so it never shadows Aurora/ALARM\n[omarchy]\nServer = https://pkgs.omarchy.org/%s/$arch\n' "$CHANNEL"
}

fetch_lists() { # Omarchy's own package composition for generic aarch64 (omarchy-pkg-defaults aarch64)
  local f
  for f in omarchy-base omarchy-aarch64 omarchy-x86_64-only; do
    curl -fsSL "$RAW/install/$f.packages" -o "$WORK/$f.packages"
  done
  for f in config hardware login post-install user; do
    curl -fsSL "$RAW/install/$f/all.sh" -o "$WORK/steps-$f.sh"
  done
  names() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$@"; }
  { names "$WORK/omarchy-base.packages" "$WORK/omarchy-aarch64.packages"; printf '%s\n' $EXTRA_PACKAGES; } |
    grep -vxF -f <(names "$WORK/omarchy-x86_64-only.packages"; printf '%s\n' $DROP_PACKAGES) |
    awk '!seen[$0]++' > "$WORK/wanted.txt"
  # Never name anything an installed package already satisfies, by name or by
  # provides (Aurora ships networkmanager-aurora, alsa-utils-aurora, ...; naming
  # the plain package would replace Aurora's build). pacman -T prints the
  # unsatisfied ones.
  pacman -T $(cat "$WORK/wanted.txt") > "$WORK/targets.txt" || true
}

steps_in() { grep -oE 'OMARCHY_INSTALL/[^"]+\.sh' "$1" | sed 's#OMARCHY_INSTALL/##; s#\.sh$##'; }

check_steps() { # every upstream step must be reviewed (run or skip)
  local s new=() known
  known=" $(echo $RUN_STEPS $SKIP_STEPS $USER_STEPS) "   # unquoted echo: newlines -> spaces
  for s in $(for f in "$WORK"/steps-*.sh; do steps_in "$f"; done); do
    [[ $known == *" $s "* ]] || new+=("$s")
  done
  ((${#new[@]} == 0)) || die "Omarchy has setup steps this script has not reviewed: ${new[*]}
Read them in omacom/omarchy install/, then add each to RUN_STEPS or SKIP_STEPS in reviewed.conf."
}

temp_db() { # a throwaway sync DB; the real one and /etc/pacman.conf stay untouched
  pacman_conf_with_omarchy > "$WORK/pacman.conf"
  sudo rm -rf "$WORK/db"; mkdir -p "$WORK/db"; ln -s /var/lib/pacman/local "$WORK/db/local"
  sudo pacman --config "$WORK/pacman.conf" --dbpath "$WORK/db" -Sy >/dev/null
  P=(pacman --config "$WORK/pacman.conf" --dbpath "$WORK/db")
}

check_plan() { # $1 plan file ("repo name version" per line); $2.. pacman command (default: pacman)
  local plan=$1 r n v c bad=0; shift
  local pac=("${@:-pacman}")
  while read -r r n v; do
    if pacman -Q "$n" >/dev/null 2>&1; then echo "  changes installed: $r/$n $v (now $(pacman -Q "$n" | cut -d' ' -f2))"; bad=1; fi
    if [[ $n =~ $PROTECTED_RE && $r != aurora ]]; then echo "  protected package from $r: $n $v"; bad=1; fi
  done < "$plan"
  # pacman --print does not evaluate conflicts: check them against what is installed.
  while read -r n c; do
    [[ -n $c && $c != None ]] || continue
    # pacman -T honours version constraints (e.g. mkinitcpio<30): empty = an installed package matches
    if [[ -z $(pacman -T "$c" 2>/dev/null) ]]; then
      echo "  $n conflicts with installed $c"; bad=1
    fi
  done < <("${pac[@]}" -Si $(awk '{print $1"/"$2}' "$plan") 2>/dev/null |
           awk -F' : ' '/^Name/{n=$2} /^Conflicts With/{k=split($2,a," "); for(i=1;i<=k;i++) print n" "a[i]}')
  return $bad
}

check_payload() { # boot/initramfs files in Omarchy's packages must all be reviewed (NoExtract'ed or known harmless)
  local pkgs f new=()
  mapfile -t pkgs < <(awk '$1=="omarchy"{print $2}' "$WORK/plan.txt")
  ((${#pkgs[@]})) || return 0
  # Fetched with curl and checked with gpg against keys/omarchy.gpg, so this
  # read-only phase needs no change to pacman's keyring.
  local url gh
  mkdir -p "$WORK/pkgs"; gh=$(mktemp -d)
  gpg --homedir "$gh" --quiet --import "$HERE/keys/omarchy.gpg" 2>/dev/null
  for url in $("${P[@]}" -Sddp --print-format '%l' "${pkgs[@]}"); do   # -dd: these packages only
    f=$WORK/pkgs/${url##*/}
    [[ -s $f ]] || curl -fsSL -o "$f" "$url"
    [[ -s $f.sig ]] || curl -fsSL -o "$f.sig" "$url.sig"
    gpg --homedir "$gh" --status-fd 1 --verify "$f.sig" "$f" 2>/dev/null | grep -q "VALIDSIG $KEY_FPR" ||
      { rm -rf "$gh"; die "bad or missing Omarchy signature: ${url##*/}"; }
  done
  rm -rf "$gh"
  local known; known=" $(echo $NOEXTRACT $KNOWN_FILES) "   # unquoted echo: newlines -> spaces
  for f in "$WORK"/pkgs/*.pkg.tar.*; do
    [[ $f == *.sig ]] && continue
    { bsdtar -tf "$f" | grep -E '^(boot/|etc/mkinitcpio|etc/limine|etc/default/grub|usr/lib/initcpio/|etc/kernel/|usr/lib/kernel/|etc/modprobe\.d/|usr/lib/modprobe\.d/|etc/pacman\.conf|etc/pacman\.d/|etc/crypttab|usr/share/libalpm/hooks/)' |
      grep -v '/$' || true; } | while read -r p; do   # most packages match nothing
        [[ $known == *" $p "* ]] || echo "$(basename "$f"): $p"
      done
  done > "$WORK/new-files.txt"
  [[ ! -s $WORK/new-files.txt ]] || die "Omarchy packages ship boot/initramfs/pacman files this script has not reviewed:
$(cat "$WORK/new-files.txt")
Review them; add each to NOEXTRACT (keep it off the system) or KNOWN_FILES (harmless) in reviewed.conf."
}

lan_subnet() { local dev; dev=$(ip route show default | awk '{print $5; exit}'); ip -4 route show dev "$dev" proto kernel scope link | awk '{print $1; exit}'; }

# ---- phases ----------------------------------------------------------------

phase=${1:-}
case $phase in
check)
  [[ $(uname -m) == aarch64 ]] || die "not aarch64"
  grep -aq 'apple,' /proc/device-tree/compatible || die "not an Apple silicon device tree"
  pacman -Q linux-aurora aura >/dev/null || die "not an Aurora ALARM install (linux-aurora/aura missing)"
  grep -q '^\[aurora\]' /etc/pacman.conf || die "/etc/pacman.conf has no [aurora] repo"
  if grep -q '^\[omarchy\]' /etc/pacman.conf; then
    [[ $(grep -E '^\[' /etc/pacman.conf | tail -1) == "[omarchy]" ]] || die "[omarchy] is not the last repo in /etc/pacman.conf"
  fi
  say "OK: $(tr '\0' ' ' < /proc/device-tree/compatible), $(pacman -Q linux-aurora), repos: $(grep -E '^\[' /etc/pacman.conf | tr '\n' ' ')"
  ;;
dryrun)
  "$0" check
  fetch_lists; check_steps
  say "upstream steps all reviewed; $(wc -l < "$WORK/wanted.txt") wanted, $(wc -l < "$WORK/targets.txt") not yet satisfied"
  temp_db
  missing=(); ok=()
  for p in $(cat "$WORK/targets.txt"); do "${P[@]}" -Sp --print-format x "$p" >/dev/null 2>&1 && ok+=("$p") || missing+=("$p"); done
  ((${#missing[@]} == 0)) || { for p in "${missing[@]}"; do echo "  $p: $("${P[@]}" -Sp "$p" 2>&1 | grep -E 'unable|not found' | head -1)"; done; die "unresolvable: ${missing[*]} (try OMARCHY_CHANNEL=stable|edge, or add to DROP_PACKAGES)"; }
  "${P[@]}" -S --needed --print --print-format '%r %n %v' "${ok[@]}" > "$WORK/plan.txt"
  say "plan: $(wc -l < "$WORK/plan.txt") packages ($(awk '{print $1}' "$WORK/plan.txt" | sort | uniq -c | tr -s ' ' | tr '\n' ','))"
  check_plan "$WORK/plan.txt" "${P[@]}" || die "the plan would change installed or protected packages, or conflicts (above)"
  check_payload
  cp "$WORK/plan.txt" "$STATE/plan-$(date +%Y%m%d-%H%M%S).txt"
  say "dry run clean: nothing installed changes, no unreviewed boot/initramfs files"
  ;;
snapshot)
  B=$STATE/pre-omarchy; mkdir -p "$B"
  pacman -Q > "$B/packages.txt"; cp /etc/pacman.conf "$B/pacman.conf"
  systemctl list-unit-files --state=enabled --no-legend > "$B/enabled-units.txt"
  ls -la /etc/mkinitcpio.conf.d /etc/modprobe.d > "$B/dropins.txt" 2>&1 || true
  for img in /boot/initramfs-*.img; do
    sudo lsinitcpio "$img" | sort > "$B/$(basename "$img").contents"
    [[ -e $img.pre-omarchy ]] || sudo cp -a "$img" "$img.pre-omarchy"
  done
  # Read-only Btrfs snapshots of / and, when it is its own subvolume, /home
  # (the user phase rewrites dotfiles there).
  snaps=()
  if findmnt -no FSTYPE / | grep -qx btrfs; then
    sudo mkdir -p /.snapshots
    [[ -e /.snapshots/pre-omarchy ]] || sudo btrfs subvolume snapshot -r / /.snapshots/pre-omarchy
    snaps+=(/.snapshots/pre-omarchy)
  fi
  if [[ $(findmnt -no FSTYPE /home 2>/dev/null) == btrfs ]] && sudo btrfs subvolume show /home >/dev/null 2>&1; then
    sudo mkdir -p /home/.snapshots
    [[ -e /home/.snapshots/pre-omarchy ]] || sudo btrfs subvolume snapshot -r /home /home/.snapshots/pre-omarchy
    snaps+=(/home/.snapshots/pre-omarchy)
  fi
  say "rollback points: $B, /boot/*.pre-omarchy, ${snaps[*]:-no Btrfs snapshots}"
  ;;
repo)
  if ! grep -q '^\[omarchy\]' /etc/pacman.conf; then
    sudo cp -n /etc/pacman.conf /etc/pacman.conf.pre-omarchy
    sudo sed -i "/^\[options\]/a IgnorePkg = $(echo $IGNORE_PKGS)\nNoExtract = $(echo $NOEXTRACT)" /etc/pacman.conf
    pacman_conf_with_omarchy | tail -4 | sudo tee -a /etc/pacman.conf >/dev/null
  fi
  gpg --show-keys --with-colons "$HERE/keys/omarchy.gpg" | grep -q "^fpr:::::::::$KEY_FPR:" || die "keys/omarchy.gpg is not $KEY_FPR"
  sudo pacman-key --list-keys "$KEY_FPR" >/dev/null 2>&1 || { sudo pacman-key --add "$HERE/keys/omarchy.gpg"; sudo pacman-key --lsign-key "$KEY_FPR"; }
  sudo pacman -Sy
  "$0" check
  ;;
packages)
  "$0" check
  grep -q '^\[omarchy\]' /etc/pacman.conf || die "run the repo phase first"
  fetch_lists; check_steps
  # No partial upgrades: bring Aurora/ALARM up to date first, on its own.
  if pending=$(pacman -Qu 2>/dev/null) && [[ -n $pending ]]; then
    echo "$pending" | head -20
    die "updates pending (above). Run a normal system upgrade first (sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu), check it, then rerun"
  fi
  # the real DB is synced; re-check the plan against it before installing
  sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed --print --print-format '%r %n %v' $(cat "$WORK/targets.txt") > "$WORK/plan.txt"
  check_plan "$WORK/plan.txt" || die "the plan would change installed or protected packages (above)"
  sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed --noconfirm $(cat "$WORK/targets.txt")
  ;;
initramfs)
  B=$STATE/pre-omarchy; changed=0
  for img in /boot/initramfs-*.img; do
    [[ -e $B/$(basename "$img").contents ]] || continue
    if sudo lsinitcpio "$img" | sort | diff "$B/$(basename "$img").contents" -; then say "$img unchanged"; else changed=1; fi
  done
  ls /etc/mkinitcpio.conf.d/ /etc/limine-entry-tool.d/ 2>/dev/null || true
  ((changed == 0)) || die "an initramfs changed (diff above): check before rebooting; backups are /boot/*.pre-omarchy"
  ;;
system)
  "$0" check
  [[ -d $OM/install ]] || die "$OM/install missing: install the packages first"
  for f in config hardware login post-install user; do cp "$OM/install/$f/all.sh" "$WORK/steps-$f.sh"; done
  check_steps
  subnet=${SSH_ALLOW_FROM:-$(lan_subnet)}
  [[ -n $subnet ]] || die "cannot tell the LAN subnet; set SSH_ALLOW_FROM"
  sudo env OMARCHY_PATH=$OM OMARCHY_INSTALL=$OM/install OMARCHY_INSTALL_USER="$USER" OMARCHY_FIRST_INSTALL=1 \
    STEPS="$RUN_STEPS" SUBNET="$subnet" bash -euo pipefail -c '
    PATH=$OMARCHY_PATH/bin:$PATH
    for s in $STEPS; do
      if [[ $s == config/firewall ]]; then
        # Omarchy denies incoming by default and does not open SSH.
        ufw allow from "$SUBNET" to any port 22 proto tcp comment "ssh from LAN (omarchy-on-aurora)"
      fi
      echo "== $s"; source "$OMARCHY_INSTALL/$s.sh"
    done'
  sudo ufw status verbose | head -20
  ;;
user)
  [[ -x /usr/bin/omarchy-provision-user ]] || die "omarchy not installed"
  omarchy-reinstall-configs
  omarchy-provision-user --first-install   # also marks every shipped migration done
  ;;
verify)
  B=$STATE/pre-omarchy
  if diff <(grep -E "^(${PROTECTED_RE:2:-2}) " "$B/packages.txt") <(pacman -Q | grep -E "^(${PROTECTED_RE:2:-2}) "); then
    say "Aurora-owned packages unchanged"
  else
    echo "protected packages differ from the snapshot (above)"
  fi
  say "repos: $(grep -E '^\[' /etc/pacman.conf | tr '\n' ' ')"
  systemctl --failed --no-legend
  sudo ufw status | head -8
  ;;
*) sed -n '2,20p' "$0"; exit 2 ;;
esac
