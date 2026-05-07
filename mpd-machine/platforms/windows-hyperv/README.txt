Windows + Hyper-V bootstrap
==========================

Automation for mpd-machine on Windows using Hyper-V (free with
Windows 10/11 Pro and Enterprise). For the platform-agnostic manual
bootstrap (any Debian Trixie VM you've already created yourself), see
../generic-vm/README.md.

This directory contains:

  setup.cmd               -- double-click to run everything (triggers UAC prompt)
  create-headless-vm.ps1  -- one-shot: creates the VM end-to-end
  configure-client.ps1        -- idempotent: configures Windows networking (called automatically
                             by create-headless-vm.ps1; also usable standalone)


Prerequisites
-------------

  * Windows 10 or 11 Pro / Enterprise (Home edition does not include
    Hyper-V).

  * Hyper-V enabled. If you have not done this yet:
      Settings > Apps > Optional Features > More Windows features
      Check "Hyper-V" (all sub-items), click OK, then reboot.

  * An SSH key. The script will detect whether you have one and offer
    to generate one if not.


create-headless-vm.ps1 -- create a VM from scratch
---------------------------------------------------

This script provisions a Debian Trixie VM end-to-end:

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
  7. Creates helper scripts in %USERPROFILE%\mpd\ and a desktop
     shortcut "mpd SSH" for quick access.

The whole process takes 10-20 minutes depending on internet speed and
your machine. You can leave it running unattended after the prompts.

How to run:

  1. Download setup.cmd and create-headless-vm.ps1 into the same folder
     (e.g. %USERPROFILE%\Downloads\).

  2. Double-click setup.cmd.
     Windows will show a UAC prompt -- click Yes to allow admin access.

  3. The script prompts for two values:

     * Last IP octet (default 200). This drives the VM name
       (mpd-machine-200), its static IP on the Hyper-V Default Switch,
       and the hostname inside the VM. Pick a different number to run
       multiple VMs side-by-side (e.g. 200 and 201 at the same time).

     * Disk size in GB (default 200). The cloud image is ~3 GB; the
       disk grows to fill whatever you choose here.

  4. If no SSH key is found, the script pauses and runs ssh-keygen so
     you can set a passphrase. Follow the on-screen prompts.

After it finishes:

  * Double-click "mpd SSH" on the Desktop to open an SSH session.
  * Open https://mpd.test in Edge or Chrome -- should load with a
    padlock (the CA cert was imported automatically).
  * Run "mpd --help" inside the VM to see available commands.


Why the VM IP is pinned
-----------------------

The script assigns a static IP to the VM (e.g. 172.19.111.200) via
cloud-init. A static IP is required because the bootstrap automation
needs to SSH into the VM before it is fully up -- DHCP would give an
unknown address that the script cannot predict.

The static IP is placed in the highest /24 of the Hyper-V Default
Switch subnet to avoid conflicts with the switch's own DHCP pool.
It is recorded in the VM as conf/platform.env (MPD_VM_IP) and on the
Windows side as the route target in configure-client.ps1.

Note: the Hyper-V Default Switch subnet (e.g. 172.19.96.0/20) can
change after a major Windows upgrade. If it does, the route and NRPT
rule will be stale. Run configure-client.ps1 again (as Administrator) with
the new VM IP to fix it.


configure-client.ps1 -- configure Windows networking only
------------------------------------------------------

This script is called automatically at the end of create-headless-vm.ps1,
so you do not need to run it manually for a fresh install. Use it if:

  * You set up the VM manually using ../generic-vm/README.md.
  * Windows networking stopped working after a host reboot or upgrade.

How to run (elevated):

  powershell -ExecutionPolicy Bypass -File configure-client.ps1 -VmIp 172.19.111.200 -SshUser yourname

Replace the IP and username with the actual values for your VM.

The script is idempotent: it skips any step that is already correct,
so it is safe to run multiple times.

What it does:

  * Adds a persistent route: Windows sends 10.163.0.0/24 traffic
    (the container subnet) through the VM.
  * Adds an NRPT rule: Windows resolves *.mpd.test via the dnsmasq
    container at 10.163.0.3 (inside the VM).
  * Fetches the mpd CA certificate from the VM over SCP and imports
    it into the Windows trusted root store, so browsers accept
    https://mpd.test without a certificate warning.


Helper scripts in %USERPROFILE%\mpd\
-------------------------------------

After create-headless-vm.ps1 finishes, it creates a small set of
scripts in %USERPROFILE%\mpd\ with the VM details already filled in:

  ssh-vm.ps1        -- open an SSH session (no arguments needed)
  start-vm.ps1      -- start the VM (run as Administrator)
  stop-vm.ps1       -- shut down the VM gracefully (run as Administrator)
  configure-client.ps1  -- re-run Windows networking setup (as Administrator)

These are convenience wrappers. The VM is also set to start
automatically with Windows, so you normally do not need start-vm.ps1.


Multiple VMs side-by-side
--------------------------

Run create-headless-vm.ps1 again with a different octet to create a
second VM:

  powershell -ExecutionPolicy Bypass -File create-headless-vm.ps1 -VmOctet 201

Each VM gets its own static IP and Hyper-V display name. The "mpd SSH"
shortcut on the Desktop always connects to the first VM (mpd-machine).
To connect to a specific VM:

  ssh yourname@172.19.111.201
  -- or --
  ssh mpd-machine-201   (after adding a Host entry to ~/.ssh/config)


Recovery: lost SSH key
----------------------

The cloud-init configuration locks all passwords (no TTY login, no
password SSH). If the private key at ~/.ssh/id_ed25519 is lost, you
cannot log into the VM through normal means.

Options:

  1. Rebuild the VM (fastest). Delete the VM in Hyper-V Manager,
     then run create-headless-vm.ps1 again. Any local project state
     (databases, generated CA, build artifacts) will be lost. Code
     that was pushed to a remote git remote is unaffected.

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
        Paste your new public key (the contents of id_ed25519.pub
        from your Windows machine, found at %USERPROFILE%\.ssh\).

     f. Save and reboot:
          sync
          exec /sbin/init

     g. After the VM comes back, run configure-client.ps1 again to
        refresh the CA certificate (the SSH key change does not
        affect the cert, but it is a good time to re-verify).


File transfer (Windows <-> VM)
------------------------------

The simplest path is scp:

  # Copy a file from Windows to the VM:
  scp "C:\path\to\file.txt" yourname@172.19.111.200:~/

  # Copy a file from the VM to Windows:
  scp yourname@172.19.111.200:~/file.txt "C:\Users\yourname\Downloads\"

For bulk transfers, the mpd fileaccess service exposes /srv/backups/
inside the VM as an SSH endpoint at fileaccess.service.mpd.test after
"mpd --setup" has run.

Do not copy private keys or the caroot/ directory out of the VM.
Private material stays in ~/Developer/mpd/conf/ inside the VM.
