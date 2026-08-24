#!/usr/bin/env fish

# ===========================================
# Btrfs + Snapper + GRUB-Btrfs Setup Script
# Arch Linux / Fish shell
# ===========================================

function die
    echo " Error: $argv"
    exit 1
end

function run_step
    echo ""
    echo "==> $argv"
end

# Refuse to continue if a command is missing. This prevents a partial install
# caused by an incomplete/non-Arch environment.
function require_command
    for cmd in $argv
        if not command -q $cmd
            die "Required command '$cmd' was not found. Install the required package/tool and run the installer again."
        end
    end
end

# Return the Btrfs subvolume UUID for an exact identity check. This is used
# before any reset rollback/deletion so a path cannot be mistaken for a tree
# created or moved by this run.
function get_subvol_uuid
    set -l subvol_path $argv[1]
    btrfs subvolume show "$subvol_path" 2>/dev/null | awk '/^[[:space:]]*UUID:/ {print $2; exit}'
end

# 1. Check root privileges
if test (id -u) -ne 0
    die "Please run this script with sudo."
end

# These tools are required before pacman can install anything else.
require_command id findmnt blkid btrfs mount umount mountpoint grep sed awk sort systemctl find head date pacman cat getent cut logname dirname mktemp mkdir rm cp rmdir mv

# The installer must always be run from the normal/current system.
# In a GRUB-Btrfs snapshot boot, / is OverlayFS rather than the real Btrfs root.
if string match -q '*snapper_snapshot_boot=1*' -- (cat /proc/cmdline)
    die "Do not run the installer from a snapshot boot. Reboot into the normal/current system first."
end

# 1b. Verify that /boot is actually available before touching initramfs/GRUB.
# If /boot is a separate filesystem and is accidentally not mounted, mkinitcpio
# and grub-mkconfig can write into the underlying empty directory and leave the
# real boot filesystem unchanged. That is a particularly dangerous partial setup.
if not test -d /boot
    die "The /boot directory does not exist. Refusing to modify boot files."
end

set BOOT_FSTAB_LINES (grep -E '^[[:space:]]*[^#][^[:space:]]+[[:space:]]+/boot[[:space:]]' /etc/fstab)
if test (count $BOOT_FSTAB_LINES) -gt 1
    die "Multiple active /boot entries exist in /etc/fstab. Refusing to choose one automatically."
end
if test (count $BOOT_FSTAB_LINES) -eq 1; and not mountpoint -q /boot
    die "A separate /boot entry exists in /etc/fstab, but /boot is not mounted. Mount /boot and run the installer again."
end
if not test -d /boot/grub
    die "The /boot/grub directory is missing. Refusing to run grub-mkconfig until the installed GRUB layout is available."
end

# 2. Detect root Btrfs device and UUID
set ROOT_DEV (findmnt -no SOURCE / | head -n1)
# findmnt may append the Btrfs subvolume in brackets (for example /dev/nvme0n1p2[/@]).
# Strip only that presentation suffix before blkid/mount/block-device checks.
set ROOT_DEV (string replace -r '\\[.*\\]$' '' -- "$ROOT_DEV")
set ROOT_FSTYPE (findmnt -no FSTYPE /)

if test "$ROOT_FSTYPE" != btrfs
    die "The root filesystem is not Btrfs. This script requires a normal Btrfs root."
end

set ROOT_OPTIONS (findmnt -no OPTIONS /)
set ROOT_SUBVOL (string match -r '(^|,)subvol=([^,]+)' -- "$ROOT_OPTIONS")
if string match -qr '(^|,)subvol=/@snapshots($|/)' -- "$ROOT_OPTIONS"
    die "The current / appears to be a Snapper snapshot subvolume. Boot the normal installed system before running the installer."
end
if test -z "$ROOT_SUBVOL"
    # subvolid=5 is the top-level filesystem and is not the normal system root.
    set ROOT_SUBVOL_ID (findmnt -no OPTIONS / | string match -r '(^|,)subvolid=([^,]+)')
    if string match -qr '(^|,)subvolid=5($|,)' -- "$ROOT_SUBVOL_ID"
        die "The current / is the Btrfs top-level subvolume, not the installed system root. Boot the normal installed system first."
    end
end

set ROOT_UUID (blkid -s UUID -o value $ROOT_DEV 2>/dev/null)

if test -z "$ROOT_DEV"; or test -z "$ROOT_UUID"
    die "Could not detect the root Btrfs partition or UUID."
end
if not test -b "$ROOT_DEV"
    die "The detected root source '$ROOT_DEV' is not a block device. Refusing to modify Btrfs storage."
end

echo " Detected Root Partition: $ROOT_DEV (UUID: $ROOT_UUID)"

# Use a private runtime mountpoint so a stale mount from an interrupted run
# cannot be mistaken for this installer's temporary Btrfs mount.
set RUN_ID (string join '-' (date +%Y%m%d-%H%M%S) $fish_pid)
set BTRFS_MOUNT "/run/snapper-setup-$fish_pid"
mkdir -p "$BTRFS_MOUNT"; or die "Could not create the private Btrfs mountpoint."
if mountpoint -q "$BTRFS_MOUNT"
    die "The private installer mountpoint is already mounted. Refusing to continue."
end

# Prevent two installer instances from modifying Btrfs/systemd/GRUB at the same time.
# mkdir is atomic, unlike a separate "test then create" sequence.
set LOCK_DIR "/run/snapper-setup.lock"
if not mkdir "$LOCK_DIR" 2>/dev/null
    die "Another Snapper-Setup installer appears to be running (lock: $LOCK_DIR). Refusing to continue."
end
printf '%s\n' "$fish_pid" > "$LOCK_DIR/pid"; or begin
    rmdir "$LOCK_DIR" 2>/dev/null
    die "Could not create installer lock."
end
function remove_installer_lock --on-event fish_exit
    if test -f "$LOCK_DIR/pid"
        set LOCK_PID (cat "$LOCK_DIR/pid" 2>/dev/null)
        if test "$LOCK_PID" = "$fish_pid"
            rm -f "$LOCK_DIR/pid"
            rmdir "$LOCK_DIR" 2>/dev/null
        end
    end
end

# 3. Installation mode
# 1 = preserve existing snapshots/configuration
# 2 = destructive reset of snapshot storage so numbering can start again
while true
    echo ""
    echo "=============================================="
    echo " Snapper installation mode"
    echo "=============================================="
    echo "  1) Safe install / preserve existing snapshots"
    echo "     - Keeps existing snapshots and configuration"
    echo "     - Installs the OverlayFS boot/remount fix"
    echo "     - Recommended for an already working system"
    echo ""
    echo "  2) Reset snapshot storage / restart numbering"
    echo "     - DELETES ALL Snapper snapshots"
    echo "     - Recreates @snapshots and the Snapper config"
    echo "     - Intended to start snapshot numbering from #1"
    echo "     - MUST be run from a normal boot"
    echo "=============================================="
    read -P " Select 1 or 2: " INSTALL_MODE

    if test "$INSTALL_MODE" = 1; or test "$INSTALL_MODE" = 2
        break
    end
    echo " Invalid choice. Please enter 1 or 2."
end

if test "$INSTALL_MODE" = 2
    echo ""
    echo " WARNING: Reset mode will permanently delete ALL Snapper snapshots."
    echo " This includes manual, timeline, pre and post snapshots."
    read -P " Type RESET to continue: " RESET_CONFIRM
    if test "$RESET_CONFIRM" != RESET
        echo " Reset cancelled. No snapshots were deleted."
        exit 0
    end
end

# 4. Install required packages
# Keep per-run backups of the small text configuration files this installer may edit.
# A unique backup is used for every run so recovery never depends on a stale backup from an older installation.
set FSTAB_BACKUP "/etc/fstab.snapper-setup-$RUN_ID.backup"
set MKINITCPIO_BACKUP "/etc/mkinitcpio.conf.snapper-setup-$RUN_ID.backup"
set GRUB_BTRFS_CONFIG "/etc/default/grub-btrfs/config"
set GRUB_BTRFS_BACKUP "/etc/default/grub-btrfs/config.snapper-setup-$RUN_ID.backup"
set SNAPPER_CONFIG "/etc/snapper/configs/root"
set SNAPPER_CONFIG_BACKUP "/etc/snapper/configs/root.snapper-setup-reset-$RUN_ID.backup"
set SNAP_CONF "/etc/conf.d/snapper"
set SNAP_SYS "/etc/sysconfig/snapper"
set SNAP_CONF_BACKUP "/etc/conf.d/snapper.snapper-setup-$RUN_ID.backup"
set SNAP_SYS_BACKUP "/etc/sysconfig/snapper.snapper-setup-$RUN_ID.backup"
set REMOUNT_DROPIN "/etc/systemd/system/systemd-remount-fs.service.d/snapshot-overlay.conf"
set REMOUNT_DROPIN_BACKUP "/etc/systemd/system/systemd-remount-fs.service.d/snapshot-overlay.conf.snapper-setup-$RUN_ID.backup"
set GRUB_BTRFSD_OVERRIDE "/etc/systemd/system/grub-btrfsd.service.d/override.conf"
set GRUB_BTRFSD_OVERRIDE_BACKUP "/etc/systemd/system/grub-btrfsd.service.d/override.conf.snapper-setup-$RUN_ID.backup"
set RESET_BACKUP_SUBVOL ""
set RESTART_TIMELINE_TIMER 0
set RESTART_CLEANUP_TIMER 0
set RESET_COMMITTED 0
set RESET_CLEANUP_STARTED 0
set RESET_OPERATION_STARTED 0
set RESET_CONFIG_CHANGES_STARTED 0
set RESET_STORAGE_MOVED 0
set RESET_NEW_TREE_CREATED 0
set RESET_OLD_TREE_UUID ""
set RESET_NEW_TREE_UUID ""
# Set to 1 only after the old snapshot tree has actually been restored.
# This prevents rollback from silently restoring configuration files while
# leaving /.snapshots pointed at a newly-created replacement tree.
set RESET_STORAGE_ROLLBACK_OK 0
set SNAPSHOTS_WAS_MOUNTED 0
set PRE_RESET_SNAPSHOTS_MOUNTED 0
set PRE_RESET_SNAPSHOTS_UUID ""
set PRE_INSTALL_SNAPSHOTS_MOUNTED 0
set WAS_GRUB_BTRFSD_ACTIVE 0
set WAS_GRUB_BTRFSD_ENABLED 0
set ARCH_FUNC_INSTALLED 0
set ARCH_FUNC_BACKUP_CREATED 0
set ARCH_FUNC_FILE ""
set ARCH_FUNC_BACKUP ""
set INSTALL_COMMITTED 0
set WAS_TIMELINE_ACTIVE 0
set WAS_CLEANUP_ACTIVE 0

