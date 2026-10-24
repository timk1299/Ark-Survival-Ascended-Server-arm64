# check=skip=FromPlatformFlagConstDisallowed
# (the SteamCMD rootfs stage is x86 on purpose)

# ARK: Survival Ascended dedicated server for arm64.
#
# ASA runs through the aarch64 build of GE-Proton: a native arm64 Wine that
# executes the x86_64 Windows server through FEX's ARM64EC/WoW64 DLLs. All
# container scripts run natively. Only SteamCMD (a 32-bit x86 Linux program)
# runs through the FEX interpreter, using a minimal x86 rootfs built below.
#
# Stages that only download or compile platform-independent files run on the
# build machine's own platform ($BUILDPLATFORM), so they don't need QEMU.

ARG UBUNTU_VERSION=26.04

# ---- Windows HTTPS probe used by scripts/proton_https_probe.sh ----
FROM --platform=$BUILDPLATFORM ubuntu:24.04 AS winprobe-builder
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc-mingw-w64-x86-64 && \
    rm -rf /var/lib/apt/lists/*
COPY require_files/pok_https_probe.c /tmp/pok_https_probe.c
RUN x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -municode \
    /tmp/pok_https_probe.c -o /tmp/pok_https_probe.exe -lwinhttp

# ---- rcon-cli, built for the target arch (upstream only ships x86 Linux binaries) ----
FROM --platform=$BUILDPLATFORM golang:1.24 AS rcon-builder
ARG RCON_VERSION=0.10.3
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} \
    go install -trimpath -ldflags="-s -w" github.com/gorcon/rcon-cli/cmd/gorcon@v${RCON_VERSION} && \
    find "$(go env GOPATH)/bin" -type f -name gorcon -exec install -D -m 755 {} /out/rcon-cli \; && \
    test -x /out/rcon-cli

# ---- Node.js helper dependencies (pure JavaScript, so platform independent) ----
FROM --platform=$BUILDPLATFORM node:24-slim AS node-deps
WORKDIR /helpers
COPY scripts/helpers/package.json ./
RUN npm install --omit=dev --no-audit --no-fund

# ---- Shared download stage ----
FROM --platform=$BUILDPLATFORM ubuntu:${UBUNTU_VERSION} AS fetch
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

# ---- GE-Proton (aarch64 build) ----
FROM fetch AS proton
ARG PROTON_VERSION=GE-Proton11-11
RUN set -eux; \
    if [ "$PROTON_VERSION" = "latest" ]; then \
      DOWNLOAD_URL=$(curl -fsSL https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest | grep browser_download_url | grep 'aarch64.tar.gz"' | cut -d\" -f4 | head -n 1); \
    else \
      DOWNLOAD_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${PROTON_VERSION}/${PROTON_VERSION}-aarch64.tar.gz"; \
    fi; \
    ARCHIVE_NAME="${DOWNLOAD_URL##*/}"; \
    CHECKSUM_NAME="${ARCHIVE_NAME%.tar.gz}.sha512sum"; \
    cd /tmp; \
    curl -fsSL "$DOWNLOAD_URL" -o "$ARCHIVE_NAME"; \
    curl -fsSL "${DOWNLOAD_URL%.tar.gz}.sha512sum" -o "$CHECKSUM_NAME"; \
    sha512sum -c "$CHECKSUM_NAME"; \
    mkdir -p /out; \
    tar -xzf "$ARCHIVE_NAME" -C /out; \
    ACTUAL_VERSION=$(basename "$(find /out -maxdepth 1 -mindepth 1 -type d | head -n 1)"); \
    test -d "/out/$ACTUAL_VERSION/files/bin-arm64"; \
    ln -s "$ACTUAL_VERSION" /out/GE-Proton-Current; \
    printf '%s\n' "$ACTUAL_VERSION" > /out/.pok-proton-version; \
    rm -f "$ARCHIVE_NAME" "$CHECKSUM_NAME"

# ---- SteamCMD and the VC++ redistributable ----
# vc_redist is installed into the Proton prefix on first start
# (initialize_proton_prefix), because Wine can't run during the image build.
FROM fetch AS assets
RUN set -eux; \
    mkdir -p /out/steamcmd /out/vcredist; \
    curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz -C /out/steamcmd; \
    curl -fsSL https://aka.ms/vs/17/release/vc_redist.x64.exe -o /out/vcredist/vc_redist.x64.exe; \
    test -s /out/vcredist/vc_redist.x64.exe

