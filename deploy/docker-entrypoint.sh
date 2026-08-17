#!/bin/sh
set -e

# Fix data directory permissions when running as root.
# Docker named volumes / host bind-mounts may be owned by root,
# preventing the non-root slothwatching user from writing files.
if [ "$(id -u)" = "0" ]; then
    mkdir -p /app/data
    # Use || true to avoid failure on read-only mounted files (e.g. config.yaml:ro)
    chown -R slothwatching:slothwatching /app/data 2>/dev/null || true
    # Re-invoke this script as slothwatching so the flag-detection below
    # also runs under the correct user.
    exec su-exec slothwatching "$0" "$@"
fi

# Compatibility: if the first arg looks like a flag (e.g. --help),
# prepend the default binary so it behaves the same as the old
# ENTRYPOINT ["/app/slothwatching"] style.
if [ "${1#-}" != "$1" ]; then
    set -- /app/slothwatching "$@"
fi

exec "$@"
