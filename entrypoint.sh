#!/bin/sh
# Container entrypoint (runs as root): start a private system D-Bus and a browse-only
# Avahi daemon so SANE network backends (escl, airscan) can discover scanners via mDNS,
# then drop to the unprivileged 'toonz' user and run the command (OpenToonz).
#
# Failures are non-fatal: without Avahi the app still starts, but network scanners must
# then be listed statically in sane/airscan.conf.

mkdir -p /run/dbus
rm -f /run/dbus/pid /run/dbus/system_bus_socket /run/avahi-daemon/pid

if dbus-daemon --system --fork 2>/dev/null; then
    # -D: daemonize. --no-drop-root is not used: avahi drops to its own user/chroot.
    avahi-daemon -D --no-rlimits 2>/dev/null \
        || echo "entrypoint: WARNING avahi-daemon failed to start; no mDNS scanner discovery" >&2
else
    echo "entrypoint: WARNING system dbus-daemon failed to start; no mDNS scanner discovery" >&2
fi

exec setpriv --reuid=toonz --regid="$(id -g toonz)" --init-groups \
    env HOME=/home/toonz USER=toonz LOGNAME=toonz "$@"
