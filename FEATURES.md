# Features

Numbered register of everything the three images do for the administrator who synchronises volumes with them; a number is never reused. Every feature is covered by tests listed in [TESTS.md](TESTS.md); the guard `tests/docs-contract.sh` fails when a feature has no test.

- **F1 One synchronisation** — `mwaeckerlin/rsync` runs `rsync -avP --delete` with the arguments given after the image name: the source tree arrives in the destination with its content, what the source no longer has is deleted in the destination, and `-n` shows what would happen without changing anything.
- **F2 Own options** — with `--entrypoint /usr/bin/rsync` the default options are gone and only the options after the image name apply.
- **F3 Headless images** — all three images contain rsync, the watching one also `inotifywait` and its entrypoint, the scheduled one the program of `mwaeckerlin/cron` and its schedule, with their libraries only: no shell, no interpreter, no package manager. All run as the unprivileged user `somebody`.
- **F4 Mount points for new volumes** — `/source` and `/target` exist in all three images and belong to `somebody`, so a new named volume mounted there is writable for the container without any preparation.
- **F5 Running as the owner of the data** — the images run under any user and group given with `docker run --user`, so data that only its owner may read is synchronised by running as that owner, and it arrives owned by that owner.
- **F6 Synchronisation on change** — `mwaeckerlin/rsync:inotify` synchronises once at start, then again whenever a file below the watched directories is written, created, deleted, moved or changes its attributes, including in directories created after the start.
- **F7 One run per burst of changes** — a run starts after `DELAY` seconds (default `2`) without a further change, so many changes written at once cause one run; a change during a run causes one more run after it.
- **F8 Watched directories** — `WATCH` names the directories to watch, separated by white space; without it the sources given as arguments are watched, which are all arguments that are no options except the last one.
- **F9 Options of the watching variant** — `RSYNC_OPTIONS` (default `-avP --delete`) replaces the options put in front of the arguments.
- **F10 Configuration errors are named** — a `DELAY` that is not a whole number of seconds, missing source or destination arguments, and a watched directory that does not exist end the container with a non-zero exit code and a message that names the cause.
- **F11 A failed run keeps the watch** — when rsync fails, the failure is logged with its exit code and the container goes on watching; the next change starts the next attempt.
- **F12 Clean stop** — `docker stop` passes the signal on to `inotifywait` and a running rsync, and the container ends with exit code `0` without being killed.
- **F13 rsync daemon** — with `--entrypoint /usr/bin/rsync` and `--daemon --no-detach --config=<file>`, `mwaeckerlin/rsync` serves the modules of that configuration, and a client pushes into them over `rsync://`.
- **F14 Scheduled synchronisation** — `mwaeckerlin/rsync:cron`, derived from `mwaeckerlin/cron`, runs `rsync -avP --delete /source/ /target/` at the start of the container and at minute 0 of every hour.
- **F15 Schedule and options from the environment** — `RSYNC_SCHEDULE` (default `0 * * * *`) is the cron expression of the scheduled run, `RSYNC_OPTIONS` (default `-avP --delete`) its options, the same variable as in the watching variant; `mwaeckerlin/cron` fills both into the crontab at start, and a schedule it does not accept stops the start with file and line.
- **F16 Own crontab** — an image derived from `mwaeckerlin/rsync:cron` replaces `/etc/cron.d/rsync` with its own crontab, and with it the paths and further jobs.
