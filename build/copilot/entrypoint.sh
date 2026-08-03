#!/usr/bin/env bash
set -Eeuo pipefail

STACK_CONFIG_DIR=${COPILOT_STACK_CONFIG_DIR:-/copilot-stack-config}
AUTH_CONFIG_FILE="$STACK_CONFIG_DIR/auth.env"
USER_ID=${PUID:-1000}
GROUP_ID=${PGID:-1000}
USER_NAME=appuser
GROUP_NAME=appuser_group
USER_HOME=
COPILOT_CONFIG_DIR=${COPILOT_CONFIG_DIR:-/workspace/.copilot}
AUTH_MODE=
AUTH_PROVIDER_TYPE=
AUTH_PROVIDER_BASE_URL=
AUTH_PROVIDER_API_KEY=
AUTH_MODEL=
AUTH_OFFLINE=

log_error() {
    printf 'copilot-stack: %s\n' "$*" >&2
}

log_warning() {
    printf 'copilot-stack: warning: %s\n' "$*" >&2
}

fail() {
    log_error "$*"
    return 1
}

on_error() {
    local status=$?
    log_error "initialization failed (exit $status)."
    exit "$status"
}

trap on_error ERR

validate_single_line_value() {
    local field_name=$1
    local value=$2

    if [[ "$value" == *$'\r'* || "$value" == *$'\n'* ]]; then
        fail "$field_name must not contain carriage returns or line feeds."
        return 1
    fi
}

validate_provider_url() {
    local provider_url=$1

    node -e '
const value = process.argv[1];
try {
  const url = new URL(value);
  process.exit(
    (url.protocol === "http:" || url.protocol === "https:") &&
      !url.username &&
      !url.password &&
      !url.search &&
      !url.hash
      ? 0
      : 1
  );
} catch {
  process.exit(1);
}
' "$provider_url" || {
        fail "Provider URL must be an absolute HTTP or HTTPS URL without embedded credentials, query parameters, or fragments."
        return 1
    }
}

reset_auth_values() {
    AUTH_MODE=
    AUTH_PROVIDER_TYPE=
    AUTH_PROVIDER_BASE_URL=
    AUTH_PROVIDER_API_KEY=
    AUTH_MODEL=
    AUTH_OFFLINE=
}

get_config_value() {
    local key=$1

    case "$key" in
        COPILOT_STACK_AUTH_MODE) printf '%s' "$AUTH_MODE" ;;
        COPILOT_PROVIDER_TYPE) printf '%s' "$AUTH_PROVIDER_TYPE" ;;
        COPILOT_PROVIDER_BASE_URL) printf '%s' "$AUTH_PROVIDER_BASE_URL" ;;
        COPILOT_PROVIDER_API_KEY) printf '%s' "$AUTH_PROVIDER_API_KEY" ;;
        COPILOT_MODEL) printf '%s' "$AUTH_MODEL" ;;
        COPILOT_OFFLINE) printf '%s' "$AUTH_OFFLINE" ;;
        *) fail "Unknown configuration key requested: $key" ;;
    esac
}

