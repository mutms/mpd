" Debian loads defaults.vim only when there is no ~/.vimrc — source it
" here so this file adds to the good defaults instead of replacing them.
source $VIMRUNTIME/defaults.vim

" Mouse off: defaults.vim sets mouse=a, which takes click and drag away
" from the terminal, so selecting text to copy needs a `:set mouse=`
" first. Put `set mouse=a` in /var/lib/mpd/skel/.vimrc to get it back.
set mouse=