set CREATED_CONFIG 0

if not test -f $FSTAB_BACKUP
    cp -a /etc/fstab $FSTAB_BACKUP; or die "Could not create /etc/fstab backup."
end
if not test -f $MKINITCPIO_BACKUP
    cp -a /etc/mkinitcpio.conf $MKINITCPIO_BACKUP; or die "Could not create /etc/mkinitcpio.conf backup."
end

# grub-btrfs may not be installed yet on a fresh system. If its config already
# exists, capture the real pre-run state now. If it does not exist, the package
# installation below will create the baseline that rollback can preserve.
set GRUB_BTRFS_CONFIG_PREEXISTED 0
if test -f "$GRUB_BTRFS_CONFIG"
    set GRUB_BTRFS_CONFIG_PREEXISTED 1
    if not test -f "$GRUB_BTRFS_BACKUP"
        cp -a "$GRUB_BTRFS_CONFIG" "$GRUB_BTRFS_BACKUP"; or die "Could not create the grub-btrfs configuration backup."
    end
end

# Back up configuration files that this installer may edit in BOTH modes.
# These per-run backups are also required for Safe-mode rollback; never remove
# a pre-existing user file merely because this run did not create a backup.
set CONFIG_BACKUP_PAIRS \\
    "$SNAP_CONF|$SNAP_CONF_BACKUP" \\
    "$SNAP_SYS|$SNAP_SYS_BACKUP" \\
    "$REMOUNT_DROPIN|$REMOUNT_DROPIN_BACKUP" \\
    "$GRUB_BTRFSD_OVERRIDE|$GRUB_BTRFSD_OVERRIDE_BACKUP"
for BACKUP_PAIR in $CONFIG_BACKUP_PAIRS
    set BACKUP_PARTS (string split -m1 '|' -- "$BACKUP_PAIR")
    set BACKUP_SOURCE "$BACKUP_PARTS[1]"
    set BACKUP_DEST "$BACKUP_PARTS[2]"
    if test -f "$BACKUP_SOURCE"
        cp -a "$BACKUP_SOURCE" "$BACKUP_DEST"; or die "Could not create backup for $BACKUP_SOURCE."
    end
end

# In reset mode, also preserve every configuration file that can affect boot
# before the reset begins. These backups are used only for rollback.
if test "$INSTALL_MODE" = 2
    # Back up the existing Snapper root config BEFORE any Btrfs snapshot
    # storage is moved. The old config and old @snapshots tree must remain
    # recoverable as a pair throughout reset.
    if test -e $SNAPPER_CONFIG
        if not test -f $SNAPPER_CONFIG
            die "The existing Snapper root configuration path is not a regular file. Reset aborted."
        end
        cp -a $SNAPPER_CONFIG $SNAPPER_CONFIG_BACKUP; or die "Could not back up the existing Snapper root configuration. Reset aborted; no snapshot data was moved."
    end
end

# Install required packages only AFTER all pre-existing configuration files have
# been backed up. This prevents a pacman upgrade from changing a file before
# rollback has captured its true pre-installer state.
run_step "Installing required packages..."
pacman -S --needed --noconfirm snapper snap-pac grub-btrfs inotify-tools; or die "Package installation failed."

# These commands are provided by packages that may not exist on a fresh
# installation. Check them only after pacman has had a chance to install the
# required packages; refusing earlier would make the installer unable to repair
# a system missing one of these tools.
require_command snapper mkinitcpio grub-mkconfig lsinitcpio id
if not test -f /etc/mkinitcpio.conf
    die "The mkinitcpio configuration file /etc/mkinitcpio.conf is missing after package installation."
end

if not test -f "$GRUB_BTRFS_CONFIG"
    die "grub-btrfs configuration file is missing after package installation: $GRUB_BTRFS_CONFIG"
end
# On a fresh install, preserve the package-created configuration as the rollback
# baseline. It is intentionally NOT removed on failure because pacman itself is
# not transactionally rolled back by this installer.
if test "$GRUB_BTRFS_CONFIG_PREEXISTED" -eq 0; and not test -f "$GRUB_BTRFS_BACKUP"
    cp -a "$GRUB_BTRFS_CONFIG" "$GRUB_BTRFS_BACKUP"; or die "Could not save the newly installed grub-btrfs configuration baseline."
end

# The same principle applies to Snapper's package configuration files: if they
# did not exist before pacman but the package creates them, keep that package
# baseline rather than deleting package-owned files during rollback.
for BASELINE_PAIR in \
    "$SNAP_CONF|$SNAP_CONF_BACKUP" \
    "$SNAP_SYS|$SNAP_SYS_BACKUP"
    set BASELINE_PARTS (string split -m1 '|' -- "$BASELINE_PAIR")
    set BASELINE_SOURCE "$BASELINE_PARTS[1]"
    set BASELINE_DEST "$BASELINE_PARTS[2]"
    if test -f "$BASELINE_SOURCE"; and not test -f "$BASELINE_DEST"
        cp -a "$BASELINE_SOURCE" "$BASELINE_DEST"; or die "Could not save the package baseline for $BASELINE_SOURCE."
    end
end

function restore_arch_function --on-event fish_exit
    if test "$INSTALL_COMMITTED" -eq 0; and test "$ARCH_FUNC_INSTALLED" -eq 1
        if test "$ARCH_FUNC_BACKUP_CREATED" -eq 1; and test -f "$ARCH_FUNC_BACKUP"
            cp -a "$ARCH_FUNC_BACKUP" "$ARCH_FUNC_FILE" >/dev/null 2>&1
        else
            rm -f "$ARCH_FUNC_FILE" >/dev/null 2>&1
        end
    end
end

# In normal/safe mode, configuration files are also modified. If any later
# step fails, restore the exact files that existed before this run. This keeps
# a failed safe-mode install from leaving half-applied fstab/mkinitcpio/GRUB
# or systemd changes behind. Snapshot storage itself is never deleted here.
function safe_mode_rollback --on-event fish_exit
    if test "$INSTALL_MODE" = 1; and test "$INSTALL_COMMITTED" -eq 0
        if test -f "$FSTAB_BACKUP"
            cp -a "$FSTAB_BACKUP" /etc/fstab >/dev/null 2>&1
        end
        if test -f "$MKINITCPIO_BACKUP"
            cp -a "$MKINITCPIO_BACKUP" /etc/mkinitcpio.conf >/dev/null 2>&1
        end
        if test -f "$GRUB_BTRFS_BACKUP"
            cp -a "$GRUB_BTRFS_BACKUP" "$GRUB_BTRFS_CONFIG" >/dev/null 2>&1
        end
        if test -f "$SNAP_CONF_BACKUP"
            cp -a "$SNAP_CONF_BACKUP" "$SNAP_CONF" >/dev/null 2>&1
        else
            rm -f "$SNAP_CONF" >/dev/null 2>&1
        end
        if test -f "$SNAP_SYS_BACKUP"
            cp -a "$SNAP_SYS_BACKUP" "$SNAP_SYS" >/dev/null 2>&1
        else
            rm -f "$SNAP_SYS" >/dev/null 2>&1
        end
        if test -f "$REMOUNT_DROPIN_BACKUP"
            mkdir -p (dirname "$REMOUNT_DROPIN") >/dev/null 2>&1
            cp -a "$REMOUNT_DROPIN_BACKUP" "$REMOUNT_DROPIN" >/dev/null 2>&1
        else
            rm -f "$REMOUNT_DROPIN" >/dev/null 2>&1
        end
        if test -f "$GRUB_BTRFSD_OVERRIDE_BACKUP"
            mkdir -p (dirname "$GRUB_BTRFSD_OVERRIDE") >/dev/null 2>&1
            cp -a "$GRUB_BTRFSD_OVERRIDE_BACKUP" "$GRUB_BTRFSD_OVERRIDE" >/dev/null 2>&1
        else
            rm -f "$GRUB_BTRFSD_OVERRIDE" >/dev/null 2>&1
        end
        # If this run created the Snapper root config, remove that temporary
        # config. Never remove a config that pre-dated this run.
        if test "$CREATED_CONFIG" -eq 1
            rm -f "$SNAPPER_CONFIG" >/dev/null 2>&1
        end

        # The text configuration is restored above, but initramfs and grub.cfg
        # may already have been regenerated before the failure. Rebuild them
        # from the restored configuration so rollback does not leave boot
        # artifacts referring to the failed installation.
        systemctl daemon-reload >/dev/null 2>&1
        mkinitcpio -P >/dev/null 2>&1
        grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1

        # Restore grub-btrfsd to the exact active/enabled state captured before
        # Safe mode started. The installer may have enabled/started it before a
        # later verification step failed.
        systemctl daemon-reload >/dev/null 2>&1
        if test "$WAS_GRUB_BTRFSD_ENABLED" -eq 1
            systemctl enable grub-btrfsd.service >/dev/null 2>&1
        else
            systemctl disable grub-btrfsd.service >/dev/null 2>&1
        end
        if test "$WAS_GRUB_BTRFSD_ACTIVE" -eq 1
            systemctl start grub-btrfsd.service >/dev/null 2>&1
        else
            systemctl stop grub-btrfsd.service >/dev/null 2>&1
        end

        # If this run mounted /.snapshots and it was not mounted beforehand,
        # return it to the pre-install state. Do not unmount a pre-existing mount.
        if test "$PRE_INSTALL_SNAPSHOTS_MOUNTED" -eq 0; and mountpoint -q /.snapshots
            umount /.snapshots >/dev/null 2>&1
        end
    end