# ---- FEX interpreter from the official FEX PPA ----
# Only the interpreter and its server are needed; the package's GUI tools and
# thunk libraries are left out. armv8.0 runs on every arm64 CPU, and it only
# has to run SteamCMD. To change the package, also change version and checksum
# (see https://ppa.launchpadcontent.net/fex-emu/fex/ubuntu/dists/resolute/main/binary-arm64/Packages.gz).
FROM fetch AS fex
ARG FEX_PACKAGE=fex-emu-armv8.0
ARG FEX_DEB_VERSION=2610-1~r
ARG FEX_DEB_SHA256=15cbec4226dc5e587fb7c885613d0391c4343030b3ee3cefcd5870e624295c22
RUN set -eux; \
    curl -fsSL "https://ppa.launchpadcontent.net/fex-emu/fex/ubuntu/pool/main/f/${FEX_PACKAGE}/${FEX_PACKAGE}_${FEX_DEB_VERSION}_arm64.deb" -o /tmp/fex.deb; \
    echo "${FEX_DEB_SHA256}  /tmp/fex.deb" | sha256sum -c -; \
    dpkg-deb -x /tmp/fex.deb /tmp/fex; \
    install -D -m 755 /tmp/fex/usr/bin/FEX /out/usr/bin/FEX; \
    install -D -m 755 /tmp/fex/usr/bin/FEXServer /out/usr/bin/FEXServer

