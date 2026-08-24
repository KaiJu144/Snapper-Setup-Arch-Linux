# Btrfs Snapshot Setup guide for Arch Linux (Fish Shell)

A simple **Btrfs Snapshot** system installation and setup guide for **Arch Linux** along with **Snapper**, **GRUB** and **Fish Shell**.

This system allows you to:
- Take snapshots with a few commands via Fish Shell (`arch snapshot`)
- Automatically create snapshots before and after system updates with `pacman`.
- Select Boot to past snapshots directly from the **GNU GRUB** page.

---

## Prerequisites

- Arch Linux operating system uses **Btrfs** as the Root File System (`/`)
- Use **GRUB** as Bootloader.
- Use **Fish Shell** as the main shell.

---

> [!WARNING]
> ## Important Precautions & Warnings (Save User)
> 
> <details><summary>Warning</summary>
> 
> ### 1. Prohibitions for Rollback (most important!)
> 
> - **Don't use** `snapper rollback` **directly from the base OS**:
> 
>   - On Arch Linux using the Btrfs subvolume (`@` and `/@snapshots`) layout, running the `snapper rollback` command directly while booting normally will result in the main subvolume crashing or a Kernel Panic on the next boot!
>   
>   - **How to Rollback Correctly**:
>   
>     1. Reboot the machine and select Boot into the desired Snapshot via **GRUB Menu** (`Arch Linux snapshots`).
>     
>     2. Once temporarily logged in via Snapshot, open Terminal and run the command:
>     
>       ```sh
>       sudo snapper rollback
>       ```
>       
>      1. Then reboot the machine again to return to the main system that has already rolled back.
> ---
> 
>  ### 2. Warning about lost files and data (**Data Loss Warning**)
>  
>  - **Rollback returns only Root** (`/`):
>  
>    - All Root Partition data (including Package, Configuration in `/etc`) will revert to the Snapshot date.
>    
>    - **If** `/home` **is not separated into a separate subvolume (for example,** `/home` **is included with** `/`**): all your personal files, documents, or desktop files will be sent back in time!**
>    
>    - **Tip**: Always backup important data in `/home` externally or separate Subvolume `@home` before running this script.
> ---
>    
>   ### 3. Disk space is full (Disk Space & Subvolume Maintenance)
>    
>  - **Deleting large files Doesn't help free up space immediately:**
>    
>    - On Btrfs if you delete large files in the system But the file is still saved in the old Snapshot. Disk space will not be regained.
>    
>    - If the disk is so full that Btrfs becomes Read-Only, delete the old Snapshot with the command:
>      ```sh
>      arch snapshot -d <ID_to be deleted>
>      ```
> ---
>    
>    ### 4. When Kernel or GRUB is updated
>    
>    - After a major system update (e.g. `pacman -Syu` with a Linux Kernel update), the `grub-btrfsd` service will automatically sync the Snapshots menu in GRUB.
>    
>    - If you opened GRUB and couldn't find the latest snapshot, you can manually create a new GRUB menu:
>      ```sh
>      sudo grub-mkconfig -o /boot/grub/grub.cfg
>      ```
> ---
> ### 5. Problem with `arch snapshot` function: can't find it.
> 
> - If you type `arch snapshot` and Shell says `command not found`:
> 
> - Check if the current user has **Fish Shell** enabled.
> 
> - Run the command to load the new config: `source ~/.config/fish/config.fish`
> 
>   ```sh
>   source ~/.config/fish/config.fish
>   ```
>   
>   - Check permissions of function file: `ls -l ~/.config/fish/functions/arch.fish` (must be Owner of that user)
> ---
> 
> </details>

## Installation Automated & (Step-by-Step)

<details><summary>Important to know</summary>

> **Important:** `install.fish` changes system configuration files, initramfs, GRUB, Snapper configuration, mounts, and Btrfs snapshot storage. Read this section before running it.
>
> This installer is intended for an **already-installed Arch Linux system using Btrfs for `/` and GRUB as the bootloader**. It is not an Arch Linux installation script and should not be run from the Arch ISO/chroot unless you specifically know that the target system is correctly mounted and bootable.

---

</details>

<details><summary>Step 1: Requirements</summary>

### Step 1: Requirements

Before starting, make sure:

- You are booted into the **normal installed Arch Linux system**.
- `/` is on **Btrfs**.
- The system uses **GRUB**.
- `fish` is installed.
- `sudo` works for your user.
- You have enough free Btrfs space for snapshots.
- You have a working internet connection if the installer needs to install missing packages.
- You have a way to recover the machine if a boot configuration change fails (for example, an Arch ISO/USB).

Check the most important conditions:

```sh
findmnt -no FSTYPE /
```

```sh
findmnt /
```

```sh
bootctl status
```

```sh
sudo grub-install --version
```

```sh
fish --version
```

The first command `findmnt -no FSTYPE /` should report:

```
btrfs
```

If `/` is not Btrfs, **do not continue**.

---

</details>

<details><summary>Step 2: Get the repository</summary>

### Step 2: Get the repository

Clone the repository:

```sh
git clone https://github.com/KaiJu144/Snapper-Setup-Arch-Linux.git
```