end

# If reset mode exits unexpectedly after moving the old snapshot tree aside,
# restore the old tree and Snapper config. This is intentionally best-effort:
# never delete the old backup during rollback.
function reset_rollback --on-event fish_exit
    # The package-level Snapper configuration is edited before the destructive
    # storage reset starts. If that early stage fails, restore only those files;
    # do not touch @snapshots because it has not been moved yet.
    if test "$INSTALL_MODE" = 2; and test "$RESET_CONFIG_CHANGES_STARTED" -eq 1; and test "$RESET_OPERATION_STARTED" -eq 0; and test "$RESET_COMMITTED" -eq 0
        if test -f "$SNAP_CONF_BACKUP"
            cp -a "$SNAP_CONF_BACKUP" "$SNAP_CONF" >/dev/null 2>&1
        else
            rm -f "$SNAP_CONF" >/dev/null 2>&1
        end
        if test -f "$SNAP_SYS_BACKUP"
            cp -a "$SNAP_SYS_BACKUP" "$SNAP_SYS" >/dev/null 2>&1
        else
            rm -f "$SNAP_SYS" >/dev/null 2>&1
        end
    end

    if test "$INSTALL_MODE" = 2; and test "$RESET_OPERATION_STARTED" -eq 1; and test "$RESET_COMMITTED" -eq 0
        # Before destructive cleanup starts, the new tree can be moved aside and
        # the old tree restored without deleting either tree.
        if test "$RESET_CLEANUP_STARTED" -eq 0
            # /.snapshots may have been mounted again before a later verification
            # failure. It must be unmounted before moving the @snapshots
            # subvolume, otherwise the old storage can remain busy/inconsistent.
            if mountpoint -q /.snapshots
                umount /.snapshots >/dev/null 2>&1
            end
            if mountpoint -q "$BTRFS_MOUNT"
                umount "$BTRFS_MOUNT" 2>/dev/null
            end
            mkdir -p "$BTRFS_MOUNT" 2>/dev/null
            if mount -o subvolid=5 "$ROOT_DEV" "$BTRFS_MOUNT" 2>/dev/null
                # Never touch the live @snapshots tree merely because reset mode
                # was entered. Storage rollback is armed only after the old tree
                # was actually moved or a new tree was actually created.
                if test "$RESET_STORAGE_MOVED" -eq 1
                    # Remove only the replacement tree created by this run, then
                    # restore the old tree from its backup. This avoids the old
                    # rollback path that could leave the replacement tree in place
                    # if a rename failed.
                    set ROLLBACK_STORAGE_OK 1
                    if test -d "$BTRFS_MOUNT/@snapshots"
                        if test (get_subvol_uuid "$BTRFS_MOUNT/@snapshots") != "$RESET_NEW_TREE_UUID"
                            set ROLLBACK_STORAGE_OK 0
                        end
                    end
                    if test "$ROLLBACK_STORAGE_OK" -eq 1; and test -d "$BTRFS_MOUNT/@snapshots"
                        set ROLLBACK_CHILD_SUBVOLS (btrfs subvolume list -o "$BTRFS_MOUNT/@snapshots" | awk '{print $NF}' | awk '{ print gsub("/", "/"), $0 }' | sort -rn | cut -d' ' -f2-)
                        for ROLLBACK_CHILD in $ROLLBACK_CHILD_SUBVOLS
                            if not btrfs subvolume delete "$BTRFS_MOUNT/$ROLLBACK_CHILD" >/dev/null 2>&1
                                set ROLLBACK_STORAGE_OK 0
                                break
                            end
                        end
                        if test "$ROLLBACK_STORAGE_OK" -eq 1
                            if not btrfs subvolume delete "$BTRFS_MOUNT/@snapshots" >/dev/null 2>&1
                                set ROLLBACK_STORAGE_OK 0
                            end
                        end
                    end
                    if test "$ROLLBACK_STORAGE_OK" -eq 1
                        if not test -d "$BTRFS_MOUNT/$RESET_BACKUP_SUBVOL"; or test -e "$BTRFS_MOUNT/@snapshots"
                            set ROLLBACK_STORAGE_OK 0
                        end
                    end
                    if test "$ROLLBACK_STORAGE_OK" -eq 1
                        if test (get_subvol_uuid "$BTRFS_MOUNT/$RESET_BACKUP_SUBVOL") != "$RESET_OLD_TREE_UUID"
                            set ROLLBACK_STORAGE_OK 0
                        end
                    end
                    if test "$ROLLBACK_STORAGE_OK" -eq 1
                        if not mv "$BTRFS_MOUNT/$RESET_BACKUP_SUBVOL" "$BTRFS_MOUNT/@snapshots" >/dev/null 2>&1
                            set ROLLBACK_STORAGE_OK 0
                        end
                    end
                else if test "$RESET_NEW_TREE_CREATED" -eq 1
                    set ROLLBACK_STORAGE_OK 1
                    if test -d "$BTRFS_MOUNT/@snapshots"
                        if test (get_subvol_uuid "$BTRFS_MOUNT/@snapshots") != "$RESET_NEW_TREE_UUID"
                            set ROLLBACK_STORAGE_OK 0
                        end
                    end
                    if test "$ROLLBACK_STORAGE_OK" -eq 1; and test -d "$BTRFS_MOUNT/@snapshots"
                        set ROLLBACK_CHILD_SUBVOLS (btrfs subvolume list -o "$BTRFS_MOUNT/@snapshots" | awk '{print $NF}' | awk '{ print gsub("/", "/"), $0 }' | sort -rn | cut -d' ' -f2-)
                        for ROLLBACK_CHILD in $ROLLBACK_CHILD_SUBVOLS
                            if not btrfs subvolume delete "$BTRFS_MOUNT/$ROLLBACK_CHILD" >/dev/null 2>&1
                                set ROLLBACK_STORAGE_OK 0
                                break
                            end
                        end
                        if test "$ROLLBACK_STORAGE_OK" -eq 1
                            if not btrfs subvolume delete "$BTRFS_MOUNT/@snapshots" >/dev/null 2>&1
                                set ROLLBACK_STORAGE_OK 0
                            end
                        end
                    end
                else
                    set ROLLBACK_STORAGE_OK 1
                end
                if test "$ROLLBACK_STORAGE_OK" -eq 1
                    set RESET_STORAGE_ROLLBACK_OK 1
                else
                    echo " WARNING: automatic snapshot-storage rollback could not be completed. The old backup was not intentionally deleted; inspect the Btrfs top-level before changing /etc/fstab or Snapper configuration."
                end
                umount "$BTRFS_MOUNT" >/dev/null 2>&1
                rmdir "$BTRFS_MOUNT" >/dev/null 2>&1
            end

            # Restore the exact small configuration files saved for this run.
            # Reset mode must leave the pre-reset configuration intact if a
            # later step fails.
            if test "$RESET_STORAGE_ROLLBACK_OK" -eq 1
                if test -f "$SNAPPER_CONFIG_BACKUP"
                    mkdir -p /etc/snapper/configs >/dev/null 2>&1
                    cp -a "$SNAPPER_CONFIG_BACKUP" "$SNAPPER_CONFIG" >/dev/null 2>&1
                else
                    # No root config existed before reset. Remove the temporary
                    # config created by this failed run instead of leaving a
                    # half-reset Snapper configuration behind.
                    rm -f "$SNAPPER_CONFIG" >/dev/null 2>&1
                end
                if test -f "$FSTAB_BACKUP"
                    cp -a "$FSTAB_BACKUP" /etc/fstab >/dev/null 2>&1
                end
            else
                echo " WARNING: Snapper root config and /etc/fstab were NOT automatically restored because snapshot-storage rollback was incomplete."
            end
            if test -f "$MKINITCPIO_BACKUP"
                cp -a "$MKINITCPIO_BACKUP" /etc/mkinitcpio.conf >/dev/null 2>&1
            end
            if test -f "$GRUB_BTRFS_BACKUP"
                cp -a "$GRUB_BTRFS_BACKUP" "$GRUB_BTRFS_CONFIG" >/dev/null 2>&1
            end

            if test -f "$SNAP_CONF_BACKUP"
                cp -a "$SNAP_CONF_BACKUP" "$SNAP_CONF" >/dev/null 2>&1
            else
                rm -f "$SNAP_CONF" >/dev/null 2>&1
            end
            if test -f "$SNAP_SYS_BACKUP"
                cp -a "$SNAP_SYS_BACKUP" "$SNAP_SYS" >/dev/null 2>&1
            else
                rm -f "$SNAP_SYS" >/dev/null 2>&1
            end
            if test -f "$REMOUNT_DROPIN_BACKUP"
                mkdir -p (dirname "$REMOUNT_DROPIN") >/dev/null 2>&1
                cp -a "$REMOUNT_DROPIN_BACKUP" "$REMOUNT_DROPIN" >/dev/null 2>&1
            else
                rm -f "$REMOUNT_DROPIN" >/dev/null 2>&1
            end
            if test -f "$GRUB_BTRFSD_OVERRIDE_BACKUP"
                mkdir -p (dirname "$GRUB_BTRFSD_OVERRIDE") >/dev/null 2>&1
                cp -a "$GRUB_BTRFSD_OVERRIDE_BACKUP" "$GRUB_BTRFSD_OVERRIDE" >/dev/null 2>&1
            else
                rm -f "$GRUB_BTRFSD_OVERRIDE" >/dev/null 2>&1
            end

            # Rebuild boot metadata after restoring the pre-reset configuration.
            # This prevents grub.cfg/initramfs from referring to the temporary
            # reset configuration after a failed reset.
            systemctl daemon-reload >/dev/null 2>&1
            mkinitcpio -P >/dev/null 2>&1
            grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1

            # Restore the /.snapshots mount to the state it had before reset.
            # If it was not mounted before reset, do not introduce a new mount
            # as a side effect of rollback.
            if test "$PRE_RESET_SNAPSHOTS_MOUNTED" -eq 1
                mount /.snapshots >/dev/null 2>&1
            end
        end

        # Restore services even if destructive cleanup has already started.
        # If cleanup failed part-way through, the old snapshot backup is kept
        # for manual recovery rather than pretending an automatic rollback is safe.
        if test "$WAS_GRUB_BTRFSD_ACTIVE" -eq 1
            systemctl start grub-btrfsd.service >/dev/null 2>&1
        else
            systemctl stop grub-btrfsd.service >/dev/null 2>&1
        end
        if test "$WAS_TIMELINE_ACTIVE" -eq 1
            systemctl start snapper-timeline.timer >/dev/null 2>&1
        else
            systemctl stop snapper-timeline.timer >/dev/null 2>&1
        end
        if test "$WAS_CLEANUP_ACTIVE" -eq 1
            systemctl start snapper-cleanup.timer >/dev/null 2>&1
        else
            systemctl stop snapper-cleanup.timer >/dev/null 2>&1
        end
    end

    # Always clean up the private runtime mount on exit, including safe-mode failures.
    if mountpoint -q "$BTRFS_MOUNT" 2>/dev/null
        umount "$BTRFS_MOUNT" >/dev/null 2>&1
    end
    rmdir "$BTRFS_MOUNT" >/dev/null 2>&1