read_auth_config() {
    local config_file=$1
    local line
    local key
    local value
    local required_key
    local -A seen=()

    if [[ ! -f "$config_file" ]]; then
        fail "Authentication configuration does not exist."
        return 1
    fi
    reset_auth_values

    while IFS= read -r line || [[ -n "$line" ]]; do
        validate_single_line_value "Authentication configuration" "$line" || return 1
        if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
            fail "Malformed authentication configuration line."
            return 1
        fi
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}

        if [[ -n ${seen[$key]+present} ]]; then
            fail "Authentication configuration contains duplicate key '$key'."
            return 1
        fi
        seen[$key]=1

        case "$key" in
            COPILOT_STACK_AUTH_MODE) AUTH_MODE=$value ;;
            COPILOT_GITHUB_TOKEN)
                log_warning "ignoring obsolete GitHub token setting; run copilot login to store GitHub credentials in config.json."
                ;;
            COPILOT_PROVIDER_TYPE) AUTH_PROVIDER_TYPE=$value ;;
            COPILOT_PROVIDER_BASE_URL) AUTH_PROVIDER_BASE_URL=$value ;;
            COPILOT_PROVIDER_API_KEY) AUTH_PROVIDER_API_KEY=$value ;;
            COPILOT_MODEL) AUTH_MODEL=$value ;;
            COPILOT_OFFLINE) AUTH_OFFLINE=$value ;;
            *)
                fail "Authentication configuration contains unknown key '$key'."
                return 1
                ;;
        esac
    done <"$config_file"

    for required_key in \
        COPILOT_STACK_AUTH_MODE \
        COPILOT_PROVIDER_TYPE \
        COPILOT_PROVIDER_BASE_URL \
        COPILOT_PROVIDER_API_KEY \
        COPILOT_MODEL \
        COPILOT_OFFLINE; do
        if [[ -z ${seen[$required_key]+present} ]]; then
            fail "Authentication configuration is missing '$required_key'."
            return 1
        fi
    done
}

validate_auth_config() {
    validate_single_line_value "Authentication mode" "$AUTH_MODE" || return 1
    validate_single_line_value "Provider type" "$AUTH_PROVIDER_TYPE" || return 1
    validate_single_line_value "Provider URL" "$AUTH_PROVIDER_BASE_URL" || return 1
    validate_single_line_value "Provider API key" "$AUTH_PROVIDER_API_KEY" || return 1
    validate_single_line_value "Provider model" "$AUTH_MODEL" || return 1
    validate_single_line_value "Offline setting" "$AUTH_OFFLINE" || return 1

    case "$AUTH_MODE" in
        github)
            [[ -z "$AUTH_PROVIDER_TYPE" && -z "$AUTH_PROVIDER_BASE_URL" &&
                -z "$AUTH_PROVIDER_API_KEY" && -z "$AUTH_MODEL" ]] ||
                {
                    fail "GitHub authentication must not include BYOK provider settings."
                    return 1
                }
            [[ "$AUTH_OFFLINE" == false ]] || {
                fail "GitHub authentication cannot enable offline mode."
                return 1
            }
            ;;
        byok | hybrid)
            [[ "$AUTH_PROVIDER_TYPE" == openai ||
                "$AUTH_PROVIDER_TYPE" == azure ||
                "$AUTH_PROVIDER_TYPE" == anthropic ]] ||
                {
                    fail "Unsupported provider type '$AUTH_PROVIDER_TYPE'. Supported types are openai, azure, and anthropic."
                    return 1
                }
            [[ -n "$AUTH_PROVIDER_BASE_URL" ]] || {
                fail "BYOK configuration requires a provider URL."
                return 1
            }
            validate_provider_url "$AUTH_PROVIDER_BASE_URL" || return 1
            [[ -n "$AUTH_MODEL" ]] || {
                fail "BYOK configuration requires a model identifier."
                return 1
            }
            if [[ "$AUTH_PROVIDER_TYPE" == azure || "$AUTH_PROVIDER_TYPE" == anthropic ]]; then
                [[ -n "$AUTH_PROVIDER_API_KEY" ]] || {
                    fail "$AUTH_PROVIDER_TYPE configuration requires a provider API key."
                    return 1
                }
            fi
            if [[ "$AUTH_MODE" == hybrid ]]; then
                [[ "$AUTH_OFFLINE" == false ]] || {
                    fail "Hybrid authentication cannot enable offline mode."
                    return 1
                }
            else
                [[ "$AUTH_OFFLINE" == true || "$AUTH_OFFLINE" == false ]] ||
                    {
                        fail "Offline setting must be true or false."
                        return 1
                    }
            fi
            ;;
        *)
            fail "Unsupported authentication mode '$AUTH_MODE'."
            return 1
            ;;
    esac
}

