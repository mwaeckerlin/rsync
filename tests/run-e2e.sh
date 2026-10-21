#!/usr/bin/env bash
# End-to-end tests for mwaeckerlin/rsync, mwaeckerlin/rsync:inotify and
# mwaeckerlin/rsync:cron.
#
# Every test writes real files into real volumes and reads what arrived on the
# other side. Waiting is always for a state (a file present, a run ended), with
# a limit so that a defect ends in FAIL instead of a hang.
#
# Usage: bash tests/run-e2e.sh (the images must be built: npm run build)

set -uo pipefail

cd "$(dirname "$0")"
COMPOSE=(docker compose -f docker-compose.yml)
LIMIT=60    # seconds; an upper bound for a state to arrive, never a measurement
FOREIGN=4321:4321

PASS=0
FAIL=0
declare -a FAILED_NAMES

_pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  FAIL  $1: $2"; }
_check() { if eval "$2"; then _pass "$1"; else _fail "$1" "$3"; fi; }

cleanup() {
    "${COMPOSE[@]}" --profile manual down -v --remove-orphans > /dev/null 2>&1
}
trap cleanup EXIT

# run a shell command in the helper, as the images' user or as another one
_h() { "${COMPOSE[@]}" exec -T helper sh -c "$1"; }
_h_as() { "${COMPOSE[@]}" exec -T --user "$1" helper sh -c "$2"; }

# wait until a shell condition in the helper holds, at most $2 or LIMIT seconds
_wait() {
    local i
    for ((i = 0; i < ${2:-$LIMIT}; i++)); do
        _h "$1" && return 0
        sleep 1
    done
    return 1
}

_once() { "${COMPOSE[@]}" run --rm -T once "$@"; }

_count() {
    "${COMPOSE[@]}" logs --no-log-prefix "$1" 2>&1 | grep -c "^\*\*\*\* $2"
}

# a watching service is idle when every run it started has ended
_idle() {
    local i started ended
    for ((i = 0; i < LIMIT; i++)); do
        started=$(_count "$1" "Synchronising")
        ended=$(( $(_count "$1" "Synchronisation finished") + $(_count "$1" "Synchronisation failed") ))
        [[ ${started} -gt 0 && ${started} -eq ${ended} ]] && return 0
        sleep 1
    done
    return 1
}

_running() {
    [[ "$(docker inspect --format '{{.State.Running}}' "$("${COMPOSE[@]}" ps -a -q "$1")")" == true ]]
}

# the uid and gid of the images' run user, from the image's own /etc/passwd
container=$(docker create mwaeckerlin/rsync) || exit 1
IFS=: read -r RUN_UID RUN_GID < <(docker cp "${container}:/etc/passwd" - | tar -xO | awk -F: '$1 == "somebody" {print $3 ":" $4}')
docker rm "${container}" > /dev/null
export RUN_UID RUN_GID

echo "==> Starting the test stack"
cleanup
# the images under test create their volumes first, so the helper, which
# mounts the same volumes, finds them with the ownership of the images
_once --version > /dev/null || { echo "mwaeckerlin/rsync does not start"; exit 1; }
"${COMPOSE[@]}" create --build watch watch-dir watch-opts watch-fail daemon daemon-env cron cron-minute cron-own > /dev/null 2>&1
"${COMPOSE[@]}" up -d helper > /dev/null 2>&1

echo "==> mwaeckerlin/rsync"

_h 'mkdir -p /once/source/dir && echo alpha > /once/source/a.txt && echo beta > /once/source/dir/b.txt'
_once /source/ /target/ > /dev/null 2>&1
rc=$?
_check once_copies_the_tree \
    '[[ $rc -eq 0 ]] && _h "[ \"\$(cat /once/target/a.txt)\" = alpha ] && [ \"\$(cat /once/target/dir/b.txt)\" = beta ]"' \
    "exit code ${rc}, or the files did not arrive with their content"

_h 'rm /once/source/a.txt'
_once /source/ /target/ > /dev/null 2>&1
_check once_deletes_what_the_source_lost '_h "[ ! -e /once/target/a.txt ] && [ -f /once/target/dir/b.txt ]"' \
    "a.txt is still in the target, or b.txt vanished"

_h 'echo gamma > /once/source/c.txt'
_once -n /source/ /target/ > /dev/null 2>&1
_check once_dry_run_changes_nothing '_h "[ ! -e /once/target/c.txt ]"' "-n copied c.txt"