end


# In reset mode, the package configuration files below are the first files
# changed after their backups are created. Arm a small rollback path now so a
# failure here cannot leave SNAPPER_CONFIGS pointing at a half-reset setup.
if test "$INSTALL_MODE" = 2
    set RESET_CONFIG_CHANGES_STARTED 1
end

# 5. Create the Snapper package configuration files before hooks can run.
mkdir -p /etc/conf.d /etc/sysconfig
if test -f $SNAP_CONF
    set SNAP_CFG_LINES (grep -E '^SNAPPER_CONFIGS=' $SNAP_CONF)
    if test (count $SNAP_CFG_LINES) -ne 1
        die "/etc/conf.d/snapper has no unique SNAPPER_CONFIGS assignment. Refusing to modify it."
    end
    set SNAP_CFG_VALUE (string replace -r '^SNAPPER_CONFIGS=' '' -- "$SNAP_CFG_LINES[1]")
    set SNAP_CFG_VALUE (string trim -c '"' -- "$SNAP_CFG_VALUE")
    set SNAP_CFG_TOKENS (string split ' ' -- "$SNAP_CFG_VALUE")
    if not contains -- root $SNAP_CFG_TOKENS
        die "/etc/conf.d/snapper does not include root in SNAPPER_CONFIGS. Refusing to overwrite it."
    end
else
    printf '%s\n' 'SNAPPER_CONFIGS="root"' > $SNAP_CONF
end
if test -f $SNAP_SYS
    set SNAP_SYS_LINES (grep -E '^SNAPPER_CONFIGS=' $SNAP_SYS)
    if test (count $SNAP_SYS_LINES) -ne 1
        die "/etc/sysconfig/snapper has no unique SNAPPER_CONFIGS assignment. Refusing to modify it."
    end
    set SNAP_SYS_VALUE (string replace -r '^SNAPPER_CONFIGS=' '' -- "$SNAP_SYS_LINES[1]")
    set SNAP_SYS_VALUE (string trim -c '"' -- "$SNAP_SYS_VALUE")
    set SNAP_SYS_TOKENS (string split ' ' -- "$SNAP_SYS_VALUE")
    if not contains -- root $SNAP_SYS_TOKENS
        die "/etc/sysconfig/snapper does not include root in SNAPPER_CONFIGS. Refusing to overwrite it."
    end
else
    printf '%s\n' 'SNAPPER_CONFIGS="root"' > $SNAP_SYS
end

# 6. Reset mode: rename the old snapshot container first instead of
# deleting it immediately. This keeps the old snapshots available until the
# new configuration has been created and verified.
# Capture the pre-install grub-btrfsd state so Safe mode can restore both
# runtime activity and enablement if a later step fails.
if systemctl is-active --quiet grub-btrfsd.service
    set WAS_GRUB_BTRFSD_ACTIVE 1
end
if systemctl is-enabled --quiet grub-btrfsd.service
    set WAS_GRUB_BTRFSD_ENABLED 1
end

