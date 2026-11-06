# COPYRIGHT_BEGIN
# MIT License
#
# Copyright (c) 2026 Wizzer Works
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# COPYRIGHT_END

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
# SSH by default (needs a running ssh-agent; compose forwards it via --mount=type=ssh).
# For HTTPS instead, set OPENTOONZ_REPO=https://github.com/WizzerWorks/opentoonz.git
ARG OPENTOONZ_REPO=git@github.com:WizzerWorks/opentoonz.git
ARG OPENTOONZ_REF=magiclantern
# Parallel compile jobs. Default 2 keeps the host responsive; raise via BUILD_JOBS=N.
# 0 = use all cores (nproc).
ARG BUILD_JOBS=2

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates openssh-client pkg-config \
        libboost-all-dev libegl1-mesa-dev libfreetype6-dev libgl1-mesa-dev \
        libglew-dev libglib2.0-dev libjpeg-dev libjson-c-dev liblz4-dev \
        liblzo2-dev libpng-dev libsuperlu-dev libusb-1.0-0-dev libsdl2-dev \
        libmypaint-dev libopencv-dev libturbojpeg0-dev libtiff-dev \
        freeglut3-dev libqt5multimedia5-plugins libx11-dev zlib1g-dev liblzma-dev \
        qtbase5-dev qtscript5-dev qt5-qmake qtmultimedia5-dev \
        libqt5svg5-dev libqt5opengl5-dev libqt5serialport5-dev qtwayland5 \
        libqt5xmlpatterns5-dev qttools5-dev \
        libxkbcommon-x11-0 libxcb-xinerama0 libxcb-icccm4 libxcb-image0 \
        libxcb-keysyms1 libxcb-render-util0 libxcb-xkb1 \
        fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN mkdir -p -m 0700 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
# Change this (e.g. to the branch HEAD sha) to force a fresh clone instead of a cached layer.
ARG OPENTOONZ_REV=none
RUN --mount=type=ssh \
    echo "rev: ${OPENTOONZ_REV}" && git clone --depth 1 --branch "${OPENTOONZ_REF}" "${OPENTOONZ_REPO}" opentoonz

# Bundled libtiff (OpenToonz needs its patched copy)
WORKDIR /src/opentoonz/thirdparty/tiff-4.0.3
RUN ./configure --with-pic --disable-jbig \
    && J=${BUILD_JOBS:-2}; [ "$J" -gt 0 ] 2>/dev/null || J=$(nproc); echo "make jobs: $J"; nice -n 19 make -j"$J"

WORKDIR /src/opentoonz/toonz
RUN mkdir build
WORKDIR /src/opentoonz/toonz/build
RUN J=${BUILD_JOBS:-2}; [ "$J" -gt 0 ] 2>/dev/null || J=$(nproc); echo "make jobs: $J"; \
    cmake ../sources -DCMAKE_BUILD_TYPE=Release \
        || echo "WARNING: cmake exited non-zero (Qt translation-rule errors); continuing"; \
    nice -n 19 ionice -c3 make -k -j"$J" \
    && make install

# Stock assets expected at /opt/opentoonz/stuff
RUN mkdir -p /opt/opentoonz \
    && cp -r /src/opentoonz/stuff /opt/opentoonz/stuff

# Firefox so the Help-menu links work (OpenToonz opens links through xdg-open -> $BROWSER).
# Ubuntu 24.04's own 'firefox' package is a snap stub that cannot run in Docker, so use
# Mozilla's apt repository. This layer sits after the compile so it never triggers a recompile.
RUN apt-get update && apt-get install -y --no-install-recommends wget xdg-utils dbus-x11 \
    && install -d -m 0755 /etc/apt/keyrings \
    && wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O /etc/apt/keyrings/packages.mozilla.org.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" > /etc/apt/sources.list.d/mozilla.list \
    && printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > /etc/apt/preferences.d/mozilla \
    && apt-get update && apt-get install -y --no-install-recommends firefox \
    && rm -rf /var/lib/apt/lists/*

# xdg-open helper: opens each link as a new tab in the already-running Firefox
COPY open-url /usr/local/bin/open-url
RUN chmod 0755 /usr/local/bin/open-url

# Non-root user; uid/gid overridable from compose to match the host user
ARG UID=1000
ARG GID=1000
RUN (getent passwd ${UID} && userdel -r $(getent passwd ${UID} | cut -d: -f1) || true) \
    && (getent group ${GID} || groupadd -g ${GID} toonz) \
    && useradd -m -u ${UID} -g ${GID} -s /bin/bash toonz \
    && chown -R toonz:${GID} /opt/opentoonz

# The config dir must exist and be owned by toonz: compose mounts a named volume here,
# and a new volume inherits ownership from this directory (otherwise it is root-owned).
RUN mkdir -p /home/toonz/.config && chown toonz:${GID} /home/toonz/.config

# Pre-seed OpenToonz's SystemVar.ini (the launcher script only writes it if missing) so
# projects default to /home/toonz/projects, the bind mount of ./projects on the host.
# Everything else matches the launcher's defaults.
RUN mkdir -p /home/toonz/.config/OpenToonz \
    && printf '%s\n' '[General]' \
        'OPENTOONZROOT="/home/toonz/.config/OpenToonz/stuff"' \
        'OpenToonzPROFILES="/home/toonz/.config/OpenToonz/stuff/profiles"' \
        'TOONZCACHEROOT="/home/toonz/.config/OpenToonz/stuff/cache"' \
        'TOONZCONFIG="/home/toonz/.config/OpenToonz/stuff/config"' \
        'TOONZFXPRESETS="/home/toonz/.config/OpenToonz/stuff/fxs"' \
        'TOONZLIBRARY="/home/toonz/.config/OpenToonz/stuff/library"' \
        'TOONZPROFILES="/home/toonz/.config/OpenToonz/stuff/profiles"' \
        'TOONZPROJECTS="/home/toonz/projects"' \
        'TOONZROOT="/home/toonz/.config/OpenToonz/stuff"' \
        'TOONZSTUDIOPALETTE="/home/toonz/.config/OpenToonz/stuff/studiopalette"' \
        > /home/toonz/.config/OpenToonz/SystemVar.ini \
    && chown -R toonz:${GID} /home/toonz/.config

USER toonz
WORKDIR /home/toonz
ENV PATH=/opt/opentoonz/bin:$PATH \
    BROWSER=/usr/local/bin/open-url \
    MOZ_DBUS_REMOTE=1 \
    LD_LIBRARY_PATH=/opt/opentoonz/lib/opentoonz:/opt/opentoonz/lib:/usr/local/lib \
    QT_X11_NO_MITSHM=1
# A private D-Bus session shared by OpenToonz and the Firefox it spawns: Firefox's X11
# remote mechanism hangs here, but D-Bus remote lets later links open as new tabs.
CMD ["dbus-run-session", "--", "opentoonz"]
