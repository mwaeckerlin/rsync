# Docker Image for Simple Synchronization of Volumes

Three headless images that synchronise volumes with `rsync`: `mwaeckerlin/rsync` runs once or serves an rsync daemon, `mwaeckerlin/rsync:inotify` keeps a destination synchronised whenever the source changes, `mwaeckerlin/rsync:cron` synchronises on a schedule.

Other than `docker cp`, rsync synchronises incrementally, it can be restarted after a failure, and it is robust with large volumes of several TB, where `docker cp` often fails. Use it to back up or migrate volumes, or to mirror a directory continuously to another volume or an rsync server.

All three are runtime images on `mwaeckerlin/scratch`: they contain rsync with its libraries (the single run also its entrypoint, the watching variant also `inotifywait` and its entrypoint, the scheduled variant the cron program of `mwaeckerlin/cron`), no shell, no interpreter, no package manager, and they run as the unprivileged user `somebody`.

## Single run

`mwaeckerlin/rsync` runs `rsync -avP --delete` with your additional options and arguments. `--rm` removes the container after the synchronisation.

Synchronise `/var/lib/mysql` of a mysql container into the volume `backup`:

```bash
docker run --rm \
      -v backup:/target \
      --volumes-from mysql \
      --user 999:999 \
      mwaeckerlin/rsync \
      /var/lib/mysql/ /target/
```

