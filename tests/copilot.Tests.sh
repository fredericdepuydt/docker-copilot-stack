#!/usr/bin/env bash
set -euo pipefail

REPOSITORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
LAUNCHER="$REPOSITORY/copilot"
INSTALLER="$REPOSITORY/install"
TEST_ROOT=$(mktemp -d "/tmp/docker copilot linux tests.XXXXXX")
MOCK_BIN="$TEST_ROOT/mock-bin"
MODERN_MOCK_BIN="$TEST_ROOT/modern-mock-bin"
ARGUMENTS_FILE="$TEST_ROOT/docker-arguments"

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    echo "Test failed: $*" >&2
    exit 1
}

assert_equal() {
    local expected=$1
    local actual=$2
    local message=$3
    [[ "$expected" == "$actual" ]] ||
        fail "$message Expected '$expected', got '$actual'."
}

assert_contains() {
    local value=$1
    local expected=$2
    local message=$3
    [[ "$value" == *"$expected"* ]] ||
        fail "$message Missing '$expected'."
}

write_workspace() {
    local path=$1
    local root=$2
    local workspace=$3

    cat >"$path" <<EOF
{
  // Names are mixed-case to verify case-insensitive matching.
  "folders": [
    {
      "name": "rOoT",
      "path": "$root",
    },
    {
      "name": "WORKSPACE",
      "path": "$workspace",
    },
  ],
  "settings": {
    "url": "https://example.test/path"
  },
}
EOF
}

load_arguments() {
    mapfile -d '' -t DOCKER_ARGUMENTS <"$ARGUMENTS_FILE"
}