```sh
cd Snapper-Setup-Arch-Linux
```

If you already cloned it:

```sh
cd Snapper-Setup-Arch-Linux
git pull
```

Check that the installer exists:

```sh
ls -l ./install.fish
```

Make it executable if necessary:

```sh
chmod +x ./install.fish
```
---

</details>

<details><summary>Step 3: Check the installer before running it</summary>

### Step 3: Check the installer before running it

The installer is written for Fish.

First perform a syntax-only check:

```sh
fish -n ./install.fish
```

If there is **no output**, Fish accepted the syntax.

You can also verify the exit status:

```sh
echo $status
```

Expected result:

```
0
```

**Do not continue if the syntax check reports an error.**

---

</details>

<details><summary>Step 4: Choose the installation mode</summary>

### Step 4: Choose the installation mode

Run:

```sh
sudo ./install.fish
```

The installer provides two modes.

#### Option 1 — Normal installation / keep existing snapshot numbering

Choose this when you want to keep your existing Snapper snapshots.

This mode is the recommended choice for an existing installation because it does **not intentionally delete the existing snapshot history just to make the numbering start at `#1` again**.

It installs/configures the Snapper + GRUB-Btrfs integration and includes the fixes needed for booting snapshots through the GRUB-Btrfs OverlayFS mechanism.

Use this mode when:

- you already have useful snapshots;
- you want to preserve snapshot history;
- you do not care that the next snapshot number is greater than `#1`;
- you are upgrading/fixing an existing Snapper setup.

**Recommended for most existing systems: Option 1.**

#### Option 2 — Reset snapshot numbering

Choose this only if you explicitly want to start the Snapper snapshot storage over so that the new snapshot history can begin again from a low number.

This mode is destructive to the **old snapshot history** after the reset has been successfully committed.

Before selecting it:

1. Make sure you do not need the old snapshots.
2. If you may need them later, copy/export them first.
3. Make sure you have a recovery USB available.
4. Do not interrupt the machine while the reset is being performed.

The reset mode is designed to avoid deleting the old snapshot tree before the new setup is ready. It also keeps temporary recovery information while the operation is in progress.

**Do not choose Option 2 simply because the snapshot number is large.** Snapshot numbers are identifiers; a high number does not mean the system is broken.

---

</details>

<details><summary>Step 5: What the installer configures</summary>

### Step 5: What the installer configures

Depending on the selected mode, the installer configures the Snapper root setup and the GRUB-Btrfs integration.

The important boot-related pieces include:

- the Snapper root configuration;
- the `@snapshots` Btrfs snapshot storage;
- the `/.snapshots` mount;
- `grub-btrfs-overlayfs` in the active `mkinitcpio` `HOOKS=...` line;
- the GRUB-Btrfs snapshot kernel parameter;
- the OverlayFS remount condition used when booting a snapshot;
- `grub-btrfsd`;
- regenerated initramfs images;
- regenerated `/boot/grub/grub.cfg`;
- Snapper timeline/cleanup services where applicable.

The OverlayFS remount condition is intentionally:

```ini
[Unit]
ConditionKernelCommandLine=!snapper_snapshot_boot=1
```

This prevents `systemd-remount-fs.service` from incorrectly remounting the snapshot boot environment when `snapper_snapshot_boot=1` is present.

### 6. Let the installer finish completely

Do not reboot while the installer is still running.

The installer may perform operations such as:

```
mkinitcpio
grub-mkconfig
systemctl daemon-reload
systemctl enable/start grub-btrfsd
```

Wait until the installer reports that installation/verification completed successfully.

If the installer stops with an error, **do not immediately rerun it repeatedly**. Read the error first and check the state of the system.

---

</details>

<details><summary>Step 7: Verify the installation after it finishes</summary>

### Step 7: Verify the installation after it finishes

Check the active root filesystem:

```sh
findmnt /
```

Check that the snapshot mount exists:

```sh
findmnt /.snapshots
```

Check Snapper:

```sh
sudo snapper -c root list
```

Check the GRUB-Btrfs daemon:

```sh
systemctl status grub-btrfsd --no-pager
```

Check for failed systemd units:

```sh
systemctl --failed
```

A healthy result is:

```
0 loaded units listed.
```

---

</details>

<details><summary>Step 8: Verify the initramfs hook</summary>

### Step 8: Verify the initramfs hook

Check the active `HOOKS=` line:

```sh
grep '^HOOKS=' /etc/mkinitcpio.conf
```

It must contain:

```
grub-btrfs-overlayfs
```

Then rebuild the initramfs manually if you want an additional verification:

```sh
sudo mkinitcpio -P
```

A successful build should reach:

```
Initcpio image generation successful
```

A warning such as:

```
consolefont: no font found in configuration
```

is not by itself a Snapper/GRUB-Btrfs failure if the initramfs build completes successfully.

---

</details>

<details><summary>Step 9: Verify GRUB snapshot entries</summary>

### Step 9: Verify GRUB snapshot entries

Regenerate GRUB:

```sh
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

During generation, GRUB-Btrfs should detect the available snapshots.

You should see output similar to:

```
Detecting snapshots ...
Found snapshot: ...
```

The exact snapshot numbers and descriptions will depend on your system.

---

</details>

<details><summary>Test creating a snapshot</summary>

### Test creating a snapshot

Create a manual snapshot using the project's helper if it is installed:

```sh
arch snapshot
```

Then list snapshots:

```sh
arch snapshot -l
```

Alternatively, use Snapper directly:

```sh
sudo snapper -c root create --description "Installation test"
```

```sh
sudo snapper -c root list
```

Confirm that the new snapshot appears.

---

</details>

<details><summary>Test booting a snapshot</summary>

### Test booting a snapshot

Before testing, make sure you have saved your work.

Reboot:

```sh
sudo reboot
```

At the GRUB menu, look for the **GRUB-Btrfs snapshot submenu**.

Select a known-good snapshot.

The snapshot boot should use the OverlayFS mechanism configured by the installer. The booted snapshot should be usable for testing without modifying the read-only snapshot itself.

After booting, check:

```sh
cat /proc/cmdline
```

When booted through the snapshot entry, the command line should contain:

```
snapper_snapshot_boot=1
```

Also check:

```sh
findmnt /
```

A snapshot boot using the OverlayFS setup can show `/` as an `overlay` filesystem. This is expected for the snapshot-boot path.

---

</details>

<details><summary>If the system boots normally but systemctl --failed is clean</summary>

### If the system boots normally but `systemctl --failed` is clean

That is a good sign.

For example:

```sh
systemctl --failed
```

returning:

```
0 loaded units listed.
```

means systemd currently has no failed units.

It is still recommended to test an actual snapshot boot before considering the GRUB-Btrfs setup fully tested.

---

</details>

<details><summary>If you choose the reset mode</summary>

### If you choose the reset mode

After a successful reset:

```sh
sudo snapper -c root list
```

should show the new snapshot history.

Do **not** manually delete random Btrfs subvolumes to force the numbering lower.

If reset mode fails before its cleanup/commit phase, the installer is designed to keep the old snapshot storage available for recovery where possible.

If reset mode has already reached its final cleanup phase, automatic rollback is intentionally not attempted because the old snapshot tree may already be partially removed.

---

</details>

<details><summary>Important safety notes</summary>

### Important safety notes

#### Do not manually delete `@snapshots`

The project uses a dedicated Btrfs snapshot storage layout. Do not run commands such as:

```sh
sudo btrfs subvolume delete /...
```

unless you know exactly which subvolume is being removed.

#### Do not delete `/.snapshots` blindly

`/.snapshots` is a mount point used by Snapper. It is not necessarily the actual snapshot-storage subvolume.

Always inspect first:

```sh
findmnt /.snapshots
sudo btrfs subvolume list /
```

#### Do not use reset mode just to fix a high snapshot number

A high snapshot number is normal. Use Option 2 only when you intentionally want to discard the old snapshot history.

#### Keep a recovery medium

Any script that changes initramfs and bootloader configuration has an inherent boot-recovery risk. Keep an Arch ISO/USB available.

---

</details>

<details><summary>Quick post-install checklist</summary>

### Quick post-install checklist

Run:

```sh
findmnt -no FSTYPE /
```

```sh
findmnt /.snapshots
```

```sh
sudo snapper -c root list
```

```sh
systemctl --failed
```

```sh
systemctl is-active grub-btrfsd
```

```sh
grep '^HOOKS=' /etc/mkinitcpio.conf
```

```sh
grep -n 'snapper_snapshot_boot' /etc/default/grub-btrfs/config
```

Expected:

- `/` → `btrfs`
- `/.snapshots` → mounted
- Snapper → lists snapshots
- `systemctl --failed` → no failed units
- `grub-btrfsd` → `active`
- `HOOKS=` → contains `grub-btrfs-overlayfs`
- GRUB-Btrfs configuration → contains `snapper_snapshot_boot=1`

---

</details>

<details><summary>Troubleshooting</summary>

### Troubleshooting

If the syntax check fails:

```sh
fish -n ./install.fish
```

Fix the reported Fish syntax error before executing the installer.

If `mkinitcpio` fails:

```sh
sudo mkinitcpio -P
```

Read the first actual `ERROR:` message. Do not treat an unrelated warning as the failure.

If GRUB does not show snapshots:

```sh
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

```sh
systemctl status grub-btrfsd --no-pager
```

```sh
sudo snapper -c root list
```

If snapshot boot reaches the system but produces systemd remount-related failures, verify:

```sh
sudo cat /etc/systemd/system/systemd-remount-fs.service.d/snapshot-overlay.conf
```

It should contain exactly:

```ini
[Unit]
ConditionKernelCommandLine=!snapper_snapshot_boot=1
```

Then:

```sh
sudo systemctl daemon-reload
```

and rebuild the initramfs/GRUB configuration if required.

---

</details>

<details><summary>Recommended workflow</summary>

### Recommended workflow

For a normal existing system:

```
Clone/update repository
        ↓
fish -n ./install.fish
        ↓
./install.fish
        ↓
Choose Option 1
        ↓
Wait for verification to finish
        ↓
Check systemctl --failed
        ↓
Check Snapper
        ↓
Check GRUB snapshot entries
        ↓
Reboot
        ↓
Test a known-good snapshot
```