`--user` is the owner of the data, see [User and permissions](#user-and-permissions).

Dry run, just add `-n`:

```bash
docker run --rm -v source:/source -v target:/target mwaeckerlin/rsync -n /source/ /target/
```

To use other options than `-avP --delete`, set them in `RSYNC_OPTIONS`, e.g. `rsync -a` without deleting:

```bash
docker run --rm -v source:/source -v target:/target \
      -e RSYNC_OPTIONS="-a" \
      mwaeckerlin/rsync \
      /source/ /target/
```

Setting the entrypoint to rsync does the same; then only the options after the image name apply:

```bash
docker run --rm -v source:/source -v target:/target \
      --entrypoint /usr/bin/rsync \
      mwaeckerlin/rsync \
      -a /source/ /target/
```

### Configuration

- `RSYNC_OPTIONS`: the options in front of the arguments, separated by white space (default `-avP --delete`), the same variable as in the watching and the scheduled variant; an empty value keeps the default
- `RSYNCD_MODULES`: the modules of the rsync daemon, separated by white space (default empty: no daemon, one synchronisation); see [rsync daemon](#rsync-daemon)

## rsync daemon

With `RSYNCD_MODULES`, `mwaeckerlin/rsync` serves an rsync daemon on port 8873 without a configuration file of yours. Every entry is `name=path`, a module that clients read from, or `name=path:rw`, a module that clients also write into; `name=path:ro` says read only explicitly. A module `data` that receives into the volume on `/target`:

```bash
docker run -d -v rsyncd-data:/target -p 8873:8873 \
      -e RSYNCD_MODULES="data=/target:rw" \
      mwaeckerlin/rsync
```

A client pushes into it with `mwaeckerlin/rsync /source/ rsync://<host>:8873/data/`. At start the container prints the configuration it wrote to `/run/rsyncd/rsyncd.conf`, and the daemon logs every transfer to the container log. Arguments after the image name are passed on to `rsync --daemon`; `RSYNC_OPTIONS` does not apply to the daemon.

A name holds letters, digits, `.`, `_` and `-`, and is neither `global` nor given twice; a path starts with `/` and holds letters, digits, `/`, `.`, `_` and `-`. Any other entry, also one without `=`, ends the container before the daemon starts, with the message `invalid RSYNCD_MODULES entry '<entry>'` and what is wrong with it.

The modules have no authentication: whoever reaches port 8873 reads every module and writes into every `:rw` module. Publish the port only into a network you trust. For users, passwords, host lists or other parameters, mount a configuration of your own instead:

```bash
docker run -d --entrypoint /usr/bin/rsync -v rsyncd:/etc/rsyncd -p 8873:8873 \
      mwaeckerlin/rsync \
      --daemon --no-detach --port=8873 --config=/etc/rsyncd/rsyncd.conf
```

The daemon runs as `somebody` as well: a port above 1024, no `uid`/`gid` switch and no `use chroot` in the configuration, unless you start it with `--user` of your choice.

## Watching variant

`mwaeckerlin/rsync:inotify` synchronises once at start and then again whenever `inotifywait` reports a change below the watched directories: a file written, created, deleted, moved, or with changed attributes, also in directories created later. The arguments are the same as for `mwaeckerlin/rsync`.

```bash
docker run -d --name mirror -v source:/source -v target:/target \
      mwaeckerlin/rsync:inotify /source/ /target/
```

In `docker-compose.yml`:

```yaml
services:
  mirror:
    image: mwaeckerlin/rsync:inotify
    command: ["/source/", "/target/"]
    volumes:
      - source:/source
      - target:/target
    restart: unless-stopped
```

### Configuration

- `RSYNC_OPTIONS`: the options in front of the arguments, separated by white space (default `-avP --delete`)
- `WATCH`: the directories to watch, separated by white space (default: the sources among the arguments — every argument that is no option, except the last one, which is the destination)
- `DELAY`: seconds without a further change before a run starts (default `2`); many changes written at once become one run, and a change during a run causes one more run after it

A path with a space cannot be given in `RSYNC_OPTIONS` or `WATCH`; give such a path as an argument. An option with a value given as a separate argument (`--exclude foo`) makes its value look like a source, so set `WATCH` in that case or write the option with `=` (`--exclude=foo`).

Pushing the changes of a local directory to an rsync server and removing what arrived:

```yaml
    command: ["/output/", "rsync://sink/output/node-1/"]
    environment:
      RSYNC_OPTIONS: "--archive --partial-dir=.rsync-partial --prune-empty-dirs --remove-source-files"
```

### Behaviour

- **Nothing is lost between start and watch:** the first run starts once the watches stand, so a change during the start is part of it.
- **A failed run keeps the watch:** the failure is logged with rsync's exit code, and the next change starts the next attempt. Exit code 24 (files vanished during the transfer) is normal while the source changes.
- **Clean stop:** `docker stop` is passed on to `inotifywait` and a running rsync; the container ends with exit code 0. The initial run of the next start synchronises the changes that came after the last run.
- **Log:** every run is announced with `**** Synchronising: <cause>` and ends with `**** Synchronisation finished` or `**** Synchronisation failed with exit code <n>`; rsync's own output stands between.

Limitations:

- **The destination must lie outside the watched directories**, otherwise every run triggers the next one.
- **inotify sees changes of this kernel only:** a change written by another host into a network file system (NFS, CephFS, SMB) is not reported. Watch on the host that writes.
- **Large trees need inotify watches:** one watch per directory, limited by `fs.inotify.max_user_watches` of the host (`sysctl fs.inotify.max_user_watches`); when it is too small, the container ends with the message of `inotifywait`.

## Scheduled variant

`mwaeckerlin/rsync:cron` is `mwaeckerlin/cron` with rsync. It runs `rsync -avP --delete /source/ /target/` at the start of the container and at minute 0 of every hour:

```bash
docker run -d --name backup -v data:/source -v backup:/target mwaeckerlin/rsync:cron
```

### Configuration

- `RSYNC_SCHEDULE`: the cron expression of the scheduled run, five fields or a macro such as `@daily` (default `0 * * * *`, minute 0 of every hour)
- `RSYNC_OPTIONS`: the options of rsync, separated by white space (default `-avP --delete`), as in the watching variant

Every night at 02:30, without deleting in the destination:

```bash
docker run -d --name backup -v data:/source -v backup:/target \
      -e RSYNC_SCHEDULE="30 2 * * *" -e RSYNC_OPTIONS="-a" \
      mwaeckerlin/rsync:cron
```

The crontab [cron.d/rsync](cron.d/rsync) holds `${RSYNC_SCHEDULE}` and `${RSYNC_OPTIONS}`, and `mwaeckerlin/cron` fills them in from the environment at start. A schedule it does not accept stops the start with the file and the line. `--check` shows the schedule with the values filled in:

```bash
docker run --rm -e RSYNC_SCHEDULE="30 2 * * *" mwaeckerlin/rsync:cron --check
```

### Own crontab

Other paths or further jobs replace the crontab in an image derived from this one:

```Dockerfile
FROM mwaeckerlin/rsync:cron
COPY rsync /etc/cron.d/rsync
```

With the crontab file `rsync`, here a subdirectory every night at 02:30:

```crontab
# min hour day month weekday command
30    2    *   *     *       rsync -a /source/data/ /target/
```

The crontab syntax, the time zone `TZ`, the log and `--check` are those of [mwaeckerlin/cron](https://github.com/mwaeckerlin/cron). A command runs without a shell, so pipes and redirections are refused at start.

Limitation: `mwaeckerlin/cron` starts a job at its time also while the previous run of the same job is still running. A synchronisation that takes longer than the interval then runs twice at once into the same destination, so the interval has to be longer than the longest run.

## User and permissions

All three images run as `somebody`. Two cases need nothing further:

- **New named volumes** on `/source` and `/target`: the images carry both directories owned by `somebody`, and docker gives a new volume the ownership of its mount point.
- **Data readable by everybody** into a destination `somebody` may write.

Data that only its owner may read, a database directory for instance, is synchronised as its owner: `docker run --user <uid>:<gid> …`. Running as another user than the owner, rsync reports `Permission denied` and ends with exit code 23 (partial transfer). On the host, `stat -c %u:%g <path>` shows the owner's uid and gid.

Keeping the owners of many different users, as in a migration of a whole volume with mixed owners, requires root. The images do not run as root by default; `--user 0:0` is your decision, and the price is that a defect or a manipulated source then acts with root's rights on every mounted volume.

## Build, run, test

Everything runs through the scripts in `package.json`:

```bash
npm run build            # build the three images from docker-compose.yml
npm start                # build them, synchronise volume source into volume target once, on change and every hour
npm run start:daemon     # the same in the background
npm stop                 # stop the containers and remove them
npm test                 # run every test of this project
npm run deploy           # push the three images to Docker Hub
```

`npm test` runs three groups, each also available on its own:

- `npm run test:docs` — every feature carries a test and no test is left out
- `npm run test:image` — the three images are headless, unprivileged, and carry their programs, mount points and defaults
- `npm run test:e2e` — real volumes synchronised once, through the daemon with a mounted configuration and with modules from the environment, on change and on a schedule, including foreign owners, bursts of changes, schedules and options from the environment, an own crontab, configuration errors, a failing destination and the stop

[FEATURES.md](FEATURES.md) lists what the images do, [TESTS.md](TESTS.md) which test covers it.

## Publishing for amd64 and arm64

[.github/workflows/docker.yml](.github/workflows/docker.yml) publishes the three images to Docker Hub for `linux/amd64` and `linux/arm64`, on every push to the default branch, weekly on Monday at 06:17 UTC (one hour after `mwaeckerlin/cron`), and on demand. It calls the reusable workflow `docker-image.yml` of `mwaeckerlin/scratch`, which builds every image of all mwaeckerlin repositories the same way:

1. On a native runner per architecture (`ubuntu-24.04`, `ubuntu-24.04-arm`), the images of `docker-compose.yml` are built and `npm test` tests them.
2. Each runner pushes its tested images with `npm run deploy` under an architecture tag: `latest-amd64`, `latest-arm64`, `inotify-amd64`, `inotify-arm64`, `cron-amd64`, `cron-arm64`.
3. Only when every architecture is green, the last job joins them into the tags `latest`, `inotify` and `cron`, from which docker pulls what fits the host. Each of them is also published with the build date and the version of `package.json`: `latest`, `YYYYMMDD`, `<version>` and `<version>-YYYYMMDD`, and for the variants `inotify-YYYYMMDD`, `inotify-<version>`, `inotify-<version>-YYYYMMDD`, the same for `cron`.

The setup, the Docker Hub token and the order of the base images are described in the README of `mwaeckerlin/scratch`. A Docker Hub automated build on the same repository must be switched off, or it overwrites `latest` with an amd64-only image.

## Internals

- `Dockerfile` builds `mwaeckerlin/rsync`: rsync from the Alpine package of `mwaeckerlin/very-base`, copied with its libraries onto `mwaeckerlin/scratch`, and `init`, a static C++ program in [init.cpp](init.cpp), as the entrypoint. A headless image has no shell to read the environment, so `init` puts `RSYNC_OPTIONS` in front of the arguments, or checks `RSYNCD_MODULES` and writes the daemon configuration to `/run/rsyncd/rsyncd.conf`, and then replaces itself with rsync. `/run/rsyncd` has the mode `1777`, so `init` writes there under every `--user`.
- `Dockerfile.inotify` builds `mwaeckerlin/rsync:inotify`: rsync with its libraries plus `inotifywait` and `rsync-watch`, a static C++ program in [rsync-watch.cpp](rsync-watch.cpp). A headless image has no shell to run a watch loop, so `rsync-watch` is the entrypoint: it starts `inotifywait -m -r`, reads its events, waits for `DELAY` seconds of quiet, starts rsync, passes signals on and, as process 1, reaps what rsync leaves behind.
- `Dockerfile.cron` builds `mwaeckerlin/rsync:cron`: rsync with its libraries, copied onto `mwaeckerlin/cron`, and the crontab [cron.d/rsync](cron.d/rsync). It is built after `mwaeckerlin/cron`, whose image it starts from.
- All three images follow the rolling Alpine package of rsync; rebuild and redeploy regularly to receive its security fixes.
