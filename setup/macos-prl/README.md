# mpd-machine — Parallels Desktop Pro machines

These scripts are compatible only with Debian Trixie, see https://www.debian.org/releases/trixie/

## VM template preparation

1. Configure Parallels Desktop Pro Shared network to use 10.211.55.1-99 as DHCP range
2. Install Debian Trixie using hostname `mpd-machine-base` and the following software selection:
   - Debian desktop environment
   - GNOME
   - SSH server
   - standard system utilities
3. Install Parallels Tools in the VM, you may need to manually run
```shell
su -
```
```shell
mount /media/cdrom -o exec
bash /media/cdrom/installer/install-cli.sh -i
```
4. Make a template from installed VM called `mpd-machine-template` via "File / Convert to template" 

## Create new VM

1. Run `setup.desktop` or `bash setup/macos-prl/lib/setup.sh`

TODO: to be finished after sandbox scripts are converted to Debian Trixie