# If a later step fails after the installer overwrites the user's Fish function,
# restore the previous file (or remove the newly-created file). This is separate
# from reset rollback because Safe mode can also fail after installing arch.fish.
if test "$INSTALL_MODE" = 2
    set RESET_OPERATION_STARTED 1
    run_step "Preparing snapshot reset..."
    if mountpoint -q /.snapshots
        set PRE_RESET_SNAPSHOTS_MOUNTED 1
        set PRE_RESET_SNAPSHOTS_UUID (findmnt -no UUID /.snapshots)
        if test -z "$PRE_RESET_SNAPSHOTS_UUID"; or test "$PRE_RESET_SNAPSHOTS_UUID" != "$ROOT_UUID"
            die "Reset requires /.snapshots to be mounted from the same Btrfs filesystem as /. Refusing to move @snapshots on a filesystem that cannot be proven to be the active snapshot store."
        end
    else
        die "Reset requires /.snapshots to be mounted before reset. Mount it normally and run the installer again."
    end
    if systemctl is-active --quiet grub-btrfsd.service
        set WAS_GRUB_BTRFSD_ACTIVE 1
        systemctl stop grub-btrfsd.service; or die "Could not stop grub-btrfsd.service safely."
    end

    if systemctl is-active --quiet snapper-timeline.timer
        set WAS_TIMELINE_ACTIVE 1
        set RESTART_TIMELINE_TIMER 1
        systemctl stop snapper-timeline.timer; or die "Could not stop snapper-timeline.timer safely."
    end
    if systemctl is-active --quiet snapper-cleanup.timer
        set WAS_CLEANUP_ACTIVE 1
        set RESTART_CLEANUP_TIMER 1
        systemctl stop snapper-cleanup.timer; or die "Could not stop snapper-cleanup.timer safely."
    end

    if mountpoint -q /.snapshots
        umount /.snapshots; or die "Could not unmount /.snapshots. Reset aborted; no snapshot data was deleted."
    end

    mkdir -p $BTRFS_MOUNT
    mount -o subvolid=5 $ROOT_DEV $BTRFS_MOUNT; or die "Could not mount the Btrfs top-level subvolume. Reset aborted."

    # Before moving @snapshots, prove that it is actually the snapshot storage
    # used by this Snapper root configuration. A directory named @snapshots is
    # not enough evidence: it could belong to another tool or another layout.
    if test -f "$SNAPPER_CONFIG"
        if not test -f "$SNAPPER_CONFIG_BACKUP"
            umount "$BTRFS_MOUNT" 2>/dev/null
            rmdir "$BTRFS_MOUNT" 2>/dev/null
            die "The existing Snapper root configuration has no reset backup. Refusing to move @snapshots."
        end
        if not grep -qE '^SUBVOLUME="/"$' "$SNAPPER_CONFIG"
            umount "$BTRFS_MOUNT" 2>/dev/null
            rmdir "$BTRFS_MOUNT" 2>/dev/null
            die "The existing Snapper root configuration does not target /. Reset aborted; refusing to destroy unrelated @snapshots storage."
        end
    else if test -d "$BTRFS_MOUNT/@snapshots"
        # If @snapshots already exists but there is no root Snapper config,
        # ownership of that subvolume cannot be established safely.
        umount "$BTRFS_MOUNT" 2>/dev/null
        rmdir "$BTRFS_MOUNT" 2>/dev/null
        die "An existing @snapshots subvolume was found but /etc/snapper/configs/root does not exist. Reset aborted to avoid deleting storage owned by another setup."
    end

    # The active fstab entry is part of the identity check. Require exactly one
    # /.snapshots entry and require it to point at /@snapshots before moving it.
    set RESET_FSTAB_LINES (grep -E '^[[:space:]]*[^#][^[:space:]]+[[:space:]]+/\.snapshots[[:space:]]+btrfs[[:space:]]' /etc/fstab)
    if test (count $RESET_FSTAB_LINES) -ne 1
        umount "$BTRFS_MOUNT" 2>/dev/null
        rmdir "$BTRFS_MOUNT" 2>/dev/null
        die "Reset requires exactly one active /.snapshots Btrfs entry in /etc/fstab. Refusing to move @snapshots."
    end
    if not string match -qr '(^|[[:space:],])subvol=/@snapshots([,[:space:]]|$)' -- "$RESET_FSTAB_LINES[1]"
        umount "$BTRFS_MOUNT" 2>/dev/null
        rmdir "$BTRFS_MOUNT" 2>/dev/null
        die "The active /.snapshots fstab entry does not use subvol=/@snapshots. Reset aborted to protect unrelated Btrfs storage."
    end

    if test -d "$BTRFS_MOUNT/@snapshots"
        # Never move an arbitrary directory into the reset backup. The reset
        # logic is designed for the Btrfs @snapshots subvolume only.
        if not btrfs subvolume show "$BTRFS_MOUNT/@snapshots" >/dev/null 2>&1
            umount "$BTRFS_MOUNT" 2>/dev/null
            rmdir "$BTRFS_MOUNT" 2>/dev/null
            die "The existing @snapshots path is not a Btrfs subvolume. Reset aborted; no snapshot data was deleted."
        end
        set RESET_OLD_TREE_UUID (get_subvol_uuid "$BTRFS_MOUNT/@snapshots")
        if test -z "$RESET_OLD_TREE_UUID"
            umount "$BTRFS_MOUNT" 2>/dev/null
            rmdir "$BTRFS_MOUNT" 2>/dev/null
            die "Could not read the UUID of the existing @snapshots subvolume. Reset aborted; no snapshot data was moved."
        end
        set RESET_BACKUP_SUBVOL "@snapshots-reset-backup-"(string join '-' (date +%Y%m%d-%H%M%S) $fish_pid)
        if not mv "$BTRFS_MOUNT/@snapshots" "$BTRFS_MOUNT/$RESET_BACKUP_SUBVOL"
            umount "$BTRFS_MOUNT" 2>/dev/null
            rmdir "$BTRFS_MOUNT" 2>/dev/null
            die "Could not rename the old @snapshots subvolume. Reset aborted; old snapshots were not deleted."
        end
        # Verify the move really produced the expected rollback source before
        # creating anything new. Never proceed if both names or neither name
        # are present.
        if not test -d "$BTRFS_MOUNT/$RESET_BACKUP_SUBVOL"; or test -e "$BTRFS_MOUNT/@snapshots"
            umount "$BTRFS_MOUNT" 2>/dev/null
            rmdir "$BTRFS_MOUNT" 2>/dev/null
            die "The old @snapshots subvolume could not be verified after rename. Reset aborted."
        end
        if test (get_subvol_uuid "$BTRFS_MOUNT/$RESET_BACKUP_SUBVOL") != "$RESET_OLD_TREE_UUID"
            umount "$BTRFS_MOUNT" 2>/dev/null
            rmdir "$BTRFS_MOUNT" 2>/dev/null
            die "The renamed @snapshots backup has a different UUID. Reset aborted to protect the original snapshot tree."
        end
        set RESET_STORAGE_MOVED 1
    end

    # Do not restore the old tree here if creation fails. The exit rollback
    # handler is the single owner of storage restoration. Restoring here and
    # then running the rollback handler would make the handler mistake the
    # restored old tree for the newly-created tree and could move it aside.
    btrfs subvolume create $BTRFS_MOUNT/@snapshots; or begin
        umount $BTRFS_MOUNT 2>/dev/null
        rmdir $BTRFS_MOUNT 2>/dev/null
        die "Could not create the new @snapshots container. Reset aborted; the old snapshot tree will be restored automatically."
    end
    set RESET_NEW_TREE_CREATED 1
    if not btrfs subvolume show "$BTRFS_MOUNT/@snapshots" >/dev/null 2>&1
        umount "$BTRFS_MOUNT" 2>/dev/null
        rmdir "$BTRFS_MOUNT" 2>/dev/null
        die "The newly created @snapshots path is not a valid Btrfs subvolume. Reset aborted."
    end
    set RESET_NEW_TREE_UUID (get_subvol_uuid "$BTRFS_MOUNT/@snapshots")
    if test -z "$RESET_NEW_TREE_UUID"
        umount "$BTRFS_MOUNT" 2>/dev/null
        rmdir "$BTRFS_MOUNT" 2>/dev/null
        die "Could not read the UUID of the newly created @snapshots subvolume. Reset aborted."
    end

    umount $BTRFS_MOUNT; or die "Could not unmount the temporary Btrfs mount."
    rmdir $BTRFS_MOUNT 2>/dev/null

    # The old Snapper config was backed up before any snapshot storage was
    # moved. Remove only the config file now; the old snapshot tree remains
    # untouched as the rollback backup.
    # The old config points at the old snapshot tree. Remove only the config
    # file; the old snapshot tree itself remains untouched as the backup.
    rm -f "$SNAPPER_CONFIG"; or begin
        umount "$BTRFS_MOUNT" 2>/dev/null
        rmdir "$BTRFS_MOUNT" 2>/dev/null
        die "Could not remove the old Snapper root configuration. Reset aborted; old snapshots were not deleted."
    end
    if test -e "$SNAPPER_CONFIG"
        die "The old Snapper root configuration still exists after removal. Reset aborted."
    end

    # snapper create-config creates /.snapshots itself. Because the old
    # /.snapshots mount is already unmounted, remove only the empty mountpoint
    # directory here so Snapper can create its temporary subvolume.
    if test -d /.snapshots; and test (count (command ls -A /.snapshots 2>/dev/null)) -eq 0
        rmdir /.snapshots 2>/dev/null; or die "Could not remove the empty /.snapshots mountpoint. Reset aborted; old snapshots remain in backup."
    end
end

# 7. Ensure the @snapshots subvolume exists without adopting or deleting
# storage that cannot be tied to this Snapper installation.
if mountpoint -q /.snapshots
    set PRE_INSTALL_SNAPSHOTS_MOUNTED 1
end
run_step "Checking @snapshots subvolume..."
mkdir -p $BTRFS_MOUNT
mount -o subvolid=5 $ROOT_DEV $BTRFS_MOUNT; or die "Could not mount the Btrfs top-level subvolume."

if test -d "$BTRFS_MOUNT/@snapshots"
    if not btrfs subvolume show "$BTRFS_MOUNT/@snapshots" >/dev/null 2>&1
        umount "$BTRFS_MOUNT" 2>/dev/null
        rmdir "$BTRFS_MOUNT" 2>/dev/null
        die "The existing @snapshots path is not a Btrfs subvolume. Refusing to use it automatically."
    end
    # Safe mode must never silently adopt an existing snapshot-storage tree
    # when the corresponding Snapper root config is missing. That tree could
    # belong to another setup/tool. Reset mode performs its own stricter
    # ownership checks above.
    if test "$INSTALL_MODE" = 1; and not test -f "$SNAPPER_CONFIG"
        umount "$BTRFS_MOUNT" 2>/dev/null
        rmdir "$BTRFS_MOUNT" 2>/dev/null
        die "An existing @snapshots subvolume was found but the Snapper root config is missing. Safe install refuses to adopt unrelated snapshot storage."
    end
else
    # If a Snapper root config already exists, its snapshot storage is expected
    # to be recoverable. Safe mode refuses to manufacture a new empty store
    # behind an existing config because that could disconnect existing snapshots.
    if test "$INSTALL_MODE" = 1; and test -f "$SNAPPER_CONFIG"
        umount "$BTRFS_MOUNT" 2>/dev/null
        rmdir "$BTRFS_MOUNT" 2>/dev/null
        die "Snapper root config exists, but @snapshots does not. Safe install refuses to create a replacement snapshot store automatically."
    end
    btrfs subvolume create "$BTRFS_MOUNT/@snapshots"; or begin
        umount "$BTRFS_MOUNT" 2>/dev/null
        rmdir "$BTRFS_MOUNT" 2>/dev/null
        die "Could not create @snapshots."
    end
end

umount $BTRFS_MOUNT; or die "Could not unmount the temporary Btrfs top-level subvolume."
rmdir $BTRFS_MOUNT 2>/dev/null

# 8. Configure Snapper only if the root config does not already exist.
run_step "Configuring Snapper..."
mkdir -p /etc/snapper/configs
if not test -f /etc/snapper/configs/root
    snapper -c root create-config /; or die "Could not create the Snapper root configuration."
    set CREATED_CONFIG 1
end

if not grep -qE '^SUBVOLUME="/"$' /etc/snapper/configs/root
    die "The Snapper root configuration does not target SUBVOLUME=/. Refusing to continue."
end

# snapper create-config creates its own /.snapshots Btrfs subvolume.
# This project intentionally uses the top-level @snapshots subvolume instead,
# so remove only Snapper's newly-created container and replace it with the
# project-managed mount. In safe mode an existing mounted /.snapshots is kept.
run_step "Configuring /.snapshots..."
if not mountpoint -q /.snapshots
    if test $CREATED_CONFIG -eq 1
        if btrfs subvolume show /.snapshots >/dev/null 2>&1
            btrfs subvolume delete /.snapshots; or die "Could not remove the temporary /.snapshots subvolume."
        else if not test -d /.snapshots
            mkdir -p /.snapshots
        else if test (count (command ls -A /.snapshots 2>/dev/null)) -gt 0
            die "A non-mounted /.snapshots directory already contains files. Refusing to delete it automatically."
        end
        mkdir -p /.snapshots
    else
        die "Snapper root config already exists, but /.snapshots is not mounted. Refusing to modify existing snapshot storage automatically."
    end
end