_h 'echo extra > /once/target/extra.txt'
"${COMPOSE[@]}" run --rm -T --entrypoint /usr/bin/rsync once -a /source/ /target/ > /dev/null 2>&1
_check once_own_options_replace_the_defaults '_h "[ -f /once/target/c.txt ] && [ -f /once/target/extra.txt ]"' \
    "without --delete extra.txt must stay and c.txt must arrive"

_h 'echo env > /once/source/env.txt'
"${COMPOSE[@]}" run --rm -T -e "RSYNC_OPTIONS=-a" once /source/ /target/ > /dev/null 2>&1
rc=$?
_check once_options_from_environment \
    '[[ $rc -eq 0 ]] && _h "[ -f /once/target/env.txt ] && [ -f /once/target/extra.txt ]"' \
    "exit code ${rc}, or env.txt did not arrive, or extra.txt was deleted although RSYNC_OPTIONS=-a has no --delete"

# a directory that only a foreign user may read: 700 and 600, owned by 4321
_h 'chmod 777 /once/source /once/target'
_h_as "${FOREIGN}" 'mkdir /once/source/foreign && echo secret > /once/source/foreign/secret && chmod 600 /once/source/foreign/secret && chmod 700 /once/source/foreign'
_once /source/foreign /target/denied/ > /dev/null 2>&1
rc=$?
_check once_foreign_data_is_refused_to_the_default_user '[[ $rc -eq 23 ]]' "exit code ${rc} instead of 23 (partial transfer)"
"${COMPOSE[@]}" run --rm -T --user "${FOREIGN}" once /source/foreign /target/ > /dev/null 2>&1
rc=$?
_check once_runs_as_the_owner_of_the_data \
    '[[ $rc -eq 0 ]] && _h_as "${FOREIGN}" "[ \"\$(cat /once/target/foreign/secret)\" = secret ] && [ \"\$(stat -c %u:%g /once/target/foreign/secret)\" = ${FOREIGN} ]"' \
    "exit code ${rc}, or the file did not arrive owned by ${FOREIGN}"

_h 'printf "log file = /dev/stdout\n[data]\npath = /target\nread only = no\nuse chroot = no\n" > /daemon/conf/rsyncd.conf'
"${COMPOSE[@]}" start daemon > /dev/null 2>&1
# push /source/dir/ to the module $1, again until the daemon has started
_push() {
    local i
    for ((i = 0; i < LIMIT; i++)); do
        _once /source/dir/ "$1" > /dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}
_check daemon_receives_a_push '_push rsync://daemon:8873/data/ && _h "[ \"\$(cat /daemon/data/b.txt)\" = beta ]"' \
    "the daemon did not accept the push, or b.txt did not arrive"

_h 'echo served > /denv/source/served.txt'
"${COMPOSE[@]}" start daemon-env > /dev/null 2>&1
_check daemon_modules_from_environment '_push rsync://daemon-env:8873/data/ && _h "[ \"\$(cat /denv/data/b.txt)\" = beta ]"' \
    "the writable module data of RSYNCD_MODULES did not accept the push, or b.txt did not arrive"

_once /source/dir/ rsync://daemon-env:8873/files/ > /dev/null 2>&1
rc=$?
_check daemon_read_only_module_refuses_a_push \
    '[[ $rc -ne 0 ]] && _h "[ ! -e /denv/source/b.txt ] && [ -f /denv/source/served.txt ]"' \
    "exit code ${rc}: the read-only module files accepted the push, or lost served.txt"

_once rsync://daemon-env:8873/files/ /target/pulled/ > /dev/null 2>&1
rc=$?
_check daemon_read_only_module_serves_its_files \
    '[[ $rc -eq 0 ]] && _h "[ \"\$(cat /once/target/pulled/served.txt)\" = served ]"' \
    "exit code ${rc}, or served.txt of the read-only module files did not arrive"

out=$("${COMPOSE[@]}" logs --no-log-prefix daemon-env 2>&1)
_check daemon_configuration_is_logged \
    '[[ "${out}" == *"[data]"*"path = /target"*"read only = no"*"[files]"*"path = /source"*"read only = yes"* ]]' \
    "the log does not show the configuration of RSYNCD_MODULES: ${out}"

