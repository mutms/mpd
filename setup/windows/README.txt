Windows + Hyper-V bootstrap
==========================

Automation for mpd VM on Windows using Hyper-V (free with
Windows 10/11 Pro and Enterprise). For a "live in the VM" graphical
alternative on any hypervisor (including Hyper-V), see the sandbox
platform at https://github.com/mutms/mpd/tree/main/setup/sandbox/README.md

Files in this directory:

  setup.cmd      -- create a new mpd VM or switch the active VM (double-click)
  start.cmd      -- start the current VM
  stop.cmd       -- suspend all mpd VMs (state is preserved)
  uninstall.cmd  -- delete all mpd VMs and remove the mpd switch

All scripts trigger a UAC prompt for Administrator access.

Implementation lives under lib/ (PS1 scripts -- no need to open them).


Prerequisites
-------------

  * Windows 10 or 11 Pro / Enterprise (Home edition does not include Hyper-V).

  * Hyper-V enabled. If you have not done this yet:
      Settings > Apps > Optional Features > More Windows features
      Check "Hyper-V" (all sub-items), click OK, then reboot.

  * WSL2 with the Debian distro. Run once in an admin terminal, then reboot:
      wsl --install -d Debian
    setup.cmd uses WSL to run openssl (CA generation), genisoimage
    (cloud-init seed ISO), and qemu-img (disk conversion). No separate
    Windows installs of those tools are needed.

  * An SSH key. The script will detect whether you have one and offer
    to generate one if not.

  * winget (App Installer). Pre-installed on Windows 11. On Windows 10,
    install from the Microsoft Store if missing.

setup.cmd installs Windows Terminal via winget if not already present
and will prompt before installing it.


setup.cmd -- create a VM or switch the active VM
-------------------------------------------------

Double-click setup.cmd. Windows will show a UAC prompt -- click Yes.

The script:

  1. Explains the 'mpd' Hyper-V Internal switch and asks for confirmation.
     Any VM you connect to this switch (including custom ones) will use
     NAT through Windows for internet access.

  2. Lists all existing mpd-NN VMs. Shows which one is currently
     active (detected from the persistent route to the container subnet).

  3. Asks for a VM number:
       - Enter an existing number to switch to that VM or re-verify it.
       - Enter a new number to create a new VM end-to-end.

When creating a new VM, the script first asks for a VM username
(default: your Windows username, sanitised to lowercase letters /
digits / hyphens). Accept the default unless you have a reason —
the bare 'ssh mpd-NN-php' jump-host form assumes one matching name
across Windows / VM / runtime; see docs/NETWORKING.md.

Then:

  1. Downloads the Debian cloud image (~200 MB, cached for reuse).
  2. Converts and resizes the disk image to VHDX format.
  3. Prepares a cloud-init seed ISO (user, SSH key, static IP).
  4. Creates a Hyper-V Generation 2 VM and boots it.
  5. Waits for cloud-init to finish, then clones the mpd repository
     inside the VM, installs Swift and build tools, builds mpd, and
     runs "mpd --setup" (CA certificate, container network, services).
  6. Configures Windows networking: static route to the container
     subnet, DNS rule for *.mpd.test, and imports the mpd CA
     certificate so browsers trust https://mpd.test without warnings.
  7. Pre-warms the demo stack: builds the PHP runtime image and creates
     a postgres:latest DB container inside the VM so the first
     "demo moodle v5.2.0" doesn't pay the build/pull cost.
  8. Creates helper scripts in %USERPROFILE%\mpd VM\ and a desktop
     shortcut "mpd VM" for quick access.

The whole process takes 10-20 minutes depending on internet speed and
your machine. You can leave it running unattended after the prompts.

When setup finishes:

  * An "mpd VM" shortcut appears on your desktop. Double-click it to
    open a terminal connected to the VM.

  * https://mpd.test opens in your Windows browser and shows the mpd
    portal (project list, Adminer database UI, etc.).

  * The shell greets you with a short welcome message and a hint to
    run 'demo moodle v5.2.0'. Do that to get a fully installed Moodle
    5.2.0 site in one command -- URL and credentials printed at the
    end (typically ready in 2-3 minutes thanks to the pre-warm).

  * For day-to-day usage see docs/USAGE.md in the mpd repo.

When switching to a different VM:

  1. The current VM is suspended (state preserved on disk, resumes in
     seconds).
  2. The selected VM starts (or resumes from a previous suspension).
  3. Windows networking is updated to point to the new VM.