# Find an active (non-comment) /.snapshots entry regardless of whether it
# identifies the filesystem by UUID, LABEL, PARTUUID, or device path.
set SNAP_FSTAB_LINES (grep -E '^[[:space:]]*[^#][^[:space:]]+[[:space:]]+/\.snapshots[[:space:]]+btrfs[[:space:]]' /etc/fstab)
if test (count $SNAP_FSTAB_LINES) -eq 0
    # Reuse the current root mount's Btrfs options instead of hard-coding
    # discard/space_cache/etc. This preserves user-specific filesystem tuning.
    set SNAP_FSTAB_OPTIONS rw
    for ROOT_OPT in (string split ',' -- "$ROOT_OPTIONS")
        if test "$ROOT_OPT" = "rw"; or test "$ROOT_OPT" = "ro"
            continue
        end
        if string match -q 'subvol=*' -- "$ROOT_OPT"; or string match -q 'subvolid=*' -- "$ROOT_OPT"
            continue
        end
        set SNAP_FSTAB_OPTIONS $SNAP_FSTAB_OPTIONS $ROOT_OPT
    end
    set SNAP_FSTAB_OPTIONS_TEXT (string join ',' $SNAP_FSTAB_OPTIONS)
    printf 'UUID=%s\t/.snapshots\tbtrfs\t%s,subvol=/@snapshots\t0 0\n' "$ROOT_UUID" "$SNAP_FSTAB_OPTIONS_TEXT" >> /etc/fstab
else
    if test (count $SNAP_FSTAB_LINES) -ne 1
        die "Multiple active /.snapshots entries exist in /etc/fstab. Refusing to choose one automatically."
    end
    if not string match -qr '(^|[[:space:],])subvol=/@snapshots([,[:space:]]|$)' -- "$SNAP_FSTAB_LINES[1]"
        die "An existing /.snapshots entry in /etc/fstab does not use the exact subvol=/@snapshots option. Refusing to overwrite it automatically."
    end
    echo " /.snapshots entry already exists in /etc/fstab."
end

systemctl daemon-reload
mount /.snapshots 2>/dev/null; or true

if not mountpoint -q /.snapshots
    die "Could not mount /.snapshots from /etc/fstab."
end

# Verify that the mounted filesystem really is the project snapshot subvolume.
set SNAP_MOUNT (findmnt -no FSTYPE,OPTIONS /.snapshots)
if not string match -qr '(^|,)subvol=/@snapshots($|,)' -- "$SNAP_MOUNT"
    die "/.snapshots is mounted, but it is not @snapshots. Refusing to continue."
end

# Verify the Snapper config and mount agree on the same root/snapshot layout.
if not grep -qE '^SUBVOLUME="/"$' /etc/snapper/configs/root
    die "Snapper root config is not SUBVOLUME=/. Refusing to continue."
end

chmod 750 /.snapshots

# 10. Configure the kernel parameters used by every GRUB-Btrfs snapshot entry.
# The first parameter enables the temporary OverlayFS userspace path and the
# second is the marker consumed by our systemd-remount-fs drop-in.
run_step "Configuring GRUB-Btrfs snapshot kernel parameters..."
set GRUB_PARAM_LINES (grep -E '^GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS=' $GRUB_BTRFS_CONFIG)
if test (count $GRUB_PARAM_LINES) -gt 1
    die "Multiple GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS assignments found. Refusing to modify the GRUB-Btrfs config automatically."
end

if test (count $GRUB_PARAM_LINES) -eq 0
    printf '%s\n' 'GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS="rd.live.overlay.overlayfs=1 snapper_snapshot_boot=1"' >> $GRUB_BTRFS_CONFIG
else
    set GRUB_PARAM_LINE $GRUB_PARAM_LINES[1]
    if not string match -qr '^GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS=".*"$' -- "$GRUB_PARAM_LINE"
        die "GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS is not a simple double-quoted single-line assignment. Refusing to rewrite it automatically."
    end
    set GRUB_PARAM_MATCH (string match -r '^GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS="(.*)"$' -- "$GRUB_PARAM_LINE")
    set GRUB_PARAM_VALUE $GRUB_PARAM_MATCH[2]
    if not string match -q '*rd.live.overlay.overlayfs=1*' -- "$GRUB_PARAM_VALUE"
        set GRUB_PARAM_VALUE "$GRUB_PARAM_VALUE rd.live.overlay.overlayfs=1"
    end
    if not string match -q '*snapper_snapshot_boot=1*' -- "$GRUB_PARAM_VALUE"
        set GRUB_PARAM_VALUE "$GRUB_PARAM_VALUE snapper_snapshot_boot=1"
    end
    # Rewrite only the single validated assignment. Avoid sed's delimiter and
    # shell-quoting pitfalls when the parameter value contains special chars.
    set GRUB_PARAM_TMP (mktemp); or die "Could not create a temporary GRUB-Btrfs config file."
    while read -l GRUB_LINE
        if string match -qr '^GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS=' -- "$GRUB_LINE"
            printf '%s\n' "GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS=\"$GRUB_PARAM_VALUE\"" >> $GRUB_PARAM_TMP
        else
            printf '%s\n' "$GRUB_LINE" >> $GRUB_PARAM_TMP
        end
    end < $GRUB_BTRFS_CONFIG
    chmod --reference=$GRUB_BTRFS_CONFIG $GRUB_PARAM_TMP 2>/dev/null
    chown --reference=$GRUB_BTRFS_CONFIG $GRUB_PARAM_TMP 2>/dev/null
    mv $GRUB_PARAM_TMP $GRUB_BTRFS_CONFIG; or begin
        rm -f $GRUB_PARAM_TMP
        die "Could not safely update the GRUB-Btrfs configuration."
    end
end

# Verify that the required parameters are present before generating GRUB.
set GRUB_PARAM_VERIFY (grep -E '^GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS=' $GRUB_BTRFS_CONFIG)
if not string match -q '*rd.live.overlay.overlayfs=1*' -- "$GRUB_PARAM_VERIFY"; or not string match -q '*snapper_snapshot_boot=1*' -- "$GRUB_PARAM_VERIFY"
    die "Verification failed: required GRUB-Btrfs snapshot kernel parameters are missing."
end

# 11. Install grub-btrfs overlayfs initramfs hook.
run_step "Configuring grub-btrfs OverlayFS hook..."
if not test -f /usr/lib/initcpio/hooks/grub-btrfs-overlayfs; or not test -f /usr/lib/initcpio/install/grub-btrfs-overlayfs
    die "grub-btrfs-overlayfs files are missing from the installed grub-btrfs package."
end

# Only modify an actual active HOOKS= assignment, never a commented example.
# The grub-btrfs documentation requires this hook at the end of HOOKS.
# Only edit an active single-line HOOKS= assignment; do not touch commented
# examples or silently rewrite an unusual/multiline configuration.
# Keep the parser deliberately strict: this installer only modifies the common
# single-line HOOKS=(...) form. A multiline/custom form is left untouched.
set HOOKS_LINE (grep -E '^HOOKS=' /etc/mkinitcpio.conf)
if test (count $HOOKS_LINE) -ne 1
    die "Could not safely determine the active HOOKS= line in /etc/mkinitcpio.conf. Please add grub-btrfs-overlayfs manually."
end

set HOOKS_TEXT (string replace -r '^HOOKS=' '' -- "$HOOKS_LINE[1]")
set HOOKS_TEXT (string replace -a '(' '' -- "$HOOKS_TEXT")
set HOOKS_TEXT (string replace -a ')' '' -- "$HOOKS_TEXT")
set HOOKS_TOKENS (string split ' ' -- (string trim -- "$HOOKS_TEXT"))

if not contains -- grub-btrfs-overlayfs $HOOKS_TOKENS
    if not string match -qr '\)[[:space:]]*$' -- "$HOOKS_LINE[1]"
        die "Could not safely modify HOOKS in /etc/mkinitcpio.conf. Add grub-btrfs-overlayfs manually to the end of the active HOOKS= line."
    end
    sed -i '/^HOOKS=/ s/)[[:space:]]*$/ grub-btrfs-overlayfs)/' /etc/mkinitcpio.conf
end

set HOOKS_LINE (grep -E '^HOOKS=' /etc/mkinitcpio.conf)
set HOOKS_TEXT (string replace -r '^HOOKS=' '' -- "$HOOKS_LINE[1]")
set HOOKS_TEXT (string replace -a '(' '' -- "$HOOKS_TEXT")
set HOOKS_TEXT (string replace -a ')' '' -- "$HOOKS_TEXT")
set HOOKS_TOKENS (string split ' ' -- (string trim -- "$HOOKS_TEXT"))

if not contains -- grub-btrfs-overlayfs $HOOKS_TOKENS
    die "Could not add grub-btrfs-overlayfs to HOOKS in /etc/mkinitcpio.conf."
end

# 11. Install the systemd fix discovered during snapshot-boot testing.
# Normal boot: systemd-remount-fs runs normally.
# Snapshot boot: grub-btrfs-overlayfs has already made / an OverlayFS root,
# so systemd must not try to reconfigure it from the original Btrfs fstab entry.
run_step "Installing systemd OverlayFS remount fix..."
mkdir -p /etc/systemd/system/systemd-remount-fs.service.d
set REMOUNT_DROPIN "/etc/systemd/system/systemd-remount-fs.service.d/snapshot-overlay.conf"
if test -f "$REMOUNT_DROPIN"
    set REMOUNT_LINES (cat "$REMOUNT_DROPIN")
    if test (count $REMOUNT_LINES) -ne 2; or test "$REMOUNT_LINES[1]" != '[Unit]'; or test "$REMOUNT_LINES[2]" != 'ConditionKernelCommandLine=!snapper_snapshot_boot=1'
        die "An existing systemd-remount-fs drop-in contains custom settings. Refusing to overwrite it."
    end
