#!/usr/bin/env bash
# Image contract: all three shipped images must be headless and unprivileged.
#
# A production image must contain nothing that lets an attacker who reaches
# code execution pivot: no shell, no perl, no busybox, no package manager. The
# images ship rsync (the single run its entrypoint and the directory of the
# daemon configuration, the inotify variant also inotifywait and its
# entrypoint, the cron variant the cron program and its schedule), their
# libraries, and two empty mount points — nothing else.
#
# The interpreter checks run the interpreter as the container entrypoint
# instead of asking the image to look at its own filesystem: a headless image
# has no `ls` either, so a missing tool must be detected from outside. What is
# in the image is read by exporting it. `--pull=never` keeps docker from
# silently pulling a stale image from the registry when the local build is
# missing; that would test the wrong artefact.
#
# Usage: tests/image-contract.sh

set -uo pipefail

PASS=0
FAIL=0
declare -a FAILED_NAMES

_pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  FAIL  $1: $2"; }

# Absence of the interpreter is the pass condition, so the image itself must be
# present — otherwise every check would "pass" on a nonexistent image.
_image_exists() {
    local image="$1"
    if docker image inspect "${image}" > /dev/null 2>&1; then
        return 0
    fi
    _fail "${image}_image_exists" "image not built — run 'npm run build' first"
    return 1
}

_no_interpreter() {
    local image="$1" path="$2" name="$3"
    shift 3
    if docker run --rm --pull=never --entrypoint "${path}" "${image}" "$@" > /dev/null 2>&1; then
        _fail "${image}_no_${name}" "${path} exists — image is not headless"
    else
        _pass "${image}_no_${name}"
    fi
}

# a program in the image starts: its libraries are all there
_starts() {
    local image="$1" path="$2" name="$3" expected="$4" output
    shift 4
    output=$(docker run --rm --pull=never --entrypoint "${path}" "${image}" "$@" 2>&1)
    if [[ "${output}" == *"${expected}"* && "${output}" != *"Error loading shared library"* ]]; then
        _pass "${image}_${name}"
    else
        _fail "${image}_${name}" "${path} does not start: ${output}"
    fi
}

_contents() {
    local container
    container=$(docker create "$1") || return 1
    docker export "${container}" | tar -tv --numeric-owner
    docker rm "${container}" > /dev/null
}

# uid/gid of the image's run user, read from the image's own /etc/passwd
_run_user() {
    local container
    container=$(docker create "$1") || return 1
    docker cp "${container}:/etc/passwd" - | tar -xO | awk -F: '$1 == "somebody" {print $3 "/" $4}'
    docker rm "${container}" > /dev/null
}

# `tar -tv` prints mode, owner/group, size, date, time and name; the name is
# matched as the last field, so a path is found whatever its owner.
_holds() {
    local image="$1" path="$2" name="$3"
    if echo "${CONTENTS}" | awk '{print $NF}' | grep -qx "${path}"; then
        _pass "${image}_${name}"
    else
        _fail "${image}_${name}" "${path} is not in the image"
    fi
}

_holds_not() {
    local image="$1" path="$2" name="$3"
    if echo "${CONTENTS}" | awk '{print $NF}' | grep -qx "${path}"; then
        _fail "${image}_${name}" "${path} is in the image"
    else
        _pass "${image}_${name}"
    fi
}

_owned_by_user() {
    local image="$1" path="$2" name="$3" owner
    owner=$(echo "${CONTENTS}" | awk -v p="${path}" '$NF == p {print $2}')
    if [[ -n "${RUN_USER}" && "${owner}" == "${RUN_USER}" ]]; then
        _pass "${image}_${name}"
    else
        _fail "${image}_${name}" "${path} belongs to '${owner}' instead of somebody (${RUN_USER})"
    fi
}

# a directory carries exactly this mode, as `tar -tv` prints it
_mode() {
    local image="$1" path="$2" expected="$3" name="$4" mode
    mode=$(echo "${CONTENTS}" | awk -v p="${path}" '$NF == p {print $1}')
    if [[ "${mode}" == "${expected}" ]]; then
        _pass "${image}_${name}"
    else
        _fail "${image}_${name}" "${path} has mode '${mode}' instead of ${expected}"
    fi
}

_inspect() {
    local image="$1" format="$2" expected="$3" name="$4" actual
    actual=$(docker inspect --format "${format}" "${image}")
    if [[ "${actual}" == "${expected}" ]]; then
        _pass "${image}_${name}"
    else
        _fail "${image}_${name}" "${actual} instead of ${expected}"
    fi
}

# an environment variable of the image carries exactly this value
_env() {
    local image="$1" expected="$2" name="$3"
    if docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${image}" | grep -qxF "${expected}"; then
        _pass "${image}_${name}"
    else
        _fail "${image}_${name}" "the image has no ${expected}"
    fi
}

echo "==> Image contract: headless images"

for image in mwaeckerlin/rsync mwaeckerlin/rsync:inotify mwaeckerlin/rsync:cron; do
    _image_exists "${image}" || continue
    _no_interpreter "${image}" /bin/sh       sh      -c :
    _no_interpreter "${image}" /bin/bash     bash    -c :
    _no_interpreter "${image}" /bin/busybox  busybox ls /
    _no_interpreter "${image}" /usr/bin/perl perl    -e 1

    CONTENTS=$(_contents "${image}")
    RUN_USER=$(_run_user "${image}")
    _holds         "${image}" usr/bin/rsync  holds_rsync
    _starts        "${image}" /usr/bin/rsync starts_rsync "rsync  version" --version
    _holds_not     "${image}" sbin/apk       no_package_manager
    _owned_by_user "${image}" source/        source_writable
    _owned_by_user "${image}" target/        target_writable

    _inspect "${image}" '{{.Config.User}}' somebody unprivileged_user
done

image=mwaeckerlin/rsync
if _image_exists "${image}"; then
    CONTENTS=$(_contents "${image}")
    _holds   "${image}" usr/bin/init holds_init
    _inspect "${image}" '{{json .Config.Entrypoint}}' '["/usr/bin/init"]' init_entrypoint
    _env     "${image}" "RSYNC_OPTIONS=-avP --delete" default_options
    _env     "${image}" "RSYNCD_MODULES=" default_modules
    _mode    "${image}" run/rsyncd/ drwxrwxrwt daemon_directory_writable
fi

image=mwaeckerlin/rsync:inotify
if _image_exists "${image}"; then
    CONTENTS=$(_contents "${image}")
    _holds   "${image}" usr/bin/inotifywait holds_inotifywait
    _starts  "${image}" /usr/bin/inotifywait starts_inotifywait "inotifywait" --help
    _holds   "${image}" usr/bin/rsync-watch holds_entrypoint
    _inspect "${image}" '{{json .Config.Entrypoint}}' '["/usr/bin/rsync-watch"]' entrypoint
fi

image=mwaeckerlin/rsync:cron
if _image_exists "${image}"; then
    CONTENTS=$(_contents "${image}")
    _holds   "${image}" usr/bin/cron      holds_cron
    _holds   "${image}" etc/cron.d/rsync  holds_schedule
    _inspect "${image}" '{{json .Config.Entrypoint}}' '["/usr/bin/cron"]' cron_entrypoint
    _env "${image}" "RSYNC_SCHEDULE=0 * * * *"    default_schedule
    _env "${image}" "RSYNC_OPTIONS=-avP --delete" default_cron_options
fi

echo ""
echo "==> Image contract results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
    echo "==> Failed contracts: ${FAILED_NAMES[*]}"
    exit 1
fi
