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
[[ "$(argument_after --name)" =~ ^copilot-nested-[0-9]{8}-[0-9]{6}$ ]] ||
    fail "Unexpected workspace container name: $(argument_after --name)"

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

run_launcher "$NESTED_WORKSPACE" "" chat --allow-all-paths --yolo >/dev/null
load_arguments
allow_count=0
yolo_count=0
for argument in "${DOCKER_ARGUMENTS[@]}"; do
    [[ "$argument" == --allow-all-paths ]] && ((allow_count += 1))
    [[ "$argument" == --yolo ]] && ((yolo_count += 1))
done
assert_equal "1" "$allow_count" "--allow-all-paths was duplicated."
assert_equal "1" "$yolo_count" "--yolo was duplicated."

run_launcher "$NESTED_WORKSPACE" "" --stack-show-auth >/dev/null
load_arguments
assert_equal "show-auth" "${DOCKER_ARGUMENTS[-1]}" "Stack management command."
assert_equal "copilot" "${DOCKER_ARGUMENTS[-2]}" "Stack management service."
assert_contains "${environment_arguments[*]}" "PUID=$(id -u)" "PUID mapping."

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
[[ -f "$CREATE_DIRECTORY/$(basename -- "$CREATE_DIRECTORY").code-workspace" ]] ||
    fail "Default workspace file was not created."
load_arguments
assert_equal "/workspace" "$(argument_after --workdir)" "Default workspace cwd."
assert_equal "--banner" "${DOCKER_ARGUMENTS[-1]}" "Default Copilot argument."

DECLINE_DIRECTORY="$TEST_ROOT/decline"
mkdir -p -- "$DECLINE_DIRECTORY"
decline_output=$(run_launcher "$DECLINE_DIRECTORY" $'n\n')
[[ ! -e "$DECLINE_DIRECTORY/$(basename -- "$DECLINE_DIRECTORY").code-workspace" ]] ||
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

ENTRYPOINT_TEST_ROOT="$TEST_ROOT/entrypoint"
mkdir -p -- "$ENTRYPOINT_TEST_ROOT"
ENTRYPOINT="$REPOSITORY/build/copilot/entrypoint.sh" \
    ENTRYPOINT_TEST_ROOT="$ENTRYPOINT_TEST_ROOT" \
    bash -s <<'BASH'
set -euo pipefail
COPILOT_ENTRYPOINT_LIBRARY_ONLY=1 source "$ENTRYPOINT"

STACK_CONFIG_DIR="$ENTRYPOINT_TEST_ROOT/stack-config"
AUTH_CONFIG_FILE="$STACK_CONFIG_DIR/auth.env"
USER_HOME=

write_values() {
    AUTH_MODE=$1
    AUTH_GITHUB_TOKEN=$2
    AUTH_PROVIDER_TYPE=$3
    AUTH_PROVIDER_BASE_URL=$4
    AUTH_PROVIDER_API_KEY=$5
    AUTH_MODEL=$6
    AUTH_OFFLINE=$7
    write_auth_config
}

write_values github github_pat_test "" "" "" "" false
clear_stack_auth_environment
load_auth >/dev/null
[[ "${COPILOT_GITHUB_TOKEN:-}" == github_pat_test ]]
[[ ! -v COPILOT_PROVIDER_TYPE && ! -v COPILOT_PROVIDER_BASE_URL && ! -v COPILOT_OFFLINE ]]

write_values byok "" openai http://localhost:11434 "" llama3 true
clear_stack_auth_environment
load_auth >/dev/null
[[ ! -v COPILOT_GITHUB_TOKEN && "${COPILOT_PROVIDER_TYPE:-}" == openai ]]
[[ "${COPILOT_OFFLINE:-}" == true ]]

write_values hybrid github_pat_test openai https://litellm.example.test/v1 provider-key model-alias false
clear_stack_auth_environment
load_auth >/dev/null
[[ "${COPILOT_GITHUB_TOKEN:-}" == github_pat_test ]]
[[ "${COPILOT_PROVIDER_API_KEY:-}" == provider-key ]]
[[ ! -v COPILOT_OFFLINE ]]