For intentionally starting snapshot history over:

```
Backup anything important
        ↓
Clone/update repository
        ↓
fish -n ./install.fish
        ↓
./install.fish
        ↓
Choose Option 2
        ↓
Confirm that old snapshots may be removed
        ↓
Wait for reset + verification
        ↓
Check Snapper
        ↓
Check GRUB
        ↓
Reboot
        ↓
Create/test a new snapshot
```

> **Final recommendation:** If you are unsure which option to choose, use **Option 1**. Preserving existing snapshots is safer than resetting the snapshot history.

---

</details>

## Installation Manually & (Step-by-Step)

<details><summary>Important to know</summary>

This section describes how to install the same Snapper + GRUB-Btrfs + OverlayFS setup used by this project **without running `install.fish`**.

> [!IMPORTANT]
> This guide is for an **already-installed Arch Linux system** whose `/` is on **Btrfs** and whose bootloader is **GRUB**. It is not an Arch Linux installation/chroot guide.

> [!WARNING]
> This procedure changes `/etc/fstab`, Snapper configuration, `mkinitcpio`, GRUB-Btrfs configuration, initramfs, and the GRUB menu. Keep an Arch ISO/USB recovery medium available and back up important data first.

---

</details>

<details><summary>Step 1: Verify prerequisites</summary>

### Step 1: Verify prerequisites

Boot into the **normal installed Arch Linux system**, not a snapshot.

Check `/`:

```sh
findmnt -no FSTYPE /
```

Expected:

```
btrfs
```

Check the root mount:

```sh
findmnt /
```

Check GRUB:

```sh
grub-install --version
```

Check Fish:

```sh
fish --version
```

If `/` is not Btrfs or GRUB is not your bootloader, **stop here**.

---

</details>

<details><summary>Step 2: Install required packages</summary>

### Step 2: Install required packages

```sh
sudo pacman -S snapper snap-pac grub-btrfs btrfs-progs
```

If Fish is not installed:

```sh
sudo pacman -S fish
```

---

</details>

<details><summary>Step 3: Create a top-level @snapshots subvolume</summary>

### Step 3: Create `@snapshots` in the correct Btrfs hierarchy

This project expects `@snapshots` to be a **top-level Btrfs subvolume**, alongside the root subvolume.

Do **not** blindly run:

```sh
sudo btrfs subvolume create /@snapshots
```

when `/` itself is a subvolume such as `@`; that can create a subvolume nested inside the root.

Find the device containing `/`:

```sh
findmnt -no SOURCE /
```

Example:

```
/dev/nvme0n1p2[/@]
```

The underlying device is `/dev/nvme0n1p2`.

Create a temporary top-level mount:

```sh
sudo mkdir -p /mnt/btrfs-top
```

Mount Btrfs top level:

```sh
sudo mount -o subvolid=5 "$(findmnt -no SOURCE / | sed 's/\[.*\]//')" /mnt/btrfs-top
```

Inspect the layout:

```sh
sudo btrfs subvolume list /mnt/btrfs-top
```

If `@snapshots` does not already exist, create it:

```sh
sudo btrfs subvolume create /mnt/btrfs-top/@snapshots
```

If it already exists, **do not create another one**.

Unmount:

```sh
sudo umount /mnt/btrfs-top
```

```sh
sudo rmdir /mnt/btrfs-top
```

> [!IMPORTANT]
> `@snapshots` should be a sibling of the root subvolume in the Btrfs top-level tree, not a child of the root subvolume.

---

</details>

<details><summary>Step 4: Mount @snapshots at /.snapshots and make it persistent</summary>

### Step 4: Mount `@snapshots` at `/.snapshots`

Create the mount point:

```sh
sudo mkdir -p /.snapshots
```

Mount it:

```sh
sudo mount -o subvol=/@snapshots "$(findmnt -no SOURCE / | sed 's/\[.*\]//')" /.snapshots
```

Verify:

```sh
findmnt /.snapshots
```

Get the Btrfs filesystem UUID:

```sh
findmnt -no UUID /
```

Edit `/etc/fstab`:

```sh
sudo nano /etc/fstab
```

or:

```sh
sudo nvim /etc/fstab
```

Add **one** `/.snapshots` entry:

```
UUID=YOUR_ROOT_BTRFS_UUID  /.snapshots  btrfs  rw,relatime,ssd,discard=async,space_cache=v2,subvol=/@snapshots  0 0
```

Replace `YOUR_ROOT_BTRFS_UUID` with the UUID from `findmnt -no UUID /`.

> [!IMPORTANT]
> Do not leave duplicate `/.snapshots` entries in `/etc/fstab`.

Reload and test:

```sh
sudo systemctl daemon-reload
```

```sh
sudo mount -a
```

Then:

```sh
findmnt /.snapshots
```

If `mount -a` reports an error, **stop and fix `/etc/fstab` before continuing**.

Set permissions:

```sh
sudo chmod 750 /.snapshots
```

---

</details>

<details><summary>Step 5: Create the Snapper root configuration</summary>