argument_after() {
    local name=$1
    local index
    for ((index = 0; index < ${#DOCKER_ARGUMENTS[@]}; index++)); do
        if [[ "${DOCKER_ARGUMENTS[$index]}" == "$name" ]]; then
            printf '%s' "${DOCKER_ARGUMENTS[$((index + 1))]}"
            return
        fi
    done
    fail "Docker argument '$name' was not found."
}

run_launcher() {
    local working_directory=$1
    local input=$2
    shift 2
    (
        cd -- "$working_directory"
        printf '%s' "$input" |
            PATH="$MOCK_BIN:$PATH" \
            COPILOT_TEST_ARGUMENTS="$ARGUMENTS_FILE" \
            "$LAUNCHER" "$@"
    )
}

mkdir -p -- "$MOCK_BIN"
cat >"$MOCK_BIN/docker-compose" <<'EOF'
#!/bin/sh
printf '%s\0' "$@" >"$COPILOT_TEST_ARGUMENTS"
exit "${COPILOT_TEST_EXIT_CODE:-0}"
EOF
chmod +x -- "$MOCK_BIN/docker-compose"

mkdir -p -- "$MODERN_MOCK_BIN"
cat >"$MODERN_MOCK_BIN/docker" <<'EOF'
#!/bin/sh
if [ "$1" != "compose" ]; then
    echo "Expected docker compose subcommand." >&2
    exit 64
fi
shift
printf '%s\0' "$@" >"$COPILOT_TEST_ARGUMENTS"
EOF
chmod +x -- "$MODERN_MOCK_BIN/docker"

ROOT_WITH_SPACES="$TEST_ROOT/Root With Spaces"
NESTED_WORKSPACE="$ROOT_WITH_SPACES/Applications/Area/My Application"
mkdir -p -- "$NESTED_WORKSPACE"
write_workspace "$NESTED_WORKSPACE/nested.code-workspace" "../../.." "."
run_launcher "$NESTED_WORKSPACE" "" chat --model test-model >/dev/null
load_arguments
assert_equal \
    "/workspace/Applications/Area/My Application" \
    "$(argument_after --workdir)" \
    "Nested workspace cwd."
assert_equal \
    "$ROOT_WITH_SPACES:/workspace" \
    "$(argument_after -v)" \
    "Root mount with spaces."

environment_arguments=()
for ((index = 0; index < ${#DOCKER_ARGUMENTS[@]}; index++)); do
    if [[ "${DOCKER_ARGUMENTS[$index]}" == "-e" ]]; then
        environment_arguments+=("${DOCKER_ARGUMENTS[$((index + 1))]}")
    fi
done
assert_contains \
    "${environment_arguments[*]}" \
    "COPILOT_CONFIG_DIR=/workspace/Applications/Area/My Application/.copilot" \
    "Workspace config environment."
assert_contains "${environment_arguments[*]}" "PUID=$(id -u)" "PUID mapping."
assert_contains "${environment_arguments[*]}" "PGID=$(id -g)" "PGID mapping."

allow_index=-1
for ((index = 0; index < ${#DOCKER_ARGUMENTS[@]}; index++)); do
    [[ "${DOCKER_ARGUMENTS[$index]}" == "--allow-all-paths" ]] && allow_index=$index
done
((allow_index >= 0)) || fail "--allow-all-paths was not forwarded."
assert_equal "--yolo" "${DOCKER_ARGUMENTS[$((allow_index + 1))]}" "--yolo order."
assert_equal "chat" "${DOCKER_ARGUMENTS[$((allow_index + 2))]}" "First user argument."
assert_equal "--model" "${DOCKER_ARGUMENTS[$((allow_index + 3))]}" "Second user argument."
assert_equal "test-model" "${DOCKER_ARGUMENTS[$((allow_index + 4))]}" "Third user argument."
for argument in "${DOCKER_ARGUMENTS[@]}"; do
    [[ "$argument" != "-it" ]] || fail "Unsupported Compose -it flag was forwarded."
done

(
    cd -- "$NESTED_WORKSPACE"
    PATH="$MODERN_MOCK_BIN:/usr/bin:/bin" \
        COPILOT_TEST_ARGUMENTS="$ARGUMENTS_FILE" \
        "$LAUNCHER" --help >/dev/null
)
load_arguments
assert_equal "-f" "${DOCKER_ARGUMENTS[0]}" "Modern docker compose invocation."

CREATE_DIRECTORY="$TEST_ROOT/create"
mkdir -p -- "$CREATE_DIRECTORY"
run_launcher "$CREATE_DIRECTORY" $'\n' >/dev/null
[[ -f "$CREATE_DIRECTORY/workspace.code-workspace" ]] ||
    fail "Default workspace file was not created."
load_arguments
assert_equal "/workspace" "$(argument_after --workdir)" "Default workspace cwd."
assert_equal "--banner" "${DOCKER_ARGUMENTS[-1]}" "Default Copilot argument."

DECLINE_DIRECTORY="$TEST_ROOT/decline"
mkdir -p -- "$DECLINE_DIRECTORY"
decline_output=$(run_launcher "$DECLINE_DIRECTORY" $'n\n')
[[ ! -e "$DECLINE_DIRECTORY/workspace.code-workspace" ]] ||
    fail "Declining workspace creation still created a file."
assert_contains "$decline_output" "<current directory defaults>" "Default workspace display."

MULTIPLE_DIRECTORY="$TEST_ROOT/multiple"
mkdir -p -- "$MULTIPLE_DIRECTORY/selected"
write_workspace "$MULTIPLE_DIRECTORY/a.code-workspace" "." "."
write_workspace "$MULTIPLE_DIRECTORY/b.code-workspace" "." "selected"
run_launcher "$MULTIPLE_DIRECTORY" $'2\n' >/dev/null
load_arguments
assert_equal "/workspace/selected" "$(argument_after --workdir)" "Workspace selection."

OUTSIDE_DIRECTORY="$TEST_ROOT/outside"
mkdir -p -- "$OUTSIDE_DIRECTORY/root" "$OUTSIDE_DIRECTORY/sibling"
write_workspace "$OUTSIDE_DIRECTORY/outside.code-workspace" "root" "sibling"
if outside_output=$(run_launcher "$OUTSIDE_DIRECTORY" "" 2>&1); then
    fail "Workspace outside Root was accepted."
fi
assert_contains "$outside_output" "is outside Root" "Outside Root error."

INVALID_DIRECTORY="$TEST_ROOT/invalid"
mkdir -p -- "$INVALID_DIRECTORY"
printf '{ "folders": [ }' >"$INVALID_DIRECTORY/invalid.code-workspace"
if invalid_output=$(run_launcher "$INVALID_DIRECTORY" "" 2>&1); then
    fail "Invalid workspace JSON was accepted."
fi
assert_contains \
    "$invalid_output" \
    "Invalid or unreadable workspace JSON" \
    "Invalid JSON error."

FAILURE_DIRECTORY="$TEST_ROOT/failure"
mkdir -p -- "$FAILURE_DIRECTORY"
write_workspace "$FAILURE_DIRECTORY/failure.code-workspace" "." "."
set +e
failure_output=$(
    cd -- "$FAILURE_DIRECTORY"
    PATH="$MOCK_BIN:$PATH" \
        COPILOT_TEST_ARGUMENTS="$ARGUMENTS_FILE" \
        COPILOT_TEST_EXIT_CODE=17 \
        "$LAUNCHER" --help 2>&1
)
failure_status=$?
set -e
assert_equal "17" "$failure_status" "Compose exit code."
assert_contains "$failure_output" "exited with code 17" "Compose failure message."

LEGACY_BIN="$TEST_ROOT/legacy-bin"
mkdir -p -- "$LEGACY_BIN"
ln -s -- "$LAUNCHER" "$LEGACY_BIN/copilot"
(
    cd -- "$NESTED_WORKSPACE"
    PATH="$MOCK_BIN:$PATH" \
        COPILOT_TEST_ARGUMENTS="$ARGUMENTS_FILE" \
        "$LEGACY_BIN/copilot" --help >/dev/null
)
load_arguments
assert_equal \
    "$REPOSITORY/docker-compose.yaml" \
    "$(argument_after -f)" \
    "Legacy symlink Compose path."

INSTALL_HOME="$TEST_ROOT/install-home"
INSTALL_DIRECTORY="$INSTALL_HOME/local bin"
PROFILE="$INSTALL_HOME/.bashrc"
mkdir -p -- "$INSTALL_HOME"
printf 'export EXISTING_SETTING=1\n' >"$PROFILE"
mkdir -p -- "$INSTALL_DIRECTORY"
ln -s -- "$LAUNCHER" "$INSTALL_DIRECTORY/copilot"
for run in 1 2; do
    HOME="$INSTALL_HOME" \
        SHELL=/bin/bash \
        PATH=/usr/bin:/bin \
        COPILOT_INSTALL_DIR="$INSTALL_DIRECTORY" \
        COPILOT_PROFILE="$PROFILE" \
        "$INSTALLER" >/dev/null
done

[[ ! -e "$INSTALL_DIRECTORY/copilot" ]] ||
    fail "Legacy launcher symlink was not removed."
marker_count=$(grep -Fxc "# >>> docker copilot launcher >>>" "$PROFILE")
assert_equal "1" "$marker_count" "Installer idempotency."
assert_contains "$(<"$PROFILE")" "copilot() {" "Installed Copilot function."
assert_contains "$(<"$PROFILE")" "$LAUNCHER" "Installed launcher path."
assert_contains "$(<"$PROFILE")" "EXISTING_SETTING=1" "Existing profile content."

FUNCTION_WORKSPACE="$TEST_ROOT/function-workspace"
mkdir -p -- "$FUNCTION_WORKSPACE"
write_workspace "$FUNCTION_WORKSPACE/function.code-workspace" "." "."
(
    cd -- "$FUNCTION_WORKSPACE"
    PATH="$MOCK_BIN:$PATH"
    COPILOT_TEST_ARGUMENTS="$ARGUMENTS_FILE"
    export PATH COPILOT_TEST_ARGUMENTS
    source "$PROFILE"
    copilot --help >/dev/null
)
load_arguments
assert_equal \
    "$FUNCTION_WORKSPACE:/workspace" \
    "$(argument_after -v)" \
    "Installed function current working directory."

echo "All Linux Copilot launcher tests passed."
