# This is YOUR .bashrc — edit it freely, add whatever you like. It is your
# runtime's own copy and nothing overwrites it. Just keep the two lines below:
# the mpd environment (PATH, prompt, tools) lives in the bind-mounted
# bashrc-include.sh so it can be updated without touching your file — remove
# that source line and this runtime loses its mpd shell setup.
[ -f /etc/skel/.bashrc ] && . /etc/skel/.bashrc
[ -f /opt/mpd/assets/runtime/lib/bashrc-include.sh ] && . /opt/mpd/assets/runtime/lib/bashrc-include.sh
