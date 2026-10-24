#!/usr/bin/env bats

load '../test_helper/bats-support/load.bash'
load '../test_helper/bats-assert/load.bash'
load '../test_helper/project.bash'

@test "update_server.sh can be sourced without executing the update workflow" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/scripts/update_server.sh"
    printf "main=%s\n" "$(type -t main)"
  '

  assert_success
  assert_output --partial "main=function"
}

@test "server_needs_update returns 0 for dirty-flag restarts and records the current build" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/scripts/update_server.sh"
    server_needs_update_or_restart() { return 0; }
    has_dirty_flag() { return 0; }
    get_current_build_id() { echo 24680; }
    set +e
    server_needs_update
    status=$?
    set -e
    printf "status=%s\n" "$status"
    printf "current=%s\n" "$current_build_id"
  '

  assert_success
  assert_output --partial "RESTART REQUIRED - Instance marked dirty by another instance"
  assert_output --partial "status=0"
  assert_output --partial "current=24680"
}

@test "server_needs_update returns 1 when no update or restart is required" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/scripts/update_server.sh"
    server_needs_update_or_restart() { return 1; }
    set +e
    server_needs_update
    status=$?
    set -e
    printf "status=%s\n" "$status"
  '

  assert_success
  assert_output --partial "Server is up to date - no update or restart needed"
  assert_output --partial "status=1"
}

@test "notify_players_of_update emits the short countdown sequence" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/scripts/update_server.sh"
    sleep() { :; }
    send_rcon_command() {
      printf "msg=%s\n" "$1"
    }
    notify_players_of_update 1
  '

  assert_success
  assert_output --partial "msg=ServerChat Server update detected! Server will restart in 1 minutes for the update."
  assert_output --partial "msg=ServerChat Server restarting in 30 seconds for update..."
  assert_output --partial "msg=ServerChat 5..."
  assert_output --partial "msg=ServerChat Server restarting NOW!"
}

@test "shutdown_server_for_update aborts when the shared two-stage stop fails" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    source "$REPO_ROOT/scripts/update_server.sh"
    safe_container_stop() { echo "verified-stop=failed"; return 1; }
    if shutdown_server_for_update; then
      echo "result=unexpected-success"
    else
      echo "result=failed"
    fi
  '

  assert_success
  assert_output --partial "verified-stop=failed"
  assert_output --partial "result=failed"
  refute_output --partial "result=unexpected-success"
}

@test "shutdown_server_for_update acknowledges an active coordinated barrier only after verified saves" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    source "$REPO_ROOT/scripts/update_server.sh"
    safe_container_stop() { echo "verified-stop=ok"; return 0; }
    update_coordination_has_active_cycle() { return 0; }
    update_coordination_instance_is_participant() { return 0; }
    update_coordination_mark_shutdown_ready() { echo "barrier=acknowledged"; }
    shutdown_server_for_update
  '

  assert_success
  assert_output --partial "verified-stop=ok"
  assert_output --partial "barrier=acknowledged"
  assert_output --partial "acknowledged the coordinated verified-shutdown barrier"
}

@test "trigger_container_restart delegates durable state and restart signaling" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/scripts/update_server.sh"
    request_verified_container_restart() { printf "request=%s:%s:%s\n" "$1" "$2" "$3"; }
    trigger_container_restart FOLLOWER_COORDINATION_RESTART 24680
  '

  assert_success
  assert_output --partial "request=FOLLOWER_COORDINATION_RESTART:24680:/home/pok/container_update_restart.log"
}

