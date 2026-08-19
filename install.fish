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

# 3. Pre-create configuration files to prevent pacman/snap-pac hooks from breaking
mkdir -p /etc/conf.d /etc/sysconfig
echo 'SNAPPER_CONFIGS=""' > /etc/conf.d/snapper
echo 'SNAPPER_CONFIGS=""' > /etc/sysconfig/snapper

# 4. Install Required Packages
echo " Installing required packages (snapper, snap-pac, grub-btrfs, inotify-tools)..."
pacman -S --needed --noconfirm snapper snap-pac grub-btrfs inotify-tools

# 5. Cleanup any existing stale configurations safely (Avoid Fish Wildcard Error)
echo " Cleaning up stale snapper configurations..."
umount -l /.snapshots 2>/dev/null
rm -rf /.snapshots
rm -rf /etc/snapper/configs

# 6. Safely Create Btrfs Subvolume @snapshots at Root Level
echo " Creating Btrfs subvolume /@snapshots..."
mkdir -p /mnt/btrfs-root
mount -o subvolid=5 $ROOT_DEV /mnt/btrfs-root
if not test -d /mnt/btrfs-root/@snapshots
    btrfs subvolume create /mnt/btrfs-root/@snapshots
end
umount /mnt/btrfs-root
rmdir /mnt/btrfs-root

# 7. Initialize Snapper Config (Let Snapper create initial config)
echo "  Configuring Snapper for / ..."
snapper -c root create-config /

# 8. Swap /.snapshots with our Btrfs @snapshots subvolume
echo " Mounting /@snapshots to /.snapshots..."
umount /.snapshots 2>/dev/null
rm -rf /.snapshots
mkdir -p /.snapshots
mount -o subvol=@snapshots $ROOT_DEV /.snapshots

if not grep -q "/.snapshots" /etc/fstab
    echo " Updating /etc/fstab..."
    echo "UUID=$ROOT_UUID	/.snapshots	btrfs	rw,relatime,ssd,discard=async,space_cache=v2,subvol=/@snapshots	0 0" >>/etc/fstab
    systemctl daemon-reload
    mount -a
else
    echo "  /.snapshots entry already exists in /etc/fstab."
end

# 9. Set Arch Config Files & Permissions
echo 'SNAPPER_CONFIGS="root"' > /etc/conf.d/snapper
echo 'SNAPPER_CONFIGS="root"' > /etc/sysconfig/snapper
chmod 750 /.snapshots

# 10. Configure & Enable grub-btrfsd service
echo " Configuring and Enabling grub-btrfsd service..."
mkdir -p /etc/systemd/system/grub-btrfsd.service.d/
echo '[Service]
ExecStart=
ExecStart=/usr/bin/grub-btrfsd --syslog -s /.snapshots' > /etc/systemd/system/grub-btrfsd.service.d/override.conf

systemctl daemon-reload
systemctl enable --now grub-btrfsd

# 11. Install Custom Fish Function (`arch snapshot`)
set CALLER_USER $SUDO_USER
if test -z "$CALLER_USER"
    set CALLER_USER (logname 2>/dev/null)
end

if test -n "$CALLER_USER"
    set USER_HOME (getent passwd $CALLER_USER | cut -d: -f6)
    set FISH_FUNC_DIR "$USER_HOME/.config/fish/functions"
    mkdir -p $FISH_FUNC_DIR

    echo " Installing 'arch snapshot' function for user $CALLER_USER..."

    printf '%s\n' \
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
        '                        sudo snapper -c root delete $id' \
        '                    end' \
        '                    echo " Updating GRUB menu..."' \
        '                    sudo grub-mkconfig -o /boot/grub/grub.cfg' \
        '' \
        '                case -h --help -help' \
        '                    echo " Arch Snapshot Utility"' \
        '                    echo "-------------------------------------"' \
        '                    echo "Usage:"' \
        '                    echo "  arch snapshot               : Create a manual snapshot"' \
        '                    echo "  arch snapshot -l            : List all snapshots"' \
        '                    echo "  arch snapshot -d <ID1> <ID2>: Delete multiple snapshots by ID"' \
        '                    echo "  arch snapshot -d (seq 1 15) : Delete snapshots from ID 1 to 15"' \
        '                    echo "  arch snapshot -h | -help    : Show this help message"' \
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

# 12. Create First Snapshot & Update GRUB
echo " Creating initial snapshot..."
snapper -c root create --description "Initial Setup Snapshot"

echo " Updating GRUB menu..."
grub-mkconfig -o /boot/grub/grub.cfg

echo "
 All Done! Snapper setup is complete without errors!
 You can now use 'arch snapshot' in your terminal.
"
