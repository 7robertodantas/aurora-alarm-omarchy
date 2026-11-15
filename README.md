# omarchy-on-aurora

Install [Omarchy](https://omarchy.org)'s desktop (Hyprland, its configs and `omarchy-*` tools) on an
[Aurora Silicon](https://github.com/aurora-silicon) Arch Linux ARM (ALARM) install on an Apple silicon Mac, **with
Aurora keeping the kernel, Mesa, boot chain, initramfs, disk encryption and audio stack**.

Omarchy's own Mac installer does not support M3/M4 Macs, and its installer paths for Apple silicon assume Omarchy's
own Mac boot chain. This script installs only the desktop part on top of a working Aurora system, and stops whenever
Omarchy upstream changes something it has not been checked against.

Unofficial; not affiliated with Omarchy or Aurora. Tested on a Mac Studio (2025, M4 Max, J575c), Aurora Installer
v0.1.0-alpha.21, Arch minimal, Omarchy 4.5.0 (omacom/omarchy `c0cd26e`).

## Use

On a fresh Aurora ALARM **minimal** install, logged in over SSH or on a console as your normal user:

```sh
git clone https://github.com/7robertodantas/aurora-alarm-omarchy && cd aurora-alarm-omarchy
./omarchy-on-aurora.sh check       # read-only
./omarchy-on-aurora.sh dryrun      # read-only: resolves everything against a temporary package DB
./omarchy-on-aurora.sh snapshot    # rollback points (Btrfs snapshot of /, initramfs copies, package list)
./omarchy-on-aurora.sh repo        # [omarchy] repo (last) + Omarchy's signing key
sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu   # only if the next phase says updates are pending
./omarchy-on-aurora.sh packages
./omarchy-on-aurora.sh initramfs   # must say "unchanged" before you reboot
./omarchy-on-aurora.sh system
./omarchy-on-aurora.sh user
./omarchy-on-aurora.sh verify
sudo reboot                        # SDDM login -> Hyprland
```

Options (environment): `OMARCHY_CHANNEL=edge|stable` (default `edge`, see below), `OMARCHY_REF=<omarchy git ref>`
(default `HEAD` = the default branch, `quattro` for 4.x; used for the package and step lists), `SSH_ALLOW_FROM=<cidr>` (default: the LAN of the default
route).

## What it does differently from Omarchy's installer, and why

Omarchy 4.x installs from an ISO: it installs `omarchy-pkg-defaults <platform>`, then runs `omarchy-apply-system` and
`omarchy-provision-user`. On any booted Mac its platform detector says `aarch64-apple` (as root it ignores overrides),
and those paths would break Aurora:

| Omarchy behaviour on `aarch64-apple` | Here |
|---|---|
| `post-install/pacman.sh` replaces `/etc/pacman.conf` with its Apple template: **drops `[aurora]`** | never run; `[omarchy]` added by hand |
| pkgs.omarchy.org carries its **own copies of Aurora packages** (`linux-aurora`, `mesa-aurora`, `aura`, `uboot-aurora`, `alsa-ucm-conf-aurora`, `aurora-audio`, ...; older kernel, aura, U-Boot) | `[omarchy]` is the **last** repo: pacman takes a package from the first repo that has it |
| The edge channel also overrides `alsa-ucm-conf`, `ffmpeg`, `hyprland`, `aquamarine`, `quickshell` | same: ALARM's copies win |
| `omarchy-mac-boot` (its own m1n1/U-Boot/Limine/encryption chain) and `omarchy-mac` | `IgnorePkg`; `hardware/platform-setup` skipped |
| `omarchy-settings` ships initramfs drop-ins (replaces `HOOKS`, adds `thunderbolt` early) and Limine config | `NoExtract` (never written) |
| A package adding initcpio files makes pacman run `mkinitcpio -P` | `initramfs` phase diffs every image against the snapshot |
| Firewall: deny incoming, SSH not opened | SSH allowed from the LAN before ufw is enabled |
| `hardware/vulkan` would add `vulkan-asahi` (conflicts with `vulkan-aurora`) | skipped |
| `config/snapper` sets up snapper + `limine-snapper-sync` | skipped |
| Direct `pacman -Syu` is refused by Omarchy's guard hook | `sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu`; `omarchy update` should also work (without the Mac boot package it only warns that boot files were not verified) |
| Migrations from older Omarchy versions | `omarchy-provision-user --first-install` marks all shipped ones done |

Stable vs edge: on 2026-11-15 Omarchy stable's `hyprland` 0.56.2 needed older Hypr libraries than ALARM ships, so it
did not resolve. With `[omarchy]` last, the whole Hyprland stack comes from ALARM `extra` and Omarchy supplies only
its own packages, so `edge` resolves fully (532 packages, nothing installed changes).

Also changed on purpose by `omarchy-settings`: `/etc/nsswitch.conf`, `/etc/security/faillock.conf`,
`/etc/plymouth/plymouthd.conf`, `/etc/skel/.bashrc`, `/etc/os-release` (made a symlink to `/usr/lib/os-release`),
`usbcore autosuspend=-1`, sysctl/logind/resolved/oomd drop-ins, sddm config. Services enabled: cups, avahi,
docker.socket, systemd-resolved, NetworkManager, power-profiles-daemon, sddm, systemd-oomd, ufw.

## Safety checks on every run

- `check`: aarch64, Apple device tree, `linux-aurora` + `aura` installed, `[aurora]` in pacman.conf, `[omarchy]` last.
- Packages already satisfied by an installed one (by name or provides, e.g. Aurora's `networkmanager-aurora`,
  `alsa-utils-aurora`) are never named.
- `dryrun` / `packages`: the package plan may not change any installed package, and no protected name
  (any `*-aurora`, kernel, Mesa, aura, U-Boot, UCM, speaker safety, PipeWire, NetworkManager, mkinitcpio, GRUB, Omarchy Mac packages)
  may come from a repo other than `[aurora]`.
- Every Omarchy setup step upstream must be listed in `reviewed.conf` (run or skip), or the script stops.
- Every boot/initramfs/modprobe/pacman file in the Omarchy packages to be installed must be in `NOEXTRACT` or
  `KNOWN_FILES`, or the script stops.
- `packages` refuses a partial upgrade: pending updates must be installed first.

## When upstream changes

Rerun `check` and `dryrun` first. If it stops:

- **New setup step:** read `install/<stage>/<name>.sh` in omacom/omarchy, decide, add it to `RUN_STEPS` or
  `SKIP_STEPS` (with the reason) in `reviewed.conf`.
- **New boot/initramfs file:** read it in the package; add it to `NOEXTRACT` (keep off the system) or `KNOWN_FILES`.
- **Unresolvable packages:** try the other channel, or add the package to `DROP_PACKAGES` with a note.
- **Plan changes an installed package:** usually a library update in ALARM; run a normal `pacman -Syu` first. If it is
  a protected package, find out which repo offers it and why before going further.

Update the "Reviewed against" line in `reviewed.conf` after a review.

## Rollback

- Whole system: the read-only Btrfs snapshot `/.snapshots/pre-omarchy` (boot a rescue system or restore files from it).
- Initramfs: `/boot/initramfs-*.img.pre-omarchy`.
- Config: `/etc/pacman.conf.pre-omarchy`, `~/.local/state/omarchy-on-aurora/pre-omarchy/` (package list, enabled
  units, drop-in listing).
- Back to the console login: `sudo systemctl disable sddm && sudo systemctl set-default multi-user.target`.

## Keys

`keys/omarchy.gpg` is Omarchy's package signing key, `Omarchy <pkgs@omarchy.org>`,
`40DF B630 FF42 BCFF B047 046C F013 4EE6 80CA C571`, taken from `omarchy-keyring` 20251027-1. It was checked against
the signatures of `omarchy`, `omarchy-settings` and `omarchy-keyring` on 2026-11-15. The script refuses a key file with
a different fingerprint. (`default/pacman/keys/` in the omarchy repo holds the Arch Linux ARM build key, not this one.)

## AI disclosure

Written with the help of an AI assistant (Claude Code), reviewed and run by the repository owner.
