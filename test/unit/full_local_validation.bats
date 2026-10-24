#!/usr/bin/env bats

load '../test_helper/bats-support/load.bash'
load '../test_helper/bats-assert/load.bash'
load '../test_helper/project.bash'

@test "run_full_local_validation.sh can be sourced without executing the validation flow" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/test/run_full_local_validation.sh"
    printf "run=%s\n" "$(type -t full_validation_run)"
    printf "instance=%s\n" "${INSTANCE_NAME:-unset}"
  '

  assert_success
  assert_output --partial "run=function"
  assert_output --partial "instance=unset"
}

@test "full_validation_detect_branch_mode returns beta when the beta flag file exists" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/test/run_full_local_validation.sh"
    mkdir -p "$REPO_ROOT/config/POK-manager"
    touch "$REPO_ROOT/config/POK-manager/beta_mode"
    mode="$(full_validation_detect_branch_mode)"
    rm -f "$REPO_ROOT/config/POK-manager/beta_mode"
    printf "mode=%s\n" "$mode"
  '

  assert_success
  assert_output --partial "mode=beta"
}

@test "full_validation_parse_args accepts a target instance and branch options" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/test/run_full_local_validation.sh"
    full_validation_parse_args test_beta --branch beta --startup-timeout 600 --process-timeout 900 --health-timeout 120 --skip-fast --skip-smoke --runtime-matrix --sudo
    printf "instance=%s\n" "$INSTANCE_NAME"
    printf "branch=%s\n" "$TARGET_BRANCH_MODE"
    printf "startup=%s\n" "$STARTUP_TIMEOUT"
    printf "process=%s\n" "$PROCESS_TIMEOUT"
    printf "health=%s\n" "$HEALTH_TIMEOUT"
    printf "skip_fast=%s\n" "$SKIP_FAST"
    printf "skip_smoke=%s\n" "$SKIP_SMOKE"
    printf "runtime_matrix=%s\n" "$RUNTIME_MATRIX"
    printf "use_sudo=%s\n" "$USE_SUDO"
  '

  assert_success
  assert_output --partial "instance=test_beta"
  assert_output --partial "branch=beta"
  assert_output --partial "startup=600"
  assert_output --partial "process=900"
  assert_output --partial "health=120"
  assert_output --partial "skip_fast=true"
  assert_output --partial "skip_smoke=true"
  assert_output --partial "runtime_matrix=true"
  assert_output --partial "use_sudo=true"
}

@test "full_validation_parse_args rejects leaving the runtime matrix running" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/test/run_full_local_validation.sh"
    set +e
    full_validation_parse_args test_beta --runtime-matrix --leave-running
    status=$?
    set -e
    echo "status=$status"
  '

  assert_success
  assert_output --partial "--runtime-matrix cannot be combined with --leave-running"
  assert_output --partial "status=1"
}

@test "full validation diagnostics redact server and API credentials" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/test/run_full_local_validation.sh"
    printf "%s\n" \
      "SERVER_ADMIN_PASSWORD=admin-secret" \
      "?ServerPassword=join-secret?RCONEnabled=True" \
      "AccountKey: premium-secret" \
      "access_token=token-secret" \
      "sentry_key=sentry-secret" | full_validation_redact_stream
  '

  assert_success
  assert_output --partial "SERVER_ADMIN_PASSWORD=[REDACTED]"
  assert_output --partial "ServerPassword=[REDACTED]?RCONEnabled=True"
  assert_output --partial "AccountKey: [REDACTED]"
  assert_output --partial "access_token=[REDACTED]"
  assert_output --partial "sentry_key=[REDACTED]"
  refute_output --partial "admin-secret"
  refute_output --partial "join-secret"
  refute_output --partial "premium-secret"
  refute_output --partial "token-secret"
  refute_output --partial "sentry-secret"
}

@test "full_validation_read_api_state accepts manager and commented template syntax" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/test/run_full_local_validation.sh"
    REPO_ROOT="$BATS_TEST_TMPDIR/api-state-root"
    INSTANCE_NAME=demo
    mkdir -p "$REPO_ROOT/Instance_demo"
    printf "%s\n" "      - API=TRUE  # template setting" > "$REPO_ROOT/Instance_demo/docker-compose-demo.yaml"
    printf "commented=%s\n" "$(full_validation_read_api_state)"
    printf "%s\n" "      - API=FALSE" > "$REPO_ROOT/Instance_demo/docker-compose-demo.yaml"
    printf "managed=%s\n" "$(full_validation_read_api_state)"
  '

  assert_success
  assert_output --partial "commented=TRUE"
  assert_output --partial "managed=FALSE"
}