prepare_stack_config_directory() {
    umask 077
    mkdir -p -- "$STACK_CONFIG_DIR"
    chmod 0700 -- "$STACK_CONFIG_DIR" ||
        log_warning "could not restrict permissions on $STACK_CONFIG_DIR."
}

write_auth_config() {
    local temporary_file

    prepare_stack_config_directory || return 1
    if ! temporary_file=$(mktemp "$STACK_CONFIG_DIR/.auth.env.XXXXXX"); then
        fail "Could not create temporary authentication configuration."
        return 1
    fi
    chmod 0600 -- "$temporary_file" ||
        log_warning "could not restrict permissions on temporary authentication configuration."
    trap 'rm -f -- "$temporary_file"; exit 130' HUP INT TERM

    if ! {
        printf 'COPILOT_STACK_AUTH_MODE=%s\n' "$AUTH_MODE"
        printf 'COPILOT_PROVIDER_TYPE=%s\n' "$AUTH_PROVIDER_TYPE"
        printf 'COPILOT_PROVIDER_BASE_URL=%s\n' "$AUTH_PROVIDER_BASE_URL"
        printf 'COPILOT_PROVIDER_API_KEY=%s\n' "$AUTH_PROVIDER_API_KEY"
        printf 'COPILOT_MODEL=%s\n' "$AUTH_MODEL"
        printf 'COPILOT_OFFLINE=%s\n' "$AUTH_OFFLINE"
    } >"$temporary_file"; then
        rm -f -- "$temporary_file"
        trap - HUP INT TERM
        return 1
    fi

    if ! read_auth_config "$temporary_file" || ! validate_auth_config; then
        rm -f -- "$temporary_file"
        trap - HUP INT TERM
        return 1
    fi
    if ! mv -f -- "$temporary_file" "$AUTH_CONFIG_FILE"; then
        rm -f -- "$temporary_file"
        trap - HUP INT TERM
        return 1
    fi
    trap - HUP INT TERM
    chmod 0600 -- "$AUTH_CONFIG_FILE" ||
        log_warning "could not restrict permissions on authentication configuration."
    if [[ -n "$USER_HOME" ]]; then
        chown "$USER_NAME:$GROUP_NAME" "$STACK_CONFIG_DIR" "$AUTH_CONFIG_FILE" ||
            log_warning "could not set authentication configuration ownership."
    fi
}

require_interactive_terminal() {
    [[ -t 0 && -t 1 ]] ||
        fail "Copilot authentication is not configured and no interactive terminal is available.

Run:
  docker compose run --rm copilot configure-auth"
}

read_required_value() {
    local prompt=$1
    local value

    if ! read -r -p "$prompt" value; then
        fail "Unable to read configuration input."
        return 1
    fi
    if [[ -z "$value" ]]; then
        fail "A value is required."
        return 1
    fi
    validate_single_line_value "Configuration value" "$value" || return 1
    printf '%s' "$value"
}

read_secret_value() {
    local prompt=$1
    local required=$2
    local value

    if ! read -r -s -p "$prompt" value; then
        fail "Unable to read configuration input."
        return 1
    fi
    printf '\n'
    if [[ "$required" == required ]]; then
        if [[ -z "$value" ]]; then
            fail "A value is required."
            return 1
        fi
    fi
    validate_single_line_value "Configuration value" "$value" || return 1
    printf '%s' "$value"
}

