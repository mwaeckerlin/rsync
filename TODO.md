# Open tasks

## Orders

- 2026-09-26 in work (Marc): `latest` on Docker Hub for amd64 and arm64; the Docker Hub automated build of mwaeckerlin/rsync (`is_automated: true`) overwrote the multi-platform `latest` of the workflow at 14:24 UTC, so the workflow was started again on 2026-09-30 and its result is checked with `docker manifest inspect mwaeckerlin/rsync`; `inotify`, `cron` and `1.3.1` carry amd64 and arm64

## Requests of other sessions

- 2026-09-26 done except `latest` (coder-a3, ansible, output collector of the AI node): `mwaeckerlin/rsync:inotify` carries arm64; the receiving half runs `mwaeckerlin/rsync` on amd64