# every value is refused before the daemon starts; the limit ends a daemon
# that started although it should not have
_modules_refused() {
    local value out rc
    for value in "$@"; do
        out=$(timeout "${LIMIT}" "${COMPOSE[@]}" run --rm -T -e "RSYNCD_MODULES=${value}" daemon-env 2>&1)
        rc=$?
        if [[ $rc -eq 0 || $rc -eq 124 || "${out}" != *"invalid RSYNCD_MODULES entry"* ]]; then
            echo "    ${value@Q}: exit code ${rc}: ${out}"
            return 1
        fi
    done
}
_modules_refused $'data=/target\nuid = 0' $'data=/target\n[evil]' 'data=target' 'data=/target;x' \
    'data=/target:rx' 'da ta=/target' 'global=/target' 'data=/target data=/source'
rc=$?
_check daemon_invalid_modules_are_refused '[[ $rc -eq 0 ]]' "a value of RSYNCD_MODULES was not refused"

echo "==> mwaeckerlin/rsync:cron"

_h 'echo initial > /cron/source/initial.txt'
_h 'echo extra > /minute/target/extra.txt'
_h 'mkdir /own/source/sub'
"${COMPOSE[@]}" start cron cron-minute cron-own > /dev/null 2>&1

_check cron_initial_run '_wait "[ \"\$(cat /cron/target/initial.txt 2>/dev/null)\" = initial ]"' \
    "initial.txt did not arrive at the start of the container"

# `--check` fills in the environment of that run like the start does; line 5
# of the crontab is the scheduled job
_cron_check() { "${COMPOSE[@]}" run --rm -T --no-deps "$@" 2>&1; }

out=$(_cron_check cron --check --at 2026-09-26T10:30Z)
rc=$?
_check cron_hourly_schedule \
    '[[ $rc -eq 0 && "${out}" == *"/etc/cron.d/rsync:5 next 2026-09-26 11:00 rsync -avP --delete /source/ /target/"* ]]' \
    "exit code ${rc}: ${out}"

out=$(_cron_check -e "RSYNC_SCHEDULE=*/5 * * * *" cron --check --at 2026-09-26T10:31Z)
rc=$?
_check cron_schedule_from_environment \
    '[[ $rc -eq 0 && "${out}" == *"/etc/cron.d/rsync:5 next 2026-09-26 10:35 rsync -avP --delete /source/ /target/"* ]]' \
    "exit code ${rc}: ${out}"

out=$(_cron_check -e "RSYNC_OPTIONS=-a --inplace" cron --check --at 2026-09-26T10:30Z)
rc=$?
_check cron_options_from_environment \
    '[[ $rc -eq 0 && "${out}" == *"/etc/cron.d/rsync:5 next 2026-09-26 11:00 rsync -a --inplace /source/ /target/"* ]]' \
    "exit code ${rc}: ${out}"

out=$(_cron_check -e "RSYNC_SCHEDULE=61 * * * *" cron --check)
rc=$?
_check cron_invalid_schedule_is_refused '[[ $rc -ne 0 && "${out}" == *"/etc/cron.d/rsync:5"* ]]' \
    "exit code ${rc}: ${out}"

# a job every minute: the file arrives at the next full minute at the latest,
# so the limit is two minutes
_h 'echo minute > /minute/source/minute.txt'
_h 'echo sub > /own/source/sub/sub.txt'
_check cron_environment_schedule_runs \
    '_wait "[ -f /minute/target/minute.txt ]" 120 && _h "[ -f /minute/target/extra.txt ]"' \
    "minute.txt did not arrive within two minutes, or extra.txt was deleted although RSYNC_OPTIONS=-a has no --delete"
_check cron_own_crontab_replaces_the_default \
    '_wait "[ -f /own/target/sub.txt ]" 120' \
    "sub.txt of the source directory the own crontab names did not arrive within two minutes"

echo "==> mwaeckerlin/rsync:inotify"

_h 'echo initial > /watch/source/initial.txt'
_h 'mkdir /dir/source/only && echo outside > /dir/source/outside.txt'
_h 'echo keep > /opts/source/keep.txt'
"${COMPOSE[@]}" start watch watch-dir watch-opts watch-fail > /dev/null 2>&1

_check watch_initial_run '_wait "[ -f /watch/target/initial.txt ]"' "initial.txt did not arrive"