configure_byok_values() {
    local offline_response
    local api_key_required=optional

    printf '%s\n' "Supported provider types: openai (including OpenAI-compatible services such as LiteLLM, Ollama, and vLLM), azure, anthropic."
    AUTH_PROVIDER_TYPE=$(read_required_value "Provider type [openai/azure/anthropic]: ") || return 1
    AUTH_PROVIDER_BASE_URL=$(read_required_value "Provider base URL: ") || return 1
    AUTH_MODEL=$(read_required_value "Provider model identifier: ") || return 1
    if [[ "$AUTH_PROVIDER_TYPE" == azure || "$AUTH_PROVIDER_TYPE" == anthropic ]]; then
        api_key_required=required
    fi
    AUTH_PROVIDER_API_KEY=$(read_secret_value "Provider API key${api_key_required:+ (leave blank only for an unauthenticated local OpenAI-compatible provider)}: " "$api_key_required") || return 1

    if [[ "$AUTH_MODE" == byok ]]; then
        if ! read -r -p "Enable offline mode? [y/N] " offline_response; then
            fail "Unable to read offline mode setting."
            return 1
        fi
        case ${offline_response,,} in
            y | yes) AUTH_OFFLINE=true ;;
            "" | n | no) AUTH_OFFLINE=false ;;
            *)
                fail "Offline mode must be answered with y or n."
                return 1
                ;;
        esac
    else
        AUTH_OFFLINE=false
    fi
}

configure_github_login() {
    printf '%s\n' "Starting GitHub Copilot sign-in. Copilot CLI stores config.json centrally in $STACK_CONFIG_DIR."
    if [[ -n "$USER_HOME" ]]; then
        gosu "$USER_NAME" copilot login
    else
        copilot login
    fi
}

