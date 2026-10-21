# Tests

Register of all tests, grouped by kind and sorted by the [FEATURES.md](FEATURES.md) number each test covers. `npm test` runs everything; the guard `tests/docs-contract.sh` fails when a feature has no test entry here, when a test listed here does not exist in its script, or when a test is left out.

The e2e stack (`tests/docker-compose.yml`) gives every long-running service of the watching and the scheduled variant volumes of its own, so no test triggers another. A foreign `alpine` container writes and reads the files, as the unprivileged user of the images. Every wait is for a state — a file present, every started run ended — with a limit that turns a defect into a failure instead of a hang: 60 seconds, and 120 seconds for a job that runs every minute, whose next full minute can be up to 60 seconds away.

## E2E — synchronisation of real volumes (`tests/run-e2e.sh`)

- **F1** `tests/run-e2e.sh` › once_copies_the_tree — a file and a file in a subdirectory arrive with their content.
- **F1** `tests/run-e2e.sh` › once_deletes_what_the_source_lost — a file deleted in the source disappears in the destination, the others stay.
- **F1** `tests/run-e2e.sh` › once_dry_run_changes_nothing — with `-n` a new file does not arrive.
- **F2** `tests/run-e2e.sh` › once_own_options_replace_the_defaults — with `--entrypoint /usr/bin/rsync` and `-a` a file only the destination has stays, because `--delete` is gone.
- **F4** `tests/run-e2e.sh` › once_copies_the_tree — the new named volumes on `/source` and `/target` are written by the unprivileged user.
- **F5** `tests/run-e2e.sh` › once_foreign_data_is_refused_to_the_default_user — a directory with mode 700 of uid 4321 ends the default run with exit code 23.
- **F5** `tests/run-e2e.sh` › once_runs_as_the_owner_of_the_data — with `--user 4321:4321` the same file arrives, owned by 4321.
- **F6** `tests/run-e2e.sh` › watch_initial_run — a file written before the start arrives.
- **F6** `tests/run-e2e.sh` › watch_change_is_synchronised, watch_deletion_is_synchronised — a new file arrives; a file that has arrived disappears once it is deleted in the source.
- **F6** `tests/run-e2e.sh` › watch_new_directory_is_watched, watch_change_inside_a_new_directory — a directory created after the start is watched, a later change inside it arrives.
- **F7** `tests/run-e2e.sh` › watch_burst_becomes_one_run — fifty files written at once cause exactly one run.
- **F8** `tests/run-e2e.sh` › watch_initial_run — without `WATCH` the source given as argument is watched.
- **F8** `tests/run-e2e.sh` › watch_dir_synchronises_the_initial_tree, watch_dir_change_in_the_watched_directory — with `WATCH=/source/only` a change in that directory starts a run of the whole source.
- **F9** `tests/run-e2e.sh` › watch_opts_initial_run, watch_opts_replace_the_defaults — with `RSYNC_OPTIONS=-a` a file deleted in the source stays in the destination.
- **F10** `tests/run-e2e.sh` › invalid_delay_is_refused, missing_arguments_are_refused, missing_watch_directory_is_refused — non-zero exit code and the message naming the cause.
- **F11** `tests/run-e2e.sh` › watch_fail_is_logged, watch_fail_keeps_watching — a destination the user cannot write is logged as failed, and the next change starts another run while the container keeps running.
- **F12** `tests/run-e2e.sh` › watch_stops_cleanly — `docker stop` ends the container with exit code 0.
- **F13** `tests/run-e2e.sh` › daemon_receives_a_push — a daemon with a module on `/target` receives a directory that `mwaeckerlin/rsync` pushes to `rsync://daemon:8873/data/`.
- **F14** `tests/run-e2e.sh` › cron_initial_run — a file written before the start arrives through the run at the start of the container.
- **F14** `tests/run-e2e.sh` › cron_hourly_schedule — `--check` accepts the crontab with the defaults filled in, and after 10:30 its next run is 11:00 with `rsync -avP --delete /source/ /target/`.
- **F15** `tests/run-e2e.sh` › cron_schedule_from_environment, cron_options_from_environment — with `RSYNC_SCHEDULE=*/5 * * * *` the next run after 10:31 is 10:35; with `RSYNC_OPTIONS=-a --inplace` the job is `rsync -a --inplace /source/ /target/`.
- **F15** `tests/run-e2e.sh` › cron_invalid_schedule_is_refused — `RSYNC_SCHEDULE=61 * * * *` ends with a non-zero exit code and names `/etc/cron.d/rsync:5`.
- **F15** `tests/run-e2e.sh` › cron_environment_schedule_runs — a container with `RSYNC_SCHEDULE=* * * * *` and `RSYNC_OPTIONS=-a` brings a new file within two minutes and keeps a file only the destination has.
- **F16** `tests/run-e2e.sh` › cron_own_crontab_replaces_the_default — an image derived with its own crontab that synchronises `/source/sub/` every minute brings a file of that directory within two minutes.
- **F17** `tests/run-e2e.sh` › once_options_from_environment — with `RSYNC_OPTIONS=-a` a new file arrives and a file only the destination has stays, because `--delete` is gone.
- **F18** `tests/run-e2e.sh` › daemon_modules_from_environment — a daemon with `RSYNCD_MODULES=data=/target:rw files=/source` receives a directory that `mwaeckerlin/rsync` pushes to `rsync://daemon-env:8873/data/`.
- **F18** `tests/run-e2e.sh` › daemon_read_only_module_refuses_a_push, daemon_read_only_module_serves_its_files — a push into the module `files` without `:rw` fails and leaves its files as they are; a pull from it brings its file.
- **F18** `tests/run-e2e.sh` › daemon_configuration_is_logged — the container log shows both modules with their paths and `read only = no` and `read only = yes`.
- **F18** `tests/run-e2e.sh` › daemon_invalid_modules_are_refused — an entry with a newline and a parameter or a section after it, a relative path, a `;` in the path, the mode `:rx`, a name with a space, the name `global` and a name given twice each end the container with a non-zero exit code and `invalid RSYNCD_MODULES entry`, before a daemon starts.

