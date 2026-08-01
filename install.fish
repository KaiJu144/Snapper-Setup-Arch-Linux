#!/usr/bin/env fish

# ===========================================
# Btrfs + Snapper Setup Script for Arch Linux
# ===========================================

echo " Starting Automated Snapper & GRUB-Btrfs Setup..."

# 1. Check Root Privileges
if test (id -u) -ne 0
    echo " Error: Please run this script with sudo."
    exit 1
end

# 2. Detect Root Drive Partition & UUID
set ROOT_DEV (df -P / | tail -n1 | awk '{print $1}')
set ROOT_UUID (blkid -s UUID -o value $ROOT_DEV)

if test -z "$ROOT_DEV" -o -z "$ROOT_UUID"
    echo " Error: Could not detect Root Partition or UUID."
    exit 1
end

echo " Detected Root Partition: $ROOT_DEV (UUID: $ROOT_UUID)"

# 3. Install Required Packages
echo " Installing required packages (snapper, snap-pac, grub-btrfs, inotify-tools)..."
pacman -S --needed --noconfirm snapper snap-pac grub-btrfs inotify-tools

# 4. Cleanup any existing stale configurations
echo " Cleaning up stale snapper configurations..."
umount -l /.snapshots 2>/dev/null
rm -rf /etc/snapper/configs/*
rm -f /etc/snapper/snapper-configs
rm -f /etc/sysconfig/snapper

# 5. Safely Create Btrfs Subvolume @snapshots at Root Level
echo " Creating Btrfs subvolume /@snapshots..."
mkdir -p /mnt/btrfs-root
mount -o subvolid=5 $ROOT_DEV /mnt/btrfs-root
if not test -d /mnt/btrfs-root/@snapshots
    btrfs subvolume create /mnt/btrfs-root/@snapshots
end
umount /mnt/btrfs-root
rmdir /mnt/btrfs-root
mkdir -p /.snapshots

# 6. Mount Subvolume
echo " Mounting /@snapshots to /.snapshots..."
mount -o subvol=@snapshots $ROOT_DEV /.snapshots

# 7. Update /etc/fstab (If not already added)
if not grep -q "/.snapshots" /etc/fstab
    echo " Updating /etc/fstab..."
    echo "UUID=$ROOT_UUID	/.snapshots	btrfs	rw,relatime,ssd,discard=async,space_cache=v2,subvol=/@snapshots	0 0" >>/etc/fstab
    systemctl daemon-reload
    mount -a
else
    echo "  /.snapshots entry already exists in /etc/fstab."
end

# 8. Create Manual Snapper Root Config
echo "  Configuring Snapper for / ..."
mkdir -p /etc/snapper/configs

echo 'SUBVOLUME="/"
FSTYPE="btrfs"
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS=""
ALLOW_GROUPS=""
SYNC_ACL="no"
GENERATE_CLEANUP="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="50"
NUMBER_LIMIT_IMPORTANT="10"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="10"
TIMELINE_LIMIT_DAILY="10"
TIMELINE_LIMIT_WEEKLY="0"
TIMELINE_LIMIT_MONTHLY="0"
TIMELINE_LIMIT_YEARLY="0"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"' >/etc/snapper/configs/root

echo 'SNAPPER_CONFIGS="root"' >/etc/snapper/snapper-configs
chmod 750 /.snapshots

# 9. Configure & Enable grub-btrfsd service
echo " Configuring and Enabling grub-btrfsd service..."
mkdir -p /etc/systemd/system/grub-btrfsd.service.d/
echo '[Service]
ExecStart=
ExecStart=/usr/bin/grub-btrfsd --syslog -s /.snapshots' > /etc/systemd/system/grub-btrfsd.service.d/override.conf

systemctl daemon-reload
systemctl enable --now grub-btrfsd

# 10. Install Custom Fish Function (`arch snapshot`)
set CALLER_USER $SUDO_USER
if test -z "$CALLER_USER"
    set CALLER_USER (logname 2>/dev/null)
end

if test -n "$CALLER_USER"
    set USER_HOME (getent passwd $CALLER_USER | cut -d: -f6)
    set FISH_FUNC_DIR "$USER_HOME/.config/fish/functions"
    mkdir -p $FISH_FUNC_DIR

    echo " Installing 'arch snapshot' function for user $CALLER_USER..."

    # Write arch.fish with grub-mkconfig auto-update on delete
    printf '%s\n' \
        'function arch --description "Arch Linux Snapshot Utility"' \
        '    set -l sub_command $argv[1]' \
        '' \
        '    switch "$sub_command"' \
        '        case snapshot' \
        '            set -l flag $argv[2]' \
        '            set -l arg $argv[3]' \
        '' \
        '            switch "$flag"' \
        '                case -l --list' \
        '                    echo " Listing all system snapshots..."' \
        '                    sudo snapper -c root list' \
        '' \
        '                case -d --delete' \
        '                    if test -z "$arg"' \
        '                        echo " Error: Please specify a snapshot ID to delete."' \
        '                        echo " Usage: arch snapshot -d <snapshot_id>"' \
        '                        return 1' \
        '                    end' \
        '                    echo " Deleting snapshot ID: $arg..."' \
        '                    sudo snapper -c root delete $arg' \
        '                    echo " Updating GRUB menu..."' \
        '                    sudo grub-mkconfig -o /boot/grub/grub.cfg' \
        '' \
        '                case -h --help -help' \
        '                    echo " Arch Snapshot Utility"' \
        '                    echo "-------------------------------------"' \
        '                    echo "Usage:"' \
        '                    echo "  arch snapshot            : Create a manual snapshot"' \
        '                    echo "  arch snapshot -l         : List all snapshots"' \
        '                    echo "  arch snapshot -d <ID>    : Delete snapshot by ID"' \
        '                    echo "  arch snapshot -h | -help : Show this help message"' \
        '' \
        '                case ""' \
        '                    set -l desc "Manual snapshot taken on "(date "+%Y-%m-%d %H:%M:%S")' \
        '                    echo " Creating manual snapshot..."' \
        '                    sudo snapper -c root create --description "$desc"' \
        '                    echo " Snapshot created successfully!"' \
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
        'end' > $FISH_FUNC_DIR/arch.fish

    chown -R $CALLER_USER:(id -gn $CALLER_USER) $FISH_FUNC_DIR/arch.fish
end

# 11. Create First Snapshot & Update GRUB
echo " Creating initial snapshot..."
snapper -c root create --description "Initial Setup Snapshot"

echo " Updating GRUB menu..."
grub-mkconfig -o /boot/grub/grub.cfg

echo "
 All Done! Snapper setup is complete without errors!
 You can now use 'arch snapshot' in your terminal.
"
