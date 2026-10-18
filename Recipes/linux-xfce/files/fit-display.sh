#!/bin/sh
#
# fit-display.sh - started with the XFCE session by its autostart entry; the linux-xfce recipe
# installs it as /usr/local/libexec/agent-vm-fit-display. An interactive `agent-vm box view`
# window gives the box's display the window's size, which GNOME and KDE take by themselves and X
# does not: at each change of the display, every connected output is set to its preferred mode,
# which is that size. Runs as the box user, for as long as the session.

/usr/bin/udevadm monitor --udev --subsystem-match=drm | while read -r line; do
    case "$line" in
        # The monitor's first line says it listens: a size given before then is taken now.
        "monitor will print"*|*" change "*)
            for output in $(/usr/bin/xrandr | /usr/bin/sed -n 's/^\([^ ]*\) connected.*/\1/p'); do
                /usr/bin/xrandr --output "$output" --auto
            done
            ;;
    esac
done
# Only if the monitor ended (it lands in ~/.xsession-errors).
printf 'agent-vm-fit-display: udevadm monitor ended; the screen keeps its size until the next login\n' >&2