## Image contract (`tests/image-contract.sh`)

- **F1** `tests/image-contract.sh` › init_entrypoint — `mwaeckerlin/rsync` starts `/usr/bin/init`, which runs rsync with the default options of F17.
- **F3** `tests/image-contract.sh` › _no_interpreter, no_package_manager, unprivileged_user — no `sh`, `bash`, `busybox` or `perl` starts, `apk` is absent, and all three images run as `somebody`.
- **F3** `tests/image-contract.sh` › holds_rsync, holds_init, holds_inotifywait, holds_entrypoint, entrypoint — the programs are in the images, and the watching image starts `rsync-watch`.
- **F3** `tests/image-contract.sh` › starts_rsync, starts_inotifywait — `rsync` and `inotifywait` start in the images, so none of their libraries is missing.
- **F4** `tests/image-contract.sh` › source_writable, target_writable — `/source` and `/target` belong to the uid and gid of `somebody`.
- **F14** `tests/image-contract.sh` › holds_cron, holds_schedule, cron_entrypoint — the cron variant carries the cron program and `/etc/cron.d/rsync`, and starts `cron`.
- **F15** `tests/image-contract.sh` › default_schedule, default_cron_options — the image carries `RSYNC_SCHEDULE=0 * * * *` and `RSYNC_OPTIONS=-avP --delete`.
- **F17** `tests/image-contract.sh` › default_options — `mwaeckerlin/rsync` carries `RSYNC_OPTIONS=-avP --delete`.
- **F18** `tests/image-contract.sh` › default_modules, daemon_directory_writable — `mwaeckerlin/rsync` carries `RSYNCD_MODULES` empty, and `/run/rsyncd` with the mode `1777`, so the configuration is written under every `--user`.

## Docs contract (`tests/docs-contract.sh`)

- **F1–F18** `tests/docs-contract.sh` › unique_feature_numbers, every_feature_tested, no_dangling_references, every_listed_test_exists, no_skipped_tests — every feature of `FEATURES.md` carries an entry here, every number used here exists as a feature, every test named here exists, no number is defined twice and no test is left out.