### Step 5: Configure Snapper for `/`

Create the configuration directory:

```sh
sudo mkdir -p /etc/snapper/configs
```

Create:

```sh
sudo nano /etc/snapper/configs/root
```

Use:

```ini
SUBVOLUME="/"
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
EMPTY_PRE_POST_MIN_AGE="1800"
```

Register the configuration:

```sh
echo 'SNAPPER_CONFIGS="root"' | sudo tee /etc/snapper/snapper-configs
```

Verify:

```sh
sudo snapper -c root list
```

An empty list is acceptable if no snapshots exist yet; configuration/mount errors are not.

---

</details>

<details><summary>Step 6: Enable Snapper timers and Snap-Pac</summary>

### Step 6: Enable automatic snapshot services

```sh
sudo systemctl enable --now snapper-timeline.timer
```

```sh
sudo systemctl enable --now snapper-cleanup.timer
```

Check:

```sh
systemctl status snapper-timeline.timer --no-pager
```

```sh
systemctl status snapper-cleanup.timer --no-pager
```

`snap-pac` integrates with Pacman so package transactions can create pre/post snapshots.

---

</details>

<details><summary>Step 7: Enable GRUB-Btrfs</summary>

### Step 7: Enable `grub-btrfsd`

```sh
sudo systemctl enable --now grub-btrfsd
```

Verify:

```sh
systemctl is-active grub-btrfsd
```

Expected:

```
active
```

---

</details>

<details><summary>Step 8: Add the GRUB-Btrfs OverlayFS initramfs hook</summary>

### Step 8: Configure `grub-btrfs-overlayfs`

Edit:

```sh
sudo nano /etc/mkinitcpio.conf
```

Find the active `HOOKS=(...)` line and add `grub-btrfs-overlayfs` at the **end**.

Example:

```ini
HOOKS=(base udev autodetect microcode modprobed-db kms keyboard keymap consolefont block filesystems fsck grub-btrfs-overlayfs)
```

> [!IMPORTANT]
> Modify the existing active `HOOKS=` assignment. Do not create a second `HOOKS=` line.

Verify:

```sh
grep '^HOOKS=' /etc/mkinitcpio.conf
```

It must contain:

```
grub-btrfs-overlayfs
```

Rebuild:

```sh
sudo mkinitcpio -P
```

If there is an actual `ERROR:`, stop and fix it before continuing.

---

</details>

<details><summary>Step 9: Configure GRUB-Btrfs snapshot kernel parameters</summary>

### Step 9: Configure snapshot boot parameters

Edit:

```sh
sudo nano /etc/default/grub-btrfs/config
```

Set:

```ini
GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS="rd.live.overlay.overlayfs=1 snapper_snapshot_boot=1"
```

Verify:

```sh
grep '^GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS=' /etc/default/grub-btrfs/config
```

Expected to contain:

```
rd.live.overlay.overlayfs=1 snapper_snapshot_boot=1
```

> [!IMPORTANT]
> Keep `snapper_snapshot_boot=1`. The systemd fix in the next step uses it to distinguish snapshot boots from normal boots.

---

</details>

<details><summary>Step 10: fix systemd-remount-fs.service for snapshot OverlayFS boots</summary>

### Step 10: Add the OverlayFS remount condition

This is an important part of this project's setup. During a snapshot boot, `/` becomes OverlayFS. Without the condition below, `systemd-remount-fs.service` can try to remount `/` using the normal Btrfs root entry and fail with an error similar to:

```
mount: /: fsconfig() failed: overlay: No changes allowed in reconfigure.
```

> [!IMPORTANT]
> Perform this while booted into the **normal/main Arch Linux system**, not a snapshot.

Create the drop-in directory:

```sh
sudo mkdir -p /etc/systemd/system/systemd-remount-fs.service.d
```

Create the drop-in:

```sh
sudo sh -c 'printf "%s\n" "[Unit]" "ConditionKernelCommandLine=!snapper_snapshot_boot=1" > /etc/systemd/system/systemd-remount-fs.service.d/snapshot-overlay.conf'
```

Verify:

```sh
cat /etc/systemd/system/systemd-remount-fs.service.d/snapshot-overlay.conf
```

It must contain exactly:

```ini
[Unit]
ConditionKernelCommandLine=!snapper_snapshot_boot=1
```

Reload:

```sh
sudo systemctl daemon-reload
```

On a normal boot, `snapper_snapshot_boot=1` is absent, so the service remains able to run normally.

---

</details>

<details><summary>Step 11: Rebuild initramfs and GRUB</summary>

### Step 11: Generate the boot configuration

```sh
sudo mkinitcpio -P
```

Then:

```sh
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

If snapshots already exist, GRUB-Btrfs should detect them during generation.

---

</details>

<details><summary>Step 12: Install the Fish arch snapshot helper</summary>

### Step 12: Create `arch snapshot`

Create the Fish function directory:

```sh
mkdir -p ~/.config/fish/functions
```

Create:

```sh
nano ~/.config/fish/functions/arch.fish
```

Add:

```fish
function arch --description "Arch Linux Snapshot Utility"
    set -l sub_command $argv[1]

    switch "$sub_command"
        case snapshot
            set -l flag $argv[2]
            set -l args $argv[3..-1]

            switch "$flag"
                case -l --list
                    echo " Listing all system snapshots..."
                    sudo snapper -c root list

                case -d --delete
                    if test (count $args) -eq 0
                        echo " Error: Please specify at least one snapshot ID to delete."
                        echo " Usage: arch snapshot -d <id1> [id2 id3 ...]"
                        return 1
                    end

                    echo " Deleting snapshot ID(s): $args..."
                    for id in $args
                        echo "   - Deleting ID: $id"
                        if not sudo snapper -c root delete $id
                            echo " Error: Failed to delete snapshot ID: $id"
                            return 1
                        end
                    end

                    echo " Updating GRUB menu..."
                    if not sudo grub-mkconfig -o /boot/grub/grub.cfg
                        echo " Error: GRUB update failed."
                        return 1
                    end

                case -h --help -help
                    echo " Arch Snapshot Utility"
                    echo "-------------------------------------"
                    echo "Usage:"
                    echo "  arch snapshot               : Create a manual snapshot"
                    echo "  arch snapshot -l            : List all snapshots"
                    echo "  arch snapshot -d <ID1> <ID2>: Delete multiple snapshots by ID"
                    echo "  arch snapshot -d (seq 1 15) : Delete snapshots from ID 1 to 15"
                    echo "  arch snapshot -h | -help    : Show this help message"

                case ""
                    set -l desc "Manual snapshot taken on "(date "+%Y-%m-%d %H:%M:%S")
                    echo " Creating manual snapshot..."
                    if sudo snapper -c root create --description "$desc"
                        echo " Snapshot created successfully!"
                    else
                        echo " Error: Snapshot creation failed."
                        return 1
                    end

                case "*"
                    echo " Unknown flag: $flag"
                    echo "Use 'arch snapshot -h' for help."
                    return 1
            end

        case "*"
            echo " Unknown command: $sub_command"
            echo "Use 'arch snapshot -h' for help."
            return 1
    end
end
```

Load it:

```sh
source ~/.config/fish/functions/arch.fish
```

Test:

```sh
arch snapshot -h
```

Then:

```sh
arch snapshot -l
```

---

</details>

<details><summary>Step 13: Create a NEW test snapshot</summary>

### Step 13: Create a snapshot after all fixes

Create a new snapshot **after** the systemd drop-in was installed:

```sh
sudo snapper -c root create --description "Manual installation test"
```

List it:

```sh
sudo snapper -c root list
```

> [!WARNING]
> Snapshots created before the `systemd-remount-fs` drop-in was added do not contain the new file. Use a snapshot created **after** the fix for the first boot test.

Regenerate GRUB:

```sh
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

---

</details>

<details><summary>Step 14: Verify the normal boot before rebooting</summary>

### Step 14: Normal-system verification

Check:

```sh
findmnt /
```

The normal root should be Btrfs, not OverlayFS.

```sh
findmnt /.snapshots
```

```sh
sudo snapper -c root list
```

```sh
systemctl is-active grub-btrfsd
```

Expected:

```
active
```

```sh
systemctl --failed
```

Expected:

```
0 loaded units listed.
```

Check the hook:

```sh
grep '^HOOKS=' /etc/mkinitcpio.conf
```

It must contain `grub-btrfs-overlayfs`.

Check the GRUB-Btrfs parameter:

```sh
grep '^GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS=' /etc/default/grub-btrfs/config
```

It must contain:

```
rd.live.overlay.overlayfs=1 snapper_snapshot_boot=1
```

Check the systemd drop-in:

```sh
cat /etc/systemd/system/systemd-remount-fs.service.d/snapshot-overlay.conf
```

Expected:

```ini
[Unit]
ConditionKernelCommandLine=!snapper_snapshot_boot=1
```

Check:

```sh
cat /proc/cmdline
```

A normal boot should **not** contain:

```
snapper_snapshot_boot=1
```

---

</details>

<details><summary>Test booting a snapshot</summary>

### Reboot and test a snapshot

```sh
sudo reboot
```

At GRUB, select:

```
Arch Linux snapshots
```

Select the **new snapshot created after the fix**.

After logging in:

```sh
cat /proc/cmdline
```

It should contain:

```
rd.live.overlay.overlayfs=1
snapper_snapshot_boot=1
```

Check:

```sh
findmnt /
```

An `overlay` root is expected during a snapshot boot.

Finally:

```sh
systemctl --failed
```

Expected:

```
0 loaded units listed.
```

`systemd-remount-fs.service` should not be listed as failed.

---

</details>

<details><summary>Return to the normal system</summary>

### Step 16: Return to normal Arch Linux

Reboot:

```sh
sudo reboot
```

Select the normal:

```
Arch Linux
```

entry, not the snapshot.

Verify:

```sh
findmnt /
```

The normal root should be Btrfs.

Then:

```sh
systemctl --failed
```

It should remain clean.

And:

```sh
cat /proc/cmdline
```

should not contain:

```
snapper_snapshot_boot=1
```

---

</details>

<details><summary>Final verification checklist</summary>

### Final verification checklist

Run:

```sh
findmnt -no FSTYPE /
```

→ `btrfs`

```sh
findmnt /.snapshots
```

→ `/.snapshots` is mounted from `@snapshots`

```sh
sudo snapper -c root list
```

→ Snapper lists snapshots without configuration errors

```sh
systemctl is-active grub-btrfsd
```

→ `active`

```sh
systemctl --failed
```

→ `0 loaded units listed.`

```sh
grep '^HOOKS=' /etc/mkinitcpio.conf
```

→ contains `grub-btrfs-overlayfs`

```sh
grep '^GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS=' /etc/default/grub-btrfs/config
```

→ contains `rd.live.overlay.overlayfs=1 snapper_snapshot_boot=1`

```sh
cat /etc/systemd/system/systemd-remount-fs.service.d/snapshot-overlay.conf
```

→ contains:

```ini
[Unit]
ConditionKernelCommandLine=!snapper_snapshot_boot=1
```

A successful snapshot boot should additionally show `snapper_snapshot_boot=1`, an `overlay` root, and no failed `systemd-remount-fs.service`.

---

</details>

<details><summary>Important safety notes</summary>

### Important safety notes

#### Do not use `snapper rollback` blindly from the normal base system

For this project's Btrfs layout, do not blindly run:

```sh
sudo snapper rollback
```

while booted into the normal base system.

If you intend to roll back, first boot the desired snapshot through the GRUB-Btrfs snapshot menu and then follow the project's rollback procedure.

### Do not manually delete Btrfs subvolumes to lower snapshot numbers

Do not use:

```sh
rm -rf /.snapshots/*
```

or arbitrary:

```sh
sudo btrfs subvolume delete ...
```

to force Snapper numbering back to `#1`.

A high snapshot number is not a failure. If you intentionally want to reset the history, use the project's **automated installer Option 2** rather than manually deleting snapshot storage.

#### Do not delete `/.snapshots` blindly

`/.snapshots` is a mount point and is not necessarily the actual Btrfs snapshot-storage subvolume.

Inspect first:

```sh
findmnt /.snapshots
```

```sh
sudo btrfs subvolume list /
```

#### Keep a recovery medium

Because this setup changes initramfs and GRUB, keep an Arch ISO/USB available.

---

</details>

<details><summary>Recommended workflow</summary>

### Recommended workflow

```
Verify Btrfs + GRUB
        ↓
Install packages
        ↓
Create top-level @snapshots
        ↓
Mount @snapshots at /.snapshots
        ↓
Add /etc/fstab entry
        ↓
Configure Snapper root
        ↓
Enable Snapper timers + grub-btrfsd
        ↓
Add grub-btrfs-overlayfs
        ↓
Configure snapshot kernel parameters
        ↓
Add systemd-remount-fs condition
        ↓
Rebuild initramfs
        ↓
Regenerate GRUB
        ↓
Create a NEW test snapshot
        ↓
Verify normal boot
        ↓
Boot the NEW snapshot
        ↓
Check OverlayFS + systemctl --failed
        ↓
Return to normal Arch Linux
```

> **Recommendation:** If you do not specifically need a manual installation, use the project's `install.fish`. The automated installer performs the same configuration while adding validation, backups, and the two snapshot-history modes.

---

</details>

# How to use (Usage)

### 1. Snapshot management command in Terminal (Fish Shell)

| command | Description |
|---|---|
| `arch snapshot` | Instantly **create a manual Snapshot** (with time/date stamp) |
| `arch snapshot -l` | **List all snapshots** in the system. |
| `arch snapshot -d <ID1> <ID2>` | **Delete multiple snapshots by ID** (e.g. `arch snapshot -d 5 6 7`) |
| `arch snapshot -d (seq <ID1> <ID15>)` | **Delete snapshots from ID** (e.g. `arch snapshot -d (seq 1 15)`) 
| `arch snapshot -h` | Show the [**Help menu**] (`arch snapshot -help`, `arch snapshot --help` can be used as well) |

### 2. Auto-Snapshot before-after system update

With `snap-pac` installed, **every time** you run the command:

```sh
sudo pacman -Syu
```

The system will **automatically** take `Pre` (before installation) and `Post` (after installation) snapshots.

### 3. Rollback (rewind the system when the device has a problem)

1. **Reboot** the machine and select the menu **`Arch Linux snapshots`** on the GNU GRUB page.

2. Select the **Snapshot** of the desired date and time.

3. When logging in (The system will temporarily be in a **Read-Only** state.) **If you are sure you want to roll back** the system, **open a Terminal and run**:

```sh
sudo snapper rollback
```

4. Order to **reboot** the machine again. The system will turn back time perfectly!

### 4. Customized Snapper settings (Default Retention)

This script sets up automatic snapshot retention to prevent the disk from filling up:

- Number Cleanup: **Keep up to 50 numbers** (10 important numbers)

- **Timeline Cleanup**:
  - Hourly: **Collect 10 characters**.
  - Daily: **Collect 10 characters**.
  - Weekly / Monthly / Yearly: **0** (`turn it off to save space`)

## OPTIONAL

<details><summary>How to clean and reset Snapper to #1</summary>