start.cmd / stop.cmd
--------------------

start.cmd -- starts the VM that is currently configured (detected from
             the persistent route). No prompts.

stop.cmd  -- suspends all running mpd VMs. State is preserved on disk
             so they resume instantly. Useful before shutting down the
             host or switching VMs via setup.cmd.

Both require Administrator access (UAC prompt).


uninstall.cmd
-------------

Lists what will be removed, asks you to press Enter to proceed, then:

  1. Removes the NRPT DNS rule for *.mpd.test.
  2. Removes the persistent route to the container subnet.
  3. Removes the mpd CA certificate from the trusted root store.
  4. Removes the Hyper-V switch, NAT rule, and host IP.
  5. Deletes %USERPROFILE%\mpd VM\ (helper scripts, CA, current.env).
  6. Removes the 'Host mpd VM' entry from ~/.ssh/config.
  7. Removes the "mpd VM" desktop shortcut.
  8. For each mpd-NN VM, asks [y/N] whether to delete it.
     Pressing Enter (or N) keeps the VM. The default is to keep.
     Ctrl-C during the VM loop leaves host configuration already cleaned
     and the remaining VMs untouched.

Run setup.cmd again to start fresh.


Why the VM IP is pinned
-----------------------

setup.cmd assigns a static IP to the VM (e.g. 10.164.0.158) via
cloud-init. A static IP is required because the bootstrap automation
needs to SSH into the VM before it is fully up -- DHCP would give an
unknown address that the script cannot predict.

The static IP is recorded in the VM as conf/platform.env (MPD_VM_IP).

The active VM is tracked via the persistent route: the route to
10.163.0.0/24 (the container subnet) points to the VM's IP, so
start.cmd can detect the current VM even after a host reboot.

Note: the Hyper-V 'mpd' switch subnet (10.164.0.0/24) is fixed and
does not change after Windows upgrades. If networking stops working
after an upgrade, run setup.cmd and select your VM number to
re-verify the route and re-import the CA certificate.


Multiple VMs side-by-side
--------------------------

Run setup.cmd and enter a different octet to create a second VM:

  e.g. enter 159 alongside an existing 158 VM

Each VM gets its own static IP and Hyper-V display name. Only one VM
is "current" at a time (the one the container route points to). To
switch, run setup.cmd and enter the other VM's number -- the current
VM is suspended and the selected VM resumes.


Recovery: lost SSH key
----------------------

The cloud-init configuration locks all passwords (no TTY login, no
password SSH). If the private key at ~/.ssh/id_ed25519 is lost, you
cannot log into the VM through normal means.

Options:

  1. Rebuild the VM (fastest). Run uninstall.cmd, then setup.cmd again.
     Any local project state (databases, generated CA, build artifacts)
     will be lost. Code pushed to a remote git remote is unaffected.

  2. Recover via Hyper-V console.

     a. Open Hyper-V Manager, right-click the VM > Connect.
        You will see a basic text console.

     b. Reboot the VM. When the GRUB menu appears (you may need to
        press a key quickly to interrupt auto-boot), highlight the
        default entry and press 'e' to edit it.

     c. Find the line starting with "linux". Move to the end of
        that line and add:  init=/bin/bash
        Press Ctrl-X or F10 to boot.

     d. You land in a root shell. The filesystem is read-only:
          mount -o remount,rw /

     e. Replace the authorized_keys file:
          vi /home/<your-user>/.ssh/authorized_keys
        Paste your new public key (contents of %USERPROFILE%\.ssh\id_ed25519.pub).

     f. Save and reboot:
          sync
          exec /sbin/init

     g. After the VM comes back, run setup.cmd and select the VM's
        number to re-verify networking and re-import the CA certificate.


File transfer (Windows <-> VM)
------------------------------

The simplest path is scp:

  # Copy a file from Windows to the VM:
  scp "C:\path\to\file.txt" yourname@10.164.0.158:~/

  # Copy a file from the VM to Windows:
  scp yourname@10.164.0.158:~/file.txt "C:\Users\yourname\Downloads\"

For bulk transfers, the mpd fileaccess service exposes /srv/backups/
inside the VM as an SSH endpoint at fileaccess.service.mpd.test after
"mpd --setup" has run.

Do not copy private keys or the caroot/ directory out of the VM.
Private material stays in /var/lib/mpd/conf/ inside the VM.
