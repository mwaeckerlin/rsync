# Changelog

- 2026-09-26 **1.3.1**
    - The image is headless: it contains rsync and its libraries only, without a shell, an interpreter or a package manager, and it runs as an unprivileged user instead of root
    - Data that only its owner may read is synchronised by running the container as that owner with `--user`; the README explains when root would be needed and what it costs
    - `/source` and `/target` are prepared as mount points, so new named volumes mounted there are writable without preparation
    - The rsync daemon runs from the same image, with a configuration of your own
    - New variant `mwaeckerlin/rsync:inotify` keeps a destination synchronised: one run at start, then a run whenever a file below the watched directories changes, with many changes at once collected into one run
        - configurable options, watched directories and the quiet time before a run
        - a failed run is logged and the watch goes on; configuration errors stop the container with a message that names the cause; `docker stop` ends it cleanly
    - New variant `mwaeckerlin/rsync:cron` synchronises on a schedule, at the start of the container and every hour; `RSYNC_SCHEDULE` sets another cron expression and `RSYNC_OPTIONS` other options, and an image derived from it brings its own crontab for other paths
    - `npm test` runs the whole suite: what the images contain, and real volumes synchronised once, on change, on a schedule, through the daemon, as a foreign owner, and with every configuration error
    - What the images do is written down in `FEATURES.md`, which test covers it in `TESTS.md`

- 2018-12-17 **1.3.0**
    - Built on the base image `mwaeckerlin/very-base`

- 2018-11-14 **1.2.0**
    - Smaller image: rsync installed without package cache

- 2017-10-03 **1.1.0**
    - Documentation of dry runs and of own options

- 2017-09-28 **1.0.0**
    - Image that runs `rsync -avP --delete` with the options and arguments given after the image name
