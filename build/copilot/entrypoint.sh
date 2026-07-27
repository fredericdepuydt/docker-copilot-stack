#!/bin/bash
set -e

# Get the user and group IDs from environment variables, default to 1000 if not set.
USER_ID=${PUID:-1000}
GROUP_ID=${PGID:-1000}
USER_NAME=appuser
GROUP_NAME=appuser_group

# Reuse existing group by GID when it already exists (e.g., Debian's "node" group).
EXISTING_GROUP_BY_GID=$(getent group "$GROUP_ID" | cut -d: -f1 || true)
if [ -n "$EXISTING_GROUP_BY_GID" ]; then
    GROUP_NAME="$EXISTING_GROUP_BY_GID"
else
    groupadd --gid "$GROUP_ID" "$GROUP_NAME" >/dev/null 2>&1 || true
fi

# Reuse existing user by UID when it already exists (e.g., Debian's "node" user).
EXISTING_USER_BY_UID=$(getent passwd "$USER_ID" | cut -d: -f1 || true)
if [ -n "$EXISTING_USER_BY_UID" ]; then
    USER_NAME="$EXISTING_USER_BY_UID"
else
    useradd --uid "$USER_ID" --gid "$GROUP_ID" --shell /bin/bash --create-home "$USER_NAME" >/dev/null 2>&1 || true
fi

# Verify the selected user exists.
if ! id "$USER_NAME" >/dev/null 2>&1; then
    echo "Warning: Failed to create appuser, running as root" >&2
    mkdir -p /home/appuser/.copilot
    exec "$@"
fi

# Set up .copilot in the selected user's home directory.
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
COPILOT_CONFIG_DIR=${COPILOT_CONFIG_DIR:-/workspace/.copilot}
mkdir -p "$COPILOT_CONFIG_DIR"

# Keep Copilot state scoped to the mounted workspace.
if [ ! -L "$USER_HOME/.copilot" ]; then
    rm -rf "$USER_HOME/.copilot"
    ln -s "$COPILOT_CONFIG_DIR" "$USER_HOME/.copilot"
fi

chown -R "$USER_NAME:$GROUP_NAME" "$USER_HOME" "$COPILOT_CONFIG_DIR"

# Switch to the selected user and execute the command passed to the script.
exec gosu "$USER_NAME" "$@"