summary=$(show_auth)
[[ "$summary" != *github_pat_test* && "$summary" != *provider-key* ]]

before_failure=$(<"$AUTH_CONFIG_FILE")
AUTH_OFFLINE=true
if write_auth_config; then
    echo "Hybrid offline mode was accepted." >&2
    exit 1
fi
[[ "$(<"$AUTH_CONFIG_FILE")" == "$before_failure" ]]

for invalid_mode in invalid byok; do
    AUTH_MODE=$invalid_mode
    AUTH_GITHUB_TOKEN=
    AUTH_PROVIDER_TYPE=
    AUTH_PROVIDER_BASE_URL=
    AUTH_PROVIDER_API_KEY=
    AUTH_MODEL=
    AUTH_OFFLINE=false
    if [[ "$invalid_mode" == byok ]]; then
        AUTH_PROVIDER_TYPE=unsupported
        AUTH_PROVIDER_BASE_URL=https://provider.example.test
        AUTH_MODEL=model
    fi
    if validate_auth_config; then
        echo "Invalid authentication configuration was accepted." >&2
        exit 1
    fi
done

AUTH_MODE=byok
AUTH_GITHUB_TOKEN=
AUTH_PROVIDER_TYPE=openai
AUTH_PROVIDER_BASE_URL=
AUTH_PROVIDER_API_KEY=
AUTH_MODEL=
AUTH_OFFLINE=false
if validate_auth_config; then
    echo "Missing provider URL and model were accepted." >&2
    exit 1
fi

printf 'COPILOT_STACK_AUTH_MODE=github\r\n' >"$STACK_CONFIG_DIR/cr.env"
if read_auth_config "$STACK_CONFIG_DIR/cr.env"; then
    echo "CR-containing configuration was accepted." >&2
    exit 1
fi

AUTH_MODE=$'github\ninvalid'
AUTH_GITHUB_TOKEN=github_pat_test
AUTH_PROVIDER_TYPE=
AUTH_PROVIDER_BASE_URL=
AUTH_PROVIDER_API_KEY=
AUTH_MODEL=
AUTH_OFFLINE=false
if validate_auth_config; then
    echo "Line-feed-containing authentication value was accepted." >&2
    exit 1
fi

WORKSPACE="$ENTRYPOINT_TEST_ROOT/workspace"
mkdir -p -- "$WORKSPACE/.copilot"
printf '{"custom":"keep","trusted_folders":["/already"]}\n' >"$WORKSPACE/.copilot/config.json"
COPILOT_CONFIG_DIR="$WORKSPACE/.copilot"
COPILOT_AUTO_TRUST_WORKSPACE=1
(
    cd -- "$WORKSPACE"
    configure_workspace_trust
)
node -e '
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (value.custom !== "keep" || !value.trusted_folders.includes(process.argv[2])) process.exit(1);
' "$WORKSPACE/.copilot/config.json" "$WORKSPACE"

printf '{ invalid json\n' >"$WORKSPACE/.copilot/config.json"
if (
    cd -- "$WORKSPACE"
    configure_workspace_trust
); then
    echo "Invalid workspace Copilot JSON was overwritten." >&2
    exit 1
fi
grep -Fqx '{ invalid json' "$WORKSPACE/.copilot/config.json"

write_values github github_pat_test "" "" "" "" false
printf 'keep' >"$WORKSPACE/.copilot/state"
reset_auth --yes >/dev/null
[[ ! -e "$AUTH_CONFIG_FILE" ]] || exit 1
[[ -f "$WORKSPACE/.copilot/state" ]]

[[ -x "$ENTRYPOINT" ]]
if grep -q $'\r' "$ENTRYPOINT"; then
    echo "Entrypoint contains CRLF line endings." >&2
    exit 1
fi
BASH

echo "All Linux Copilot launcher tests passed."