else
    printf '%s\n' '[Unit]' 'ConditionKernelCommandLine=!snapper_snapshot_boot=1' > "$REMOUNT_DROPIN"
end

# 12. Rebuild initramfs and GRUB.
run_step "Rebuilding initramfs..."
mkinitcpio -P; or die "mkinitcpio failed."

# Verify the hook was not merely written to mkinitcpio.conf but actually packed
# into every generated Arch initramfs that exists in /boot.
set INITRAMFS_IMAGES (string match -r '/boot/initramfs-.*\.img$' -- (find /boot -maxdepth 1 -type f -name 'initramfs-*.img' -print))
if test (count $INITRAMFS_IMAGES) -eq 0
    die "Verification failed: no generated initramfs image was found in /boot."
end
for IMG in $INITRAMFS_IMAGES
    if not lsinitcpio -a "$IMG" 2>/dev/null | grep -q 'grub-btrfs-overlayfs'
        die "Verification failed: grub-btrfs-overlayfs is missing from $IMG."
    end
end

run_step "Configuring grub-btrfs daemon..."
mkdir -p /etc/systemd/system/grub-btrfsd.service.d
set GRUB_BTRFSD_OVERRIDE "/etc/systemd/system/grub-btrfsd.service.d/override.conf"
if test -f "$GRUB_BTRFSD_OVERRIDE"
    set GRUB_BTRFSD_LINES (cat "$GRUB_BTRFSD_OVERRIDE")
    if test (count $GRUB_BTRFSD_LINES) -ne 3; or test "$GRUB_BTRFSD_LINES[1]" != '[Service]'; or test "$GRUB_BTRFSD_LINES[2]" != 'ExecStart='; or test "$GRUB_BTRFSD_LINES[3]" != 'ExecStart=/usr/bin/grub-btrfsd --syslog -s /.snapshots'
        die "An existing grub-btrfsd override.conf contains custom settings. Refusing to overwrite it."
    end
else
    printf '%s\n' '[Service]' 'ExecStart=' 'ExecStart=/usr/bin/grub-btrfsd --syslog -s /.snapshots' > "$GRUB_BTRFSD_OVERRIDE"
end

systemctl daemon-reload
systemctl enable --now grub-btrfsd; or die "Could not enable grub-btrfsd."

grub-mkconfig -o /boot/grub/grub.cfg; or die "GRUB configuration generation failed."

# 13. Install custom Fish function (arch snapshot).
set CALLER_USER $SUDO_USER
if test -z "$CALLER_USER"
    set CALLER_USER (logname 2>/dev/null)
end

if test -n "$CALLER_USER"; and test "$CALLER_USER" != root
    set USER_HOME (getent passwd $CALLER_USER | cut -d: -f6)
    set USER_GROUP (id -gn $CALLER_USER)
    if test -z "$USER_HOME"; or test -z "$USER_GROUP"
        echo " Warning: could not determine the login user home/group; skipping the user Fish function."
    else
        set FISH_FUNC_DIR "$USER_HOME/.config/fish/functions"
        set FISH_FUNC_DIR_CREATED 0
        if not test -d "$FISH_FUNC_DIR"
            mkdir -p "$FISH_FUNC_DIR"; or die "Could not create the Fish functions directory."
            set FISH_FUNC_DIR_CREATED 1
        end
        set ARCH_FUNC_FILE "$FISH_FUNC_DIR/arch.fish"
        set ARCH_FUNC_BACKUP "$FISH_FUNC_DIR/arch.fish.snapper-setup-$RUN_ID.backup"
        if test -f "$ARCH_FUNC_FILE"
            cp -a "$ARCH_FUNC_FILE" "$ARCH_FUNC_BACKUP"; or die "Could not back up the existing arch.fish function."
            set ARCH_FUNC_BACKUP_CREATED 1
        end

    echo " Installing 'arch snapshot' function for user $CALLER_USER..."

    printf '%s\n' \
        '# Generated by Snapper-Setup-Arch-Linux.' \
        'function arch --description "Arch Linux Snapshot Utility"' \
        '    set -l sub_command $argv[1]' \
        '' \
        '    switch "$sub_command"' \
        '        case snapshot' \
        '            set -l flag $argv[2]' \
        '            set -l args $argv[3..-1]' \
        '' \
        '            switch "$flag"' \
        '                case -l --list' \
        '                    echo " Listing all system snapshots..."' \
        '                    sudo snapper -c root list' \
        '' \
        '                case -d --delete' \
        '                    if test (count $args) -eq 0' \
        '                        echo " Error: Please specify at least one snapshot ID to delete."' \
        '                        echo " Usage: arch snapshot -d <id1> [id2 id3 ...]"' \
        '                        return 1' \
        '                    end' \
        '                    echo " Deleting snapshot ID(s): $args..."' \
        '                    for id in $args' \
        '                        echo "   - Deleting ID: $id"' \
        '                        if not sudo snapper -c root delete $id' \
        '                            echo " Error: Failed to delete snapshot ID: $id"' \
        '                            return 1' \
        '                        end' \
        '                    end' \
        '                    echo " Updating GRUB menu..."' \
        '                    if not sudo grub-mkconfig -o /boot/grub/grub.cfg' \
        '                        echo " Error: GRUB update failed."' \
        '                        return 1' \
        '                    end' \
        '' \
        '                case -h --help -help' \
        '                    echo " Arch Snapshot Utility"' \
        '                    echo "-------------------------------------"' \
        '                    echo "Usage:"' \
        '                    echo "  arch snapshot               : Create a manual snapshot"' \
        '                    echo "  arch snapshot -l            : List all snapshots"' \
        '                    echo "  arch snapshot -d <ID1> <ID2>: Delete multiple snapshots by ID"' \
        '                    echo "  arch snapshot -h | -help    : Show this help message"' \
        '' \
        '                case ""' \
        '                    set -l desc "Manual snapshot taken on "(date "+%Y-%m-%d %H:%M:%S")' \
        '                    echo " Creating manual snapshot..."' \
        '                    if sudo snapper -c root create --description "$desc"' \
        '                        if not sudo grub-mkconfig -o /boot/grub/grub.cfg' \
        '                            echo " Warning: snapshot was created, but GRUB update failed."' \
        '                            return 1' \
        '                        end' \
        '                        echo " Snapshot created successfully and GRUB was updated!"' \
        '                    else' \
        '                        echo " Error: Snapshot creation failed."' \
        '                        return 1' \
        '                    end' \
        '' \
        '                case "*"' \
        '                    echo " Unknown flag: $flag"' \
        '                    echo "Use '\''arch snapshot -h'\'' for help."' \
        '            end' \
        '' \
        '        case "*"' \
        '            echo " Unknown command: $sub_command"' \
        '            echo "Use '\''arch snapshot -h'\'' for help."' \
        '    end' \
        'end' > "$ARCH_FUNC_FILE"

        chown $CALLER_USER:$USER_GROUP "$ARCH_FUNC_FILE"; or die "Could not set ownership on the installed arch.fish function."
        set ARCH_FUNC_INSTALLED 1
        if test $FISH_FUNC_DIR_CREATED -eq 1
            chown $CALLER_USER:$USER_GROUP "$FISH_FUNC_DIR"; or die "Could not set ownership on the new Fish functions directory."
        end
    end
end
# 14. Create an initial snapshot only when this run created/reset the config.
if test "$CREATED_CONFIG" = 1
    run_step "Creating initial snapshot..."
    snapper -c root create --description "Initial Setup Snapshot"; or die "Could not create the initial snapshot."
else
    echo " Existing snapshots preserved; no extra initial snapshot was created."
end

# Final GRUB update after the initial snapshot so the new snapshot appears.
grub-mkconfig -o /boot/grub/grub.cfg; or die "Final GRUB configuration generation failed."

# 15. Verify the critical configuration.
run_step "Running verification..."
systemctl daemon-reload
# /boot must still be mounted consistently with the preflight check.
if test (count $BOOT_FSTAB_LINES) -eq 1; and not mountpoint -q /boot
    die "Verification failed: /boot is no longer mounted."
end
if not test -d /boot/grub
    die "Verification failed: /boot/grub is missing."
end


set VERIFY_HOOKS_LINE (grep -E '^HOOKS=' /etc/mkinitcpio.conf)
if test (count $VERIFY_HOOKS_LINE) -ne 1
    die "Verification failed: could not determine the active mkinitcpio HOOKS= line."
end
set VERIFY_HOOKS_TEXT (string replace -r '^HOOKS=' '' -- "$VERIFY_HOOKS_LINE[1]")
set VERIFY_HOOKS_TEXT (string replace -a '(' '' -- "$VERIFY_HOOKS_TEXT")
set VERIFY_HOOKS_TEXT (string replace -a ')' '' -- "$VERIFY_HOOKS_TEXT")
set VERIFY_HOOKS_TOKENS (string split ' ' -- (string trim -- "$VERIFY_HOOKS_TEXT"))
if not contains -- grub-btrfs-overlayfs $VERIFY_HOOKS_TOKENS
    die "Verification failed: grub-btrfs-overlayfs is not in the active mkinitcpio HOOKS."
end

if not test -f /etc/systemd/system/systemd-remount-fs.service.d/snapshot-overlay.conf
    die "Verification failed: systemd OverlayFS remount fix is missing."
end

if not grep -q '^ConditionKernelCommandLine=!snapper_snapshot_boot=1$' /etc/systemd/system/systemd-remount-fs.service.d/snapshot-overlay.conf
    die "Verification failed: systemd OverlayFS remount condition is incorrect."