@test "runtime matrix orders API, RCON, restart, shutdown, and plain-mode checks" {
  run env REPO_ROOT="$PROJECT_ROOT" TRACE_FILE="$BATS_TEST_TMPDIR/runtime-trace" bash -lc '
    set -e
    source "$REPO_ROOT/test/run_full_local_validation.sh"
    INSTANCE_NAME=matrix
    full_validation_record_api_state() { echo record >> "$TRACE_FILE"; }
    full_validation_container_running() { return 1; }
    full_validation_set_api_state() { echo "api:$1" >> "$TRACE_FILE"; }
    full_validation_start_and_validate() { echo "start:$1" >> "$TRACE_FILE"; }
    full_validation_check_logs_command() { echo logs >> "$TRACE_FILE"; }
    full_validation_run_rcon_matrix() { echo rcon >> "$TRACE_FILE"; }
    full_validation_manager() { echo "manager:$*" >> "$TRACE_FILE"; }
    full_validation_wait_until_ready() { echo ready >> "$TRACE_FILE"; }
    full_validation_validate_api_mode() { echo "verify:$1" >> "$TRACE_FILE"; }
    full_validation_assert_stopped() { echo stopped >> "$TRACE_FILE"; }
    full_validation_run_runtime_matrix
    cat "$TRACE_FILE"
  '

  assert_success
  assert_line "record"
  assert_output --partial $'api:TRUE\nstart:TRUE\nlogs\nrcon'
  assert_output --partial "manager:-restart 0 matrix"
  assert_output --partial "manager:-shutdown 0 matrix"
  assert_output --partial $'api:FALSE\nstart:FALSE'
  assert_output --partial $'api:TRUE\nstart:TRUE'
}

@test "full_validation_parse_args rejects invalid branch modes" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/test/run_full_local_validation.sh"
    set +e
    full_validation_parse_args test_beta --branch nightly
    status=$?
    set -e
    echo "status=$status"
  '

  assert_success
  assert_output --partial "Invalid branch mode: nightly"
  assert_output --partial "status=1"
}

@test "full_validation_detect_branch_mode ignores compose image tags without the beta mode flag" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/test/run_full_local_validation.sh"
    REPO_ROOT="$BATS_TEST_TMPDIR/full-validation-root"
    INSTANCE_NAME="test_beta"
    mkdir -p "$REPO_ROOT/Instance_test_beta"
    cat > "$REPO_ROOT/Instance_test_beta/docker-compose-test_beta.yaml" <<'"'"'EOF'"'"'
services:
  asaserver:
    image: acekorneya/asa_server:2_1_beta
EOF
    mode="$(full_validation_detect_branch_mode)"
    printf "mode=%s\n" "$mode"
  '

  assert_success
  assert_output --partial "mode=stable"
}

@test "full_validation_select_docker_command uses sudo docker when requested" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/test/run_full_local_validation.sh"
    USE_SUDO=true
    command() {
      if [ "$1" = "-v" ] && [ "$2" = "docker" ]; then
        return 0
      fi
      builtin command "$@"
    }
    full_validation_select_docker_command
    printf "cmd=%s\n" "${FULL_VALIDATION_DOCKER_CMD[*]}"
  '

  assert_success
  assert_output --partial "cmd=sudo docker"
}

@test "full_validation_wait_for_container_health succeeds when inspect reports healthy" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/test/run_full_local_validation.sh"
    INSTANCE_NAME="demo"
    HEALTH_TIMEOUT=20
    counter_file="$BATS_TEST_TMPDIR/health-counter"
    echo 0 > "$counter_file"
    full_validation_docker() {
      calls=$(cat "$counter_file")
      calls=$((calls + 1))
      echo "$calls" > "$counter_file"
      if [ "$calls" -lt 2 ]; then
        echo "starting"
      else
        echo "healthy"
      fi
    }
    full_validation_wait_for_container_health
  '

  assert_success
  assert_output --partial "Container asa_demo reported healthy."
}

@test "full_validation_wait_for_health_endpoint succeeds when curl returns ok" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/test/run_full_local_validation.sh"
    INSTANCE_NAME="demo"
    HEALTH_TIMEOUT=20
    counter_file="$BATS_TEST_TMPDIR/endpoint-counter"
    echo 0 > "$counter_file"
    full_validation_docker() {
      calls=$(cat "$counter_file")
      calls=$((calls + 1))
      echo "$calls" > "$counter_file"
      if [ "$calls" -lt 2 ]; then
        return 1
      fi
      echo "ok: server ready and responding to rcon"
    }
    full_validation_wait_for_health_endpoint
  '

  assert_success
  assert_output --partial "Health endpoint returned: ok: server ready and responding to rcon"
}