_h 'echo new > /watch/source/new.txt'
_check watch_change_is_synchronised '_wait "[ \"\$(cat /watch/target/new.txt 2>/dev/null)\" = new ]"' "new.txt did not arrive"

_h 'mkdir -p /watch/source/sub/deeper && echo deep > /watch/source/sub/deeper/file.txt'
_check watch_new_directory_is_watched '_wait "[ -f /watch/target/sub/deeper/file.txt ]"' "the file in the new directory did not arrive"
_idle watch
_h 'echo later > /watch/source/sub/deeper/later.txt'
_check watch_change_inside_a_new_directory '_wait "[ -f /watch/target/sub/deeper/later.txt ]"' \
    "a change inside a directory created after the start did not arrive"

# the file must have arrived before its deletion can be measured
_h 'echo gone > /watch/source/gone.txt'
_check watch_deletion_is_synchronised \
    '_wait "[ -f /watch/target/gone.txt ]" && _h "rm /watch/source/gone.txt" && _wait "[ ! -e /watch/target/gone.txt ]"' \
    "gone.txt did not arrive, or is still in the target after its deletion"

_idle watch
before=$(_count watch "Synchronising")
_h 'for i in $(seq 1 50); do echo $i > /watch/source/burst-$i; done'
_wait '[ "$(ls /watch/target | grep -c ^burst-)" -eq 50 ]'
_idle watch
runs=$(( $(_count watch "Synchronising") - before ))
_check watch_burst_becomes_one_run '[[ ${runs} -eq 1 ]]' "50 files written at once caused ${runs} runs"

_check watch_dir_synchronises_the_initial_tree '_wait "[ -f /dir/target/outside.txt ]"' "outside.txt did not arrive"
_h 'echo inside > /dir/source/only/inside.txt'
_check watch_dir_change_in_the_watched_directory '_wait "[ -f /dir/target/only/inside.txt ]"' "inside.txt did not arrive"

_check watch_opts_initial_run '_wait "[ -f /opts/target/keep.txt ]"' "keep.txt did not arrive"
_h 'rm /opts/source/keep.txt && echo trigger > /opts/source/trigger.txt'
_check watch_opts_replace_the_defaults \
    '_wait "[ -f /opts/target/trigger.txt ]" && _idle watch-opts && _h "[ -f /opts/target/keep.txt ]"' \
    "RSYNC_OPTIONS=-a must not delete keep.txt"

_wait_count() {
    local i
    for ((i = 0; i < LIMIT; i++)); do
        [[ $(_count "$1" "$2") -ge $3 ]] && return 0
        sleep 1
    done
    return 1
}
_check watch_fail_is_logged '_wait_count watch-fail "Synchronisation failed" 1' "the failed initial run was not logged"
_h 'echo retry > /fail/source/retry.txt'
_check watch_fail_keeps_watching '_wait_count watch-fail "Synchronisation failed" 2 && _running watch-fail' \
    "no second run after a change, or the container ended"

out=$("${COMPOSE[@]}" run --rm -T -e DELAY=abc watch 2>&1)
rc=$?
_check invalid_delay_is_refused '[[ $rc -ne 0 && "${out}" == *"DELAY must be a whole number of seconds"* ]]' \
    "exit code ${rc}: ${out}"

out=$("${COMPOSE[@]}" run --rm -T watch-bare 2>&1)
rc=$?
_check missing_arguments_are_refused '[[ $rc -ne 0 && "${out}" == *"give the source and the destination"* ]]' \
    "exit code ${rc}: ${out}"

out=$("${COMPOSE[@]}" run --rm -T -e WATCH=/nonexistent watch 2>&1)
rc=$?
_check missing_watch_directory_is_refused '[[ $rc -ne 0 && "${out}" == *"/nonexistent"* && "${out}" == *"inotifywait ended"* ]]' \
    "exit code ${rc}: ${out}"

"${COMPOSE[@]}" stop -t 30 watch > /dev/null 2>&1
code=$(docker inspect --format '{{.State.ExitCode}}' "$("${COMPOSE[@]}" ps -a -q watch)")
_check watch_stops_cleanly '[[ ${code} -eq 0 ]]' "exit code ${code} after SIGTERM (137 means docker had to kill it)"

echo ""
echo "==> E2E results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
    echo "==> Failed tests: ${FAILED_NAMES[*]}"
    exit 1
fi