# ---- Minimal x86 rootfs for SteamCMD ----
# SteamCMD is 32-bit, so it needs the 32-bit C/C++ runtime and CA certificates.
FROM --platform=linux/amd64 ubuntu:${UBUNTU_VERSION} AS steam-rootfs-base
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates lib32gcc-s1 lib32stdc++6 libc6-i386 && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /usr/share/doc/* /usr/share/man/* /usr/share/info/*

# FEX looks up files in the rootfs first and falls back to the host. Removing
# these makes SteamCMD use the container's own DNS, hosts and user files.
FROM fetch AS steam-rootfs
COPY --from=steam-rootfs-base / /rootfs/
RUN rm -f /rootfs/etc/resolv.conf /rootfs/etc/hosts /rootfs/etc/hostname \
          /rootfs/etc/passwd /rootfs/etc/group /rootfs/etc/shadow /rootfs/etc/gshadow

# ---- Final image ----
FROM ubuntu:${UBUNTU_VERSION}
# IMPORTANT: These values are set at build time and CANNOT be changed at runtime
# The container has fixed user IDs:
# - 2_0_latest image: PUID=1000, PGID=1000
# - 2_1_latest image: PUID=7777, PGID=7777
# Host file ownership MUST match these values to avoid permission issues
ARG PUID=7777
ARG PGID=7777

# Set a default timezone, can be overridden at runtime
ENV TZ=UTC \
    PUID=${PUID} \
    PGID=${PGID} \
    PROTON_USE_ESYNC=1 \
    DEBIAN_FRONTEND=noninteractive \
    WINEDLLOVERRIDES="version=n,b" \
    WINEPREFIX="/home/pok/.steam/steam/steamapps/compatdata/2430930/pfx" \
    DISPLAY=:0.0 \
    HEALTHCHECK_PORT=8080 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# Linux dependencies for the scripts and for the native arm64 Wine in GE-Proton.
RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    jq curl wget tar unzip nano gzip iproute2 procps dbus tini \
    # Full python3: the Proton script needs ctypes, uuid, shlex and other modules python3-minimal lacks \
    python3 \
    # tzdata package provides timezone database for TZ environment variable support \
    tzdata locales \
    libc6 libgcc-s1 libstdc++6 libglib2.0-0t64 libvulkan1 \
    libnss3 \
    libfontconfig1 libfreetype6 \
    libcups2t64 \
    ca-certificates \
    # X server packages for headless operation
    xvfb x11-xserver-utils xauth libgl1-mesa-dri libgl1 libglx-mesa0 \
    # Libraries used by Wine and the VC++ runtime
    libldap2 libgnutls30t64 \
    libxml2-16 libasound2t64 libpulse0 \
    libopenal1 libncurses6 \
    # DO NOT ENABLE screen package - causes log display issues which is needed by the POK-manager.sh script
    winbind; \
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen; \
    locale-gen en_US.UTF-8; \
    update-locale LANG=en_US.UTF-8; \
    # Machine id for Proton
    rm -f /etc/machine-id /var/lib/dbus/machine-id; \
    dbus-uuidgen --ensure=/etc/machine-id; \
    dbus-uuidgen --ensure; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Create the pok user and the directories the scripts expect
RUN set -ex; \
    # Ubuntu images ship an "ubuntu" user with UID/GID 1000, which would clash with PUID/PGID=1000 \
    if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi; \
    groupadd -g ${PGID} pok; \
    useradd -d /home/pok -u ${PUID} -g pok -G users -m pok; \
    mkdir -p \
      /home/pok/.steam/steam/compatibilitytools.d \
      /home/pok/.steam/steam/steamapps/compatdata/2430930 \
      /home/pok/.fex-emu \
      /home/pok/logs \
      /home/pok/arkserver/ShooterGame/Binaries/Win64/AsaApi \
      /home/pok/arkserver/ShooterGame/Binaries/Win64/logs \
      /home/pok/arkserver/ShooterGame/Saved/Config/WindowsServer \
      /home/pok/arkserver/ShooterGame/Saved/SavedArks \
      /home/pok/arkserver/ShooterGame/Saved/Logs \
      /opt/steamcmd; \
    ln -s /home/pok/arkserver/ShooterGame/Saved/Logs/ShooterGame.log /home/pok/shooter_game.log; \
    # Only empty directories exist yet, so this recursive chown is cheap \
    chown -R pok:pok /home/pok /opt/steamcmd; \
    chmod 775 /home/pok/arkserver/ShooterGame/Binaries/Win64/logs /home/pok/arkserver/ShooterGame/Saved/Logs; \
    # X11 directories and lock file for Xvfb
    install -d -m 1777 /tmp/.X11-unix; \
    install -m 1777 -o pok -g pok /dev/null /tmp/.X0-lock

# FEX interpreter and the x86 rootfs, only used for SteamCMD
COPY --from=fex /out/usr/bin/ /usr/bin/
COPY --from=steam-rootfs /rootfs/ /opt/fex-rootfs/
RUN set -ex; \
    printf '{"Config":{"RootFS":"/opt/fex-rootfs"}}\n' > /home/pok/.fex-emu/Config.json; \
    chown pok:pok /home/pok/.fex-emu/Config.json; \
    printf '%s\n' '#!/bin/sh' \
      '# SteamCMD is a 32-bit x86 program, so run it through FEX with the x86 rootfs.' \
      'export FEX_ROOTFS=/opt/fex-rootfs' \
      'exec FEX /bin/bash /opt/steamcmd/steamcmd.sh "$@"' > /usr/local/bin/steamcmd; \
    chmod 755 /usr/local/bin/steamcmd

COPY --from=rcon-builder /out/rcon-cli /usr/local/bin/rcon-cli
COPY --from=node:24-slim /usr/local/bin/node /usr/local/bin/node
COPY --from=assets --chown=pok:pok /out/steamcmd/ /opt/steamcmd/
COPY --from=assets --chown=pok:pok /out/vcredist/ /home/pok/vcredist/
COPY --from=proton --chown=pok:pok /out/ /home/pok/.steam/steam/compatibilitytools.d/

# Copy scripts, defaults, and Require_Files folders into the container
COPY --chown=pok:pok defaults/ /home/pok/defaults/
COPY --chown=pok:pok require_files/ /home/pok/require_files/
COPY --from=winprobe-builder --chown=pok:pok /tmp/pok_https_probe.exe /home/pok/require_files/pok_https_probe.exe
COPY --chown=pok:pok --chmod=755 scripts/ /home/pok/scripts/
COPY --from=node-deps --chown=pok:pok /helpers/node_modules/ /home/pok/scripts/helpers/node_modules/

USER pok
WORKDIR /home/pok

HEALTHCHECK --interval=30s --timeout=10s --start-period=30m --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${HEALTHCHECK_PORT}/healthz" >/dev/null || exit 1

# Use tini as the entrypoint
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/home/pok/scripts/init.sh"]
