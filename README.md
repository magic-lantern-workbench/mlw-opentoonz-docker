# OpenToonz on Ubuntu 24.04 (Docker Compose)

Builds https://github.com/WizzerWorks/opentoonz from source (Qt5, Release) and runs the GUI via X11.

```bash
mkdir -p projects
docker compose build      # long: full OpenToonz compile (~25-30 min at BUILD_JOBS=2)
xhost +local:docker       # allow container to reach your X server (once per login)
UID=$(id -u) GID=$(id -g) docker compose up
```

## Options

Env vars or `.env`:

| Var | Default | Purpose |
|---|---|---|
| `OPENTOONZ_REPO` | `git@github.com:WizzerWorks/opentoonz.git` | SSH URL (needs a running `ssh-agent`; `SSH_AUTH_SOCK` is forwarded by BuildKit). Use `https://github.com/WizzerWorks/opentoonz.git` for HTTPS |
| `OPENTOONZ_REF` | `magiclantern` | Branch or tag to build. See [Source branch](#source-branch) |
| `OPENTOONZ_REV` | `none` | Cache-buster for the `git clone` layer. `.env.example` pins it to the `magiclantern` commit last built (`96f6ce6`). See [After pushing new commits](#after-pushing-new-commits) |
| `BUILD_JOBS` | `2` | Parallel compile jobs. `0` = all cores (not recommended, see [Keeping the host responsive](#keeping-the-host-responsive)). Each C++ job can use 2-3 GB RAM |

## Source branch

The `magiclantern` branch is `v1.8.0` of upstream OpenToonz plus fixes needed to compile
with the GCC 13 / Qt 5 / glibc shipped in Ubuntu 24.04 (`tcg/hash.h` `size_t` shadowing, a
stray control character in `twain.h`, missing `<QPainterPath>` includes, and the removed
`<sys/sysctl.h>` in `tfarmserver`). Because plain `v1.8.0` lacks these fixes, building it (or
upstream `master`) on this base image will most likely fail to compile.

## After pushing new commits

The Dockerfile clones the repo from GitHub, and Docker caches that layer. If you push
new commits to the branch and rebuild with the same arguments, Docker reuses the old
checkout and silently builds stale source. Pass the branch's current commit SHA to force
a fresh clone:

```bash
OPENTOONZ_REV=$(git ls-remote https://github.com/WizzerWorks/opentoonz.git magiclantern | cut -f1) \
  docker compose build
```

Re-running with the **same, full** SHA reuses the cached compile (seconds), so changes to
later Dockerfile steps (e.g. `ENV`, `USER`) don't trigger a recompile. A different or
abbreviated value invalidates the cache and recompiles everything.

## Keeping the host responsive

OpenToonz is a large C++/Qt project. An unbounded `make -j` spawned ~170 compilers, hit
the builder's memory cap and, uncapped, froze the host. To avoid that:

- Keep `BUILD_JOBS` at 2 (the Dockerfile falls back to 2 if it is unset or invalid).
- Cap the BuildKit builder container (these limits are lost if the container is recreated):

  ```bash
  docker update --cpus 4 --memory 12g --memory-swap 12g --cpu-shares 128 \
    buildx_buildkit_system-builder0
  ```

- Cancelling a build (Ctrl+C) can leave its compilers running inside the builder. If
  `pgrep cc1plus` still shows processes afterwards, run
  `docker restart buildx_buildkit_system-builder0`.

## Build notes

- `make -k` is used, so a failing build reports **all** compile errors in one run rather
  than stopping at the first.
- CMake prints `Attempt to add a custom rule to output ... tnzcore.ts.stamp.rule which
  already has a custom rule` (from `qt5_create_translation`) and ends with "Generate step
  failed". This is expected: the Dockerfile tolerates the non-zero exit and the build
  proceeds. It may mean the translation files are incomplete in the image.
- The OpenToonz libraries install to `/opt/opentoonz/lib/opentoonz`; both that path and
  `/opt/opentoonz/bin` are set in the image's `LD_LIBRARY_PATH` / `PATH`.

## Runtime

Wayland hosts use XWayland via the X11 socket.

### Help menu links

OpenToonz opens links (Help menu, online manual) through `xdg-open`, which needs a browser.
The container has no access to your host's browser, so the image includes Firefox (from
Mozilla's apt repo, since Ubuntu's `firefox` package is a snap stub that cannot run in
Docker) and sets `BROWSER` to a small wrapper (`open-url`) that runs `firefox --new-tab`, so every link opens as a new tab in the same Firefox window inside the container.

- The network is not the problem: the container uses `network_mode: host`, so no ports are
  blocked.
- This Firefox has its own empty profile: none of your host browser's logins, cookies or
  bookmarks, and its profile is discarded when the container is removed.
- `shm_size: 1gb` is set in `docker-compose.yml` because Firefox tabs crash with Docker's
  default 64 MB `/dev/shm`.
- Docker's default seccomp profile blocks user namespaces, so Firefox prints
  `Sandbox: CanCreateUserNamespace() ... EPERM` and runs with a reduced content sandbox.
  That is acceptable for browsing OpenToonz's documentation; do not use it for general
  browsing. The container is intentionally not run with extra privileges to avoid this.
- Firefox's default X11 remote mechanism hangs in this container, so a second link failed with
  "Firefox is already running, but is not responding". The image therefore installs
  `dbus-x11`, sets `MOZ_DBUS_REMOTE=1` and starts OpenToonz under `dbus-run-session`. That gives
  OpenToonz and the Firefox it launches one private D-Bus session inside the container, and
  later links open as new tabs in the existing window.
- Mounting the host's D-Bus session socket to open links in the host browser was considered
  and rejected: it would give the container access to your whole desktop session.

### Where your data lives

| What | Container path | Stored in | Survives `docker compose down` |
|---|---|---|---|
| Projects | `/home/toonz/projects` | `./projects` on the host (bind mount) | Yes, and visible from the host |
| Settings, stock assets, library, cache | `/home/toonz/.config` | Docker named volume `opentoonz-config` | Yes. Only `docker compose down -v` / `docker volume rm` deletes it |

OpenToonz's project root (`TOONZPROJECTS` in `~/.config/OpenToonz/SystemVar.ini`) is set to
`/home/toonz/projects`, so new projects are saved in `./projects` by default. The image
pre-seeds `SystemVar.ini` this way because OpenToonz's launcher script only writes it when
it is missing.

Notes:

- The config volume must be owned by `toonz`. The image creates `/home/toonz/.config` for
  this; without it Docker creates the volume root-owned and OpenToonz fails at startup with
  "Undefined or empty". If you ever see that, remove the volume and start again.
- A **volume that already existed** keeps its old `SystemVar.ini` (image changes don't
  overwrite volume contents). To point an existing volume at `./projects`, edit the file:

  ```bash
  docker run --rm -v mlw-opentoonz-docker_opentoonz-config:/v alpine sh -c \
    'sed -i "s|^TOONZPROJECTS=.*|TOONZPROJECTS=\"/home/toonz/projects\"|" /v/OpenToonz/SystemVar.ini \
     && chown 1000:1000 /v/OpenToonz/SystemVar.ini'
  ```

- Projects created earlier in the old default location stay inside the volume
  (`/home/toonz/.config/OpenToonz/stuff/projects`); copy them out if you want them in
  `./projects`.
- `./projects` must be writable by uid/gid 1000 (the image's `toonz` user, matching a typical
  first host user). For another uid, build with `UID=... GID=...`.
