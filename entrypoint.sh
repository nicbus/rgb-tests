#!/usr/bin/env bash

# match internal with external user/group IDs
if [ "$MY_UID" != 1000 ]; then
    usermod -u "$MY_UID" "$USR"
fi
if [ "$MY_GID" != 1000 ]; then
    usermod -g "$MY_GID" "$USR"
fi
chown -Rf "$USR" "$WORKDIR"

# match internal with external "docker" group ID
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
groupmod -g "$DOCKER_GID" docker

# start the test
CMD_BEGIN=(cargo test --profile reldebug --test stress random_transfers)
CMD_END=(--nocapture --ignored)

if [ -n "$MEMPROF" ]; then
    gosu "$USR" "${CMD_BEGIN[@]}" --features memprof -- "${CMD_END[@]}"
else
    gosu "$USR" "${CMD_BEGIN[@]}" -- "${CMD_END[@]}"
fi