@test "rollback update preflight rejects incompatible candidates without shutdown" {
  run env REPO_ROOT="$PROJECT_ROOT" BATS_TMP="$BATS_TEST_TMPDIR/update-preflight" bash -lc '
    set -e
    source "$REPO_ROOT/scripts/update_server.sh"
    rollback_state_is_active() { return 0; }
    acquire_update_lock() { echo lock; return 0; }
    release_update_lock() { echo unlock; }
    create_temp_download_dir() { mkdir -p "$BATS_TMP/staged"; echo "$BATS_TMP/staged"; }
    steamcmd_download_to_dir() { echo download; return 0; }
    prepare_staged_asaapi_cache() { echo incompatible; return 1; }
    record_failed_rollback_retry() { echo recorded; }
    shutdown_server_for_update() { echo unexpected-shutdown; }
    if preflight_rollback_update; then echo unexpected-success; else echo held-online; fi
  '

  assert_success
  assert_output --partial "incompatible"
  assert_output --partial "recorded"
  assert_output --partial "held-online"
  assert_output --partial "unlock"
  refute_output --partial "unexpected-shutdown"
}

@test "update_server main participates in an active coordination cycle led by another instance even when configured as MASTER" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/scripts/update_server.sh"
    UPDATE_SERVER=TRUE
    UPDATE_COORDINATION_ROLE=MASTER
    UPDATE_COORDINATION_PRIORITY=1
    INSTANCE_NAME=beta
    prepare_runtime_env() { :; }
    get_current_build_id() { echo 24786897; }
    get_build_id_from_acf() { echo 24718469; }
    update_coordination_cleanup() { :; }
    shared_update_policy_allows_automatic_updates() { return 0; }
    remove_stale_lock() { :; }
    server_needs_update() { return 0; }
    rollback_state_is_active() { return 1; }
    has_dirty_flag() { return 1; }
    update_coordination_enabled() { return 0; }
    update_coordination_has_active_cycle() { return 0; }
    update_coordination_is_active_leader() { return 1; }
    UPDATE_COORDINATION_STATE_ACTIVE_LEADER_INSTANCE="alpha"
    notify_players_of_update() { printf "notice=%s\n" "$1"; }
    shutdown_server_for_update() { echo "shutdown=verified"; return 0; }
    trigger_container_restart() { printf "restart=%s:%s\n" "$1" "$2"; }
    main
  '

  assert_success
  assert_output --partial "Active coordination cycle detected (Leader: alpha)"
  assert_output --partial "Participating in coordinated update: starting countdown notice and verified shutdown"
  assert_output --partial "notice=30"
  assert_output --partial "shutdown=verified"
  assert_output --partial "restart=FOLLOWER_COORDINATION_RESTART:24786897"
}

@test "update_server main initiates coordination cycle when configured as MASTER and no cycle is active" {
  run env REPO_ROOT="$PROJECT_ROOT" bash -lc '
    set -e
    source "$REPO_ROOT/scripts/update_server.sh"
    UPDATE_SERVER=TRUE
    UPDATE_COORDINATION_ROLE=MASTER
    UPDATE_COORDINATION_PRIORITY=1
    INSTANCE_NAME=alpha
    prepare_runtime_env() { :; }
    get_current_build_id() { echo 24786897; }
    get_build_id_from_acf() { echo 24718469; }
    update_coordination_cleanup() { :; }
    shared_update_policy_allows_automatic_updates() { return 0; }
    remove_stale_lock() { :; }
    server_needs_update() { return 0; }
    rollback_state_is_active() { return 1; }
    has_dirty_flag() { return 1; }
    update_coordination_enabled() { return 0; }
    update_coordination_has_active_cycle() { return 1; }
    update_coordination_is_master_role() { return 0; }
    update_coordination_begin_cycle() { printf "cycle_created=%s\n" "$1"; return 0; }
    update_coordination_start_heartbeat() { echo "heartbeat=started"; }
    notify_players_of_update() { printf "notice=%s\n" "$1"; }
    shutdown_server_for_update() { echo "shutdown=verified"; return 0; }
    trigger_container_restart() { printf "restart=%s:%s\n" "$1" "$2"; }
    main
  '

  assert_success
  assert_output --partial "cycle_created=24786897"
  assert_output --partial "This instance is the configured coordination master and will lead the shared update cycle"
  assert_output --partial "heartbeat=started"
  assert_output --partial "notice=30"
  assert_output --partial "shutdown=verified"
  assert_output --partial "restart=UPDATE_RESTART:24786897"
}
