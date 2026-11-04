# OpenToonz on Ubuntu 24.04 (Docker Compose)

Builds https://github.com/WizzerWorks/opentoonz from source (Qt5, Release) and runs the GUI via X11.

```bash
mkdir -p projects
docker compose build      # long: full OpenToonz compile (~20 min at BUILD_JOBS=2)
xhost +local:docker       # allow container to reach your X server (once per login)
UID=$(id -u) GID=$(id -g) docker compose up
```

## Options

Env vars or `.env`:

| Var | Default | Purpose |
|---|---|---|
| `OPENTOONZ_REPO` | HTTPS URL of WizzerWorks/opentoonz | Use `git@github.com:WizzerWorks/opentoonz.git` for SSH (needs a running `ssh-agent`; `SSH_AUTH_SOCK` is forwarded by BuildKit) |
| `OPENTOONZ_REF` | `magiclantern` | Branch or tag to build. See [Source branch](#source-branch) |
| `OPENTOONZ_REV` | `none` | Cache-buster for the `git clone` layer. See [After pushing new commits](#after-pushing-new-commits) |
| `BUILD_JOBS` | `2` | Parallel compile jobs. `0` = all cores (not recommended, see [Keeping the host responsive](#keeping-the-host-responsive)). Each C++ job can use 2-3 GB RAM |

## Source branch

The `magiclantern` branch carries fixes needed to compile with the GCC 13 / Qt 5 / glibc
shipped in Ubuntu 24.04 (`tcg/hash.h` `size_t` shadowing, a stray control character in
`twain.h`, missing `<QPainterPath>` includes, and the removed `<sys/sysctl.h>`).
Building `master` or `v1.4.0` will most likely fail to compile on this base image.

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

Projects are saved in `./projects`; settings persist in the `opentoonz-config` volume.
Wayland hosts use XWayland via the X11 socket.
