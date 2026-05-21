# mpd-machine — Parallels Desktop Pro machines

## VM template preparation

1. Configure Parallels Desktop Pro Shared network to use 10.211.55.1-100 as DHCP range
2. Install Debian Trixie VM with Gnome desktop
3. Install Parallels tools in the VM, you may need to manually run `su`, `mount /media/cdrom -o exec` and `bash /media/cdrom/installer/install-cli.sh`
4. Install additional apps and tweak default settings
5. Make a template from installed VM called: mpd-machine-template

## Create new VM

1. Run `setup.desktop` or `bash setup/macos-prl/lib/setup.sh`

TODO: to be finished after sandbox scripts are converted to Debian Trixie