setup_central_config_link() {
    local central_config="$STACK_CONFIG_DIR/config.json"
    local workspace_config="$COPILOT_CONFIG_DIR/config.json"

    prepare_stack_config_directory || return 1
    mkdir -p -- "$COPILOT_CONFIG_DIR"
    if [[ -L "$workspace_config" ]]; then
        [[ "$(readlink -- "$workspace_config")" == "$central_config" ]] || {
            fail "$workspace_config links to an unexpected location."
            return 1
        }
    elif [[ -e "$workspace_config" ]]; then
        if [[ ! -e "$central_config" ]]; then
            mv -- "$workspace_config" "$central_config"
        else
            COPILOT_CENTRAL_CONFIG="$central_config" COPILOT_WORKSPACE_CONFIG="$workspace_config" node <<'NODE'
const fs = require("fs");
const path = require("path");

const centralFile = process.env.COPILOT_CENTRAL_CONFIG;
const workspaceFile = process.env.COPILOT_WORKSPACE_CONFIG;
let central;
let workspace;
try {
  central = JSON.parse(fs.readFileSync(centralFile, "utf8"));
  workspace = JSON.parse(fs.readFileSync(workspaceFile, "utf8"));
} catch {
  console.error("copilot-stack: central or workspace config.json is invalid; migration was not performed.");
  process.exit(1);
}
if (!central || Array.isArray(central) || typeof central !== "object" ||
    !workspace || Array.isArray(workspace) || typeof workspace !== "object") {
  console.error("copilot-stack: central and workspace config.json files must contain JSON objects.");
  process.exit(1);
}
for (const [key, value] of Object.entries(workspace)) {
  if (!Object.prototype.hasOwnProperty.call(central, key)) central[key] = value;
}
const temporaryFile = path.join(
  path.dirname(centralFile),
  `.${path.basename(centralFile)}.${process.pid}.${Date.now()}.tmp`
);
try {
  fs.writeFileSync(temporaryFile, `${JSON.stringify(central, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporaryFile, centralFile);
} catch (error) {
  try {
    fs.unlinkSync(temporaryFile);
  } catch {}
  console.error(`copilot-stack: could not migrate workspace config.json: ${error.message}`);
  process.exit(1);
}
NODE
            rm -- "$workspace_config"
        fi
        ln -s -- "$central_config" "$workspace_config"
    else
        ln -s -- "$central_config" "$workspace_config"
    fi

    [[ ! -e "$central_config" ]] || chmod 0600 -- "$central_config" ||
        log_warning "could not restrict permissions on central Copilot configuration."
    if [[ -n "$USER_HOME" ]]; then
        chown "$USER_NAME:$GROUP_NAME" "$STACK_CONFIG_DIR" "$COPILOT_CONFIG_DIR" ||
            log_warning "could not set Copilot configuration directory ownership."
        [[ ! -e "$central_config" ]] || chown "$USER_NAME:$GROUP_NAME" "$central_config" ||
            log_warning "could not set central Copilot configuration ownership."
        chown -h "$USER_NAME:$GROUP_NAME" "$workspace_config" ||
            log_warning "could not set central Copilot configuration link ownership."
    fi
}


configure_auth() {
    local selection

    require_interactive_terminal || return 1
    reset_auth_values
    printf '%s\n\n' "Configure Copilot authentication"
    printf '%s\n' "  1. GitHub Copilot"
    printf '%s\n' "  2. BYOK provider"
    printf '%s\n' "  3. BYOK provider with GitHub integration"
    if ! read -r -p "Select authentication mode [1-3]: " selection; then
        fail "Unable to read authentication mode."
        return 1
    fi

    case "$selection" in
        1)
            AUTH_MODE=github
            AUTH_OFFLINE=false
            configure_github_login || return 1
            ;;
        2)
            AUTH_MODE=byok
            configure_byok_values || return 1
            ;;
        3)
            AUTH_MODE=hybrid
            configure_byok_values || return 1
            configure_github_login || return 1
            ;;
        *)
            fail "Authentication mode must be 1, 2, or 3."
            return 1
            ;;
    esac

    write_auth_config || return 1
    printf '%s\n' "Copilot authentication configuration saved."
}

clear_stack_auth_environment() {
    unset COPILOT_GITHUB_TOKEN GH_TOKEN GITHUB_TOKEN
    unset COPILOT_PROVIDER_BASE_URL COPILOT_PROVIDER_TYPE COPILOT_PROVIDER_API_KEY COPILOT_MODEL COPILOT_OFFLINE
}

print_auth_summary() {
    local github_configured=no
    local api_key_configured=no

    [[ "$AUTH_MODE" == github || "$AUTH_MODE" == hybrid ]] && github_configured=yes
    [[ -n "$AUTH_PROVIDER_API_KEY" ]] && api_key_configured=yes

    printf 'Mode:                %s\n' "$AUTH_MODE"
    printf 'GitHub configured:   %s\n' "$github_configured"
    if [[ "$AUTH_MODE" == byok || "$AUTH_MODE" == hybrid ]]; then
        printf 'Provider type:       %s\n' "$AUTH_PROVIDER_TYPE"
        printf 'Provider URL:        %s\n' "$AUTH_PROVIDER_BASE_URL"
        printf 'Provider model:      %s\n' "$AUTH_MODEL"
        printf 'API key configured:  %s\n' "$api_key_configured"
    fi
    printf 'Offline:             %s\n' "$AUTH_OFFLINE"
}

print_startup_auth_summary() {
    printf 'Authentication:    %s\n' "$AUTH_MODE"
    if [[ "$AUTH_MODE" == github || "$AUTH_MODE" == hybrid ]]; then
        printf '%s\n' "GitHub access:     enabled"
    else
        printf '%s\n' "GitHub access:     disabled"
    fi
    if [[ "$AUTH_MODE" == byok || "$AUTH_MODE" == hybrid ]]; then
        printf 'Provider type:     %s\n' "$AUTH_PROVIDER_TYPE"
        printf 'Provider URL:      %s\n' "$AUTH_PROVIDER_BASE_URL"
        printf 'Provider model:    %s\n' "$AUTH_MODEL"
    fi
    printf 'Offline mode:      %s\n' "$AUTH_OFFLINE"
}

load_auth() {
    clear_stack_auth_environment

    if [[ ! -e "$AUTH_CONFIG_FILE" ]]; then
        configure_auth || return 1
    fi
    [[ -f "$AUTH_CONFIG_FILE" ]] ||
        fail "Authentication configuration is not a regular file."

    read_auth_config "$AUTH_CONFIG_FILE" || return 1
    validate_auth_config || return 1

    case "$AUTH_MODE" in
        github)
            ;;
        byok)
            export COPILOT_PROVIDER_TYPE="$AUTH_PROVIDER_TYPE"
            export COPILOT_PROVIDER_BASE_URL="$AUTH_PROVIDER_BASE_URL"
            export COPILOT_PROVIDER_API_KEY="$AUTH_PROVIDER_API_KEY"
            export COPILOT_MODEL="$AUTH_MODEL"
            [[ "$AUTH_OFFLINE" == true ]] && export COPILOT_OFFLINE=true
            ;;
        hybrid)
            export COPILOT_PROVIDER_TYPE="$AUTH_PROVIDER_TYPE"
            export COPILOT_PROVIDER_BASE_URL="$AUTH_PROVIDER_BASE_URL"
            export COPILOT_PROVIDER_API_KEY="$AUTH_PROVIDER_API_KEY"
            export COPILOT_MODEL="$AUTH_MODEL"
            ;;
    esac
    print_startup_auth_summary
}

show_auth() {
    clear_stack_auth_environment
    [[ -f "$AUTH_CONFIG_FILE" ]] ||
        fail "Copilot authentication is not configured."
    read_auth_config "$AUTH_CONFIG_FILE" || return 1
    validate_auth_config || return 1
    print_auth_summary
}

reset_auth() {
    local confirmation

    case ${1:-} in
        --yes)
            [[ $# -eq 1 ]] || fail "reset-auth accepts only --yes."
            ;;
        "")
            [[ -t 0 && -t 1 ]] ||
                fail "reset-auth requires confirmation. Run: docker compose run --rm copilot reset-auth --yes"
            read -r -p "Remove the stack authentication configuration? [y/N] " confirmation ||
                fail "Unable to read reset confirmation."
            case ${confirmation,,} in
                y | yes) ;;
                *) printf '%s\n' "Authentication configuration was not removed."; return 0 ;;
            esac
            ;;
        *)
            fail "reset-auth accepts only --yes."
            ;;
    esac

    rm -f -- "$AUTH_CONFIG_FILE"
    printf '%s\n' "Copilot stack authentication configuration removed."
}

configure_workspace_trust() {
    local trust_setting=${COPILOT_AUTO_TRUST_WORKSPACE:-1}
    local config_file="$STACK_CONFIG_DIR/config.json"

    case "$trust_setting" in
        0 | false | FALSE) return 0 ;;
        1 | true | TRUE) ;;
        *)
            fail "COPILOT_AUTO_TRUST_WORKSPACE must be 0 or 1."
            return 1
            ;;
    esac

    prepare_stack_config_directory || return 1
    COPILOT_TRUST_CONFIG_FILE="$config_file" COPILOT_TRUST_DIRECTORY="$PWD" node <<'NODE'
const fs = require("fs");
const path = require("path");

const configFile = process.env.COPILOT_TRUST_CONFIG_FILE;
const trustedDirectory = process.env.COPILOT_TRUST_DIRECTORY;
let config = {};

function parseJsonc(content) {
  let output = "";
  let inString = false;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;

  for (let index = 0; index < content.length; index += 1) {
    const character = content[index];
    const next = content[index + 1];
    if (lineComment) {
      if (character === "\n" || character === "\r") {
        lineComment = false;
        output += character;
      }
      continue;
    }
    if (blockComment) {
      if (character === "*" && next === "/") {
        blockComment = false;
        index += 1;
      } else if (character === "\n" || character === "\r") {
        output += character;
      }
      continue;
    }
    if (inString) {
      output += character;
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === '"') inString = false;
      continue;
    }
    if (character === '"') {
      inString = true;
      output += character;
    } else if (character === "/" && next === "/") {
      lineComment = true;
      index += 1;
    } else if (character === "/" && next === "*") {
      blockComment = true;
      index += 1;
    } else {
      output += character;
    }
  }

  return JSON.parse(output.replace(/,\s*([}\]])/g, "$1"));
}

if (fs.existsSync(configFile)) {
  try {
    config = parseJsonc(fs.readFileSync(configFile, "utf8"));
  } catch {
    console.error("copilot-stack: shared Copilot configuration is invalid JSON; it was not modified.");
    process.exit(1);
  }
  if (config === null || Array.isArray(config) || typeof config !== "object") {
    console.error("copilot-stack: shared Copilot configuration must be a JSON object; it was not modified.");
    process.exit(1);
  }
}

const trustKey = Object.prototype.hasOwnProperty.call(config, "trusted_folders")
  ? "trusted_folders"
  : Object.prototype.hasOwnProperty.call(config, "trustedFolders")
    ? "trustedFolders"
    : "trusted_folders";
if (Object.prototype.hasOwnProperty.call(config, trustKey) && !Array.isArray(config[trustKey])) {
  console.error("copilot-stack: shared trusted-folder configuration must be an array; it was not modified.");
  process.exit(1);
}

const trustedFolders = config[trustKey] || [];
if (!trustedFolders.includes(trustedDirectory)) {
  config[trustKey] = [...trustedFolders, trustedDirectory];
  const temporaryFile = path.join(
    path.dirname(configFile),
    `.${path.basename(configFile)}.${process.pid}.${Date.now()}.tmp`
  );
  try {
    fs.writeFileSync(temporaryFile, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
    fs.renameSync(temporaryFile, configFile);
  } catch (error) {
    try {
      fs.unlinkSync(temporaryFile);
    } catch {}
    console.error(`copilot-stack: could not update shared trust configuration: ${error.message}`);
    process.exit(1);
  }
}
NODE
}

setup_container_user() {
    local existing_group
    local existing_user

    existing_group=$(getent group "$GROUP_ID" | cut -d: -f1 || true)
    if [[ -n "$existing_group" ]]; then
        GROUP_NAME=$existing_group
    else
        groupadd --gid "$GROUP_ID" "$GROUP_NAME" ||
            log_warning "failed to create the mapped group."
    fi

    existing_user=$(getent passwd "$USER_ID" | cut -d: -f1 || true)
    if [[ -n "$existing_user" ]]; then
        USER_NAME=$existing_user
    else
        useradd --uid "$USER_ID" --gid "$GROUP_ID" --shell /bin/bash --create-home "$USER_NAME" ||
            log_warning "failed to create the mapped user."
    fi

    if ! id "$USER_NAME" >/dev/null 2>&1; then
        log_warning "failed to create the mapped user; running as root."
        return 1
    fi

    USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
    mkdir -p -- "$COPILOT_CONFIG_DIR"
    if [[ ! -L "$USER_HOME/.copilot" ]]; then
        rm -rf -- "$USER_HOME/.copilot"
        ln -s "$COPILOT_CONFIG_DIR" "$USER_HOME/.copilot"
    fi
    setup_central_config_link || return 1
    chown -R "$USER_NAME:$GROUP_NAME" "$USER_HOME" "$COPILOT_CONFIG_DIR"
    chown -h "$USER_NAME:$GROUP_NAME" "$COPILOT_CONFIG_DIR/config.json"
}

run_as_container_user() {
    exec gosu "$USER_NAME" "$@"
}

main() {
    clear_stack_auth_environment

    if ! setup_container_user; then
        setup_central_config_link
        load_auth
        configure_workspace_trust
        exec "$@"
    fi

    case ${1:-} in
        configure-auth)
            [[ $# -eq 1 ]] || fail "configure-auth does not accept additional arguments."
            configure_auth
            exit 0
            ;;
        show-auth)
            [[ $# -eq 1 ]] || fail "show-auth does not accept additional arguments."
            show_auth
            exit 0
            ;;
        reset-auth)
            shift
            reset_auth "$@"
            exit 0
            ;;
    esac

    load_auth
    configure_workspace_trust
    chown -R "$USER_NAME:$GROUP_NAME" "$COPILOT_CONFIG_DIR"
    run_as_container_user "$@"
}

if [[ ${COPILOT_ENTRYPOINT_LIBRARY_ONLY:-0} != 1 ]]; then
    main "$@"
fi