end

if not systemctl is-active --quiet grub-btrfsd
    die "Verification failed: grub-btrfsd is not active."
end

# If snapshot entries exist in the generated menu, verify that they contain
# the required parameters. A completely empty snapshot menu is allowed in safe
# mode, because the user may legitimately have zero snapshots at install time.
if grep -q 'snapper_snapshot_boot=1' /boot/grub/grub.cfg
    # Verify both parameters occur inside the same GRUB menuentry block.
    # Checking the whole file could produce a false positive from unrelated entries.
    if not awk '
        /menuentry / {
            in_entry=1
            has_marker=0
            has_overlay=0
        }
        in_entry && /snapper_snapshot_boot=1/ { has_marker=1 }
        in_entry && /rd\.live\.overlay\.overlayfs=1/ { has_overlay=1 }
        in_entry && /^}/ {
            if (has_marker && has_overlay) found=1
            in_entry=0
        }
        END { exit(found ? 0 : 1) }
    ' /boot/grub/grub.cfg
        die "Verification failed: no single GRUB snapshot menuentry contains both required kernel parameters."
    end
else
    echo " Warning: no snapper_snapshot_boot=1 entry is currently present in grub.cfg. Create a snapshot and regenerate GRUB before testing snapshot boot."
end

if not mountpoint -q /.snapshots
    die "Verification failed: /.snapshots is not mounted."
end
set VERIFY_SNAP_MOUNT (findmnt -no FSTYPE,OPTIONS /.snapshots)
if not string match -qr '(^|,)subvol=/@snapshots($|,)' -- "$VERIFY_SNAP_MOUNT"
    die "Verification failed: /.snapshots is not mounted from the exact @snapshots subvolume."
end
set VERIFY_SNAP_UUID (findmnt -no UUID /.snapshots)
if test -z "$VERIFY_SNAP_UUID"; or test "$VERIFY_SNAP_UUID" != "$ROOT_UUID"
    die "Verification failed: /.snapshots is not on the same Btrfs filesystem as /. Refusing to report the installation as healthy."
end
set VERIFY_SNAP_FSTAB_LINES (grep -E '^[[:space:]]*[^#][^[:space:]]+[[:space:]]+/\.snapshots[[:space:]]+btrfs[[:space:]]' /etc/fstab)
if test (count $VERIFY_SNAP_FSTAB_LINES) -ne 1; or not string match -qr '(^|[[:space:],])subvol=/@snapshots([,[:space:]]|$)' -- "$VERIFY_SNAP_FSTAB_LINES[1]"
    die "Verification failed: /etc/fstab does not contain exactly one active /.snapshots entry using subvol=/@snapshots."
end

if not test -f /etc/snapper/configs/root
    die "Verification failed: Snapper root config is missing."
end
if not grep -qE '^SUBVOLUME="/"$' /etc/snapper/configs/root
    die "Verification failed: Snapper root config does not target /."
end

if string match -q '*snapper_snapshot_boot=1*' -- (cat /proc/cmdline)
    die "Verification failed: installer is running with snapshot-boot marker set. This must be a normal boot."
end

# Only after all critical checks pass do we remove the old snapshot-storage
# backup created by reset mode. If anything failed before this point, the old
# snapshot tree is still present and can be recovered manually.
if test "$INSTALL_MODE" = 2; and test -n "$RESET_BACKUP_SUBVOL"
    run_step "Removing the temporary old snapshot-storage backup..."
    # Do not mark cleanup as started until all non-destructive checks below
    # have succeeded. If mounting or validation fails, the rollback handler
    # can still restore the old snapshot tree.
    mkdir -p $BTRFS_MOUNT
    mount -o subvolid=5 $ROOT_DEV $BTRFS_MOUNT; or die "Could not mount Btrfs top-level to remove the temporary backup."
    # @snapshots is a parent subvolume containing the individual Snapper
    # snapshot subvolumes. Btrfs cannot delete the parent while child
    # subvolumes still exist, so remove children deepest-first.
    set BACKUP_PATH "$BTRFS_MOUNT/$RESET_BACKUP_SUBVOL"
    if not test -d "$BACKUP_PATH"
        umount "$BTRFS_MOUNT" 2>/dev/null
        rmdir "$BTRFS_MOUNT" 2>/dev/null
        die "The reset backup storage is missing. Refusing to delete anything."
    end
    if not btrfs subvolume show "$BACKUP_PATH" >/dev/null 2>&1
        umount "$BTRFS_MOUNT" 2>/dev/null
        rmdir "$BTRFS_MOUNT" 2>/dev/null
        die "The reset backup path is not a Btrfs subvolume. Refusing to delete anything."
    end
    if test (get_subvol_uuid "$BACKUP_PATH") != "$RESET_OLD_TREE_UUID"
        umount "$BTRFS_MOUNT" 2>/dev/null
        rmdir "$BTRFS_MOUNT" 2>/dev/null
        die "The reset backup UUID does not match the original snapshot tree. Refusing to delete anything."
    end
    set CHILD_SUBVOLS (btrfs subvolume list -o "$BACKUP_PATH" | awk '{print $NF}' | awk '{ print gsub("/", "/"), $0 }' | sort -rn | cut -d' ' -f2-)
    for CHILD in $CHILD_SUBVOLS
        if not string match -q "$RESET_BACKUP_SUBVOL/*" -- "$CHILD"
            umount "$BTRFS_MOUNT" 2>/dev/null
            rmdir "$BTRFS_MOUNT" 2>/dev/null
            die "An old snapshot child path escaped the reset backup tree. Refusing to delete anything."
        end
    end
    # Also prove that the live replacement tree is still the one created by
    # this run before any irreversible deletion of the old tree begins.
    if not test -d "$BTRFS_MOUNT/@snapshots"; or test (get_subvol_uuid "$BTRFS_MOUNT/@snapshots") != "$RESET_NEW_TREE_UUID"
        umount "$BTRFS_MOUNT" 2>/dev/null
        rmdir "$BTRFS_MOUNT" 2>/dev/null
        die "The live @snapshots subvolume is no longer the replacement tree created by this run. Refusing to delete the old snapshot backup."
    end
    # The first child deletion is the first irreversible operation. From this
    # point onward, automatic rollback is intentionally disabled.
    set RESET_CLEANUP_STARTED 1
    for CHILD in $CHILD_SUBVOLS
        btrfs subvolume delete "$BTRFS_MOUNT/$CHILD"; or begin
            umount $BTRFS_MOUNT 2>/dev/null
            rmdir $BTRFS_MOUNT 2>/dev/null
            die "Setup succeeded, but an old snapshot-storage child could not be removed. The old backup may be partially deleted; automatic rollback is disabled. Inspect the backup before removing it."
        end
    end

    btrfs subvolume delete "$BACKUP_PATH"; or begin
        umount $BTRFS_MOUNT 2>/dev/null
        rmdir $BTRFS_MOUNT 2>/dev/null
        die "Setup succeeded, but the old snapshot-storage backup container could not be removed. Its contents were already processed; inspect the path manually before removing it."
    end

    # The old snapshot tree is now permanently gone. The reset is committed;
    # failures after this point must not attempt to reconstruct it automatically.
    # From here on, recovery means manual inspection of the remaining system
    # configuration/backups, not automatic restoration of deleted snapshots.
    set RESET_COMMITTED 1
    umount $BTRFS_MOUNT; or die "Could not unmount the temporary Btrfs mount after reset commit."
    rmdir $BTRFS_MOUNT 2>/dev/null
end

if test "$INSTALL_MODE" = 2; and test "$RESET_COMMITTED" -eq 1
    if test $RESTART_TIMELINE_TIMER -eq 1
        if not systemctl start snapper-timeline.timer
            echo " Warning: reset succeeded, but snapper-timeline.timer could not be restarted."
        end
    end
    if test $RESTART_CLEANUP_TIMER -eq 1
        if not systemctl start snapper-cleanup.timer
            echo " Warning: reset succeeded, but snapper-cleanup.timer could not be restarted."
        end
    end
end

# The installer is now fully verified. Prevent exit handlers from rolling back
# the successfully installed Fish function or reset state.
set INSTALL_COMMITTED 1

# A successful reset no longer needs the old Snapper config backup. Keep the
# backup during installation so it remains available if anything fails.
if test "$INSTALL_MODE" = 2; and test "$RESET_COMMITTED" -eq 1
    rm -f "$SNAPPER_CONFIG_BACKUP" "$SNAP_CONF_BACKUP" "$SNAP_SYS_BACKUP" "$REMOUNT_DROPIN_BACKUP" "$GRUB_BTRFSD_OVERRIDE_BACKUP"
end

if mountpoint -q "$BTRFS_MOUNT"
    umount "$BTRFS_MOUNT" 2>/dev/null
end
rmdir "$BTRFS_MOUNT" 2>/dev/null

echo ""
echo "=============================================="
echo " Snapper setup completed successfully"
echo "=============================================="
echo " Mode: $INSTALL_MODE"
echo " Existing snapshots preserved: "(test "$INSTALL_MODE" = 1; and echo yes; or echo no)
echo " OverlayFS snapshot-boot fix: installed"
echo " grub-btrfs-overlayfs initramfs hook: installed"
echo " /.snapshots: mounted"
echo ""
echo " Test normal boot with:"
echo "   systemctl --failed"
echo ""
echo " Then boot a GRUB-Btrfs snapshot and run the same command."
echo " Expected result: 0 loaded units listed."
echo ""
echo " WARNING: Reset mode permanently deletes all Snapper snapshots."
echo "=============================================="