### Why does Snapper not reuse the old snapshot number after I delete it? (In-depth explanation)

- There are three main factors that prevent Snapper from resetting to `#1` after we delete files:
1. `info.xml` within **Subvolume** (`/.snapshots/<number>/info.xml`):
Snapper doesn't just check if the folder in `/.snapshots/ exists`, every time a snapshot is created, it creates an `info.xml` file to store metadata. If these files are stuck or the numbers in the XML conflict, the system will skip to the next number.

2. **Snapper Internal DB / Metadata Counter**:
The Snapper Engine stores the Next Snapshot ID in Memory/State. If you delete a folder using `rm -rf` without using the `snapper delete` command, the Snapper counter will not update backward.

3. **Btrfs Subvolume Tree Inconsistency**:
At the Btrfs File System level, each subvolume has its own subvolume ID in the kernel. Even if the folder is deleted on the OS, if the actual subvolume hasn't been `btrfs subvolume delete`, the snapper will consider that area to still have a conflict and will run the next ID to prevent data overlap (Data Corruption Protection).

#### How to clean and reset Snapper #1 (One-Liner / Single Script)

> [!WARNING]
> ## YOU NEED TO DELETE ALL YOUR SNAPSHOT BEFORE PROCEEDING WITH THE FOLLOWING STEPS.

- To completely reset the Snapper system to a clean 100% reset, returning the snapshot count to `#1` you can use the command/script below:

1. **Stop the service** and **unmount all** old files.

```sh
sudo systemctl stop grub-btrfsd
```

```sh
sudo umount -l /.snapshots 2>/dev/null
```

```sh
sudo rm -rf /.snapshots
```

```sh
sudo rm -rf /etc/snapper/configs/*
```

2. Unlock the **configuration** to allow **Snapper** to create a new configuration.

```sh
echo 'SNAPPER_CONFIGS=""' | sudo tee /etc/conf.d/snapper >/dev/null
```

```sh
echo 'SNAPPER_CONFIGS=""' | sudo tee /etc/sysconfig/snapper >/dev/null
```

3. Let **Snapper** create the actual **configuration** file first (it will secretly create its own `/.snapshots` file).

```sh
sudo snapper -c root create-config /
```

4. Swap the `/.snapshots` that **Snapper** creates with our actual `@snapshots`.

```sh
sudo umount /.snapshots 2>/dev/null
```

```sh
sudo rm -rf /.snapshots
```

```sh
sudo mkdir -p /.snapshots
```

```sh
sudo mount -o subvol=@snapshots (df -P / | tail -n1 | awk '{print $1}') /.snapshots
```

5. Register the **configuration** and set **permissions**.

```sh
echo 'SNAPPER_CONFIGS="root"' | sudo tee /etc/conf.d/snapper >/dev/null
```

```sh
echo 'SNAPPER_CONFIGS="root"' | sudo tee /etc/sysconfig/snapper >/dev/null
```

```sh
sudo chmod 750 /.snapshots
```

6. **Restart Service**.

```sh
sudo systemctl daemon-reload
```

```sh
sudo systemctl restart grub-btrfsd
```
### 5.5 Ensure Persistent Mounts (`/etc/fstab`)

> [!NOTE]
> To prevent snapshots from disappearing after a system **reboot**, ensure your `/@snapshots` subvolume is registered in `/etc/fstab`.

1. Open the `/etc/fstab` file.

```sh
sudo nvim /etc/fstab
```

**or**

```sh
sudo nano /etc/fstab
```

2. Add this line to the bottom of the file.

> [!NOTE]
> If you find multiple duplicate `/.snapshots` lines, delete them all so that only one remains, in this correct format.

![preview](assets/UUID-preview-1.png "PREVIEW")

```sh
UUID=YOUR_ROOT_UUID  /.snapshots  btrfs  rw,relatime,ssd,discard=async,space_cache=v2,subvol=/@snapshots  0 0
```

> [!NOTE]
> (Replace `YOUR_ROOT_UUID` with the actual UUID of your primary drive.)

> [!TIP]
> (The complete `/etc/fstab` file after adding this will look like this.)
> ```sh
> # Static information about the filesystems.
> # See fstab(5) for details.
> 
> # <file system> <dir> <type> <options> <dump> <pass>
> # /dev/nvme0n1p2
> UUID=235749cf-3398-4291-b33f-96ccec82bb84 / btrfs rw,relatime,ssd,discard=async,space_cache=v2,subvol=/ 0 0
> 
> # /dev/nvme0n1p1
> UUID=533C-B30F /boot vfat rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro 0 2
>
> # /dev/nvme0n1p2 - /.snapshots
> UUID=235749cf-3398-4291-b33f-96ccec82bb84 /.snapshots btrfs rw,relatime,ssd,discard=async,space_cache=v2,subvol=/@snapshots 0 0
> ```

3. Perform a **mount** test and **reload** Systemd.

- Run this command in the **Terminal** to **mount the system** immediately without **restarting**

```sh
sudo systemctl daemon-reload
```

```sh
sudo mount -a
```

#### All your snapshots will reappear immediately, and this time, they won't disappear even after multiple restarts.

</details>

---