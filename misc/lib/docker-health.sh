#!/usr/bin/env bash
# Docker runtime readiness helpers.
#
# Health and HTTP-readiness waits used by the bootstrap flow. The container
# health wait is dynamic (it inspects whatever is actually running), so it adapts
# automatically to the number of Keycloak nodes or any other optional service.
#
# Requires the output helpers from folio-common.sh (step/ok/warn).

[[ -n "${_FOLIO_DOCKER_HEALTH_SOURCED:-}" ]] && return 0
readonly _FOLIO_DOCKER_HEALTH_SOURCED=1

HEALTH_READY_COUNT=0
HEALTH_TOTAL_COUNT=0

# Block until every running container that declares a health check reports
# healthy. Containers without a health check are ignored.
wait_for_all_healthy() {
  local i=0 spin_char health_status unhealthy crashed cid inspect_line
  local unhealthy_count=0
  local timeout_seconds=300 elapsed=0
  local project="${COMPOSE_PROJECT_NAME:-folio-platform-minimal}"
  local exited_filter=(--filter "label=com.docker.compose.project=${project}" --filter status=exited --filter status=dead)

  # Baseline of containers already exited before this wait (stale from prior
  # runs) — only crashes that happen during THIS wait should fail it.
  local pre_exited
  pre_exited="$(docker ps -aq "${exited_filter[@]}" 2>/dev/null | sort)"

  ui_timer_start health_wait
  ui_activity_start 'Verifying container health'
  while true; do
    # Fail fast if a long-running (healthcheck-declaring) service crashes during
    # this wait. `docker ps -q` below only sees running containers, so a crashed
    # service would otherwise stay invisible to the health check.
    crashed=''
    while IFS= read -r cid || [[ -n "${cid}" ]]; do
      [[ -n "${cid}" ]] || continue
      inspect_line="$(docker inspect \
        --format '{{if .Config.Healthcheck}}{{.Name}} (exit {{.State.ExitCode}}{{if .State.OOMKilled}}, OOMKilled{{end}}){{end}}' \
        "${cid}" 2>/dev/null || true)"
      [[ -n "${inspect_line}" ]] && crashed="${crashed}${inspect_line}"$'\n'
    done < <(comm -13 <(printf '%s\n' "$pre_exited") <(docker ps -aq "${exited_filter[@]}" 2>/dev/null | sort))
    if [[ -n "$crashed" ]]; then
      ui_activity_finish fail 'Container health failed' "$(ui_timer_read health_wait 2>/dev/null || printf 0)"
      ui_fail 'container(s) crashed while waiting for health:'
      ui_info "$crashed"
      exit 1
    fi

    health_status=''
    while IFS= read -r cid || [[ -n "${cid}" ]]; do
      [[ -n "${cid}" ]] || continue
      inspect_line="$(docker inspect --format '{{if .State.Health}}{{.Name}} {{.State.Health.Status}}{{end}}' "${cid}" 2>/dev/null || true)"
      [[ -n "${inspect_line}" ]] && health_status="${health_status}${inspect_line}"$'\n'
    done < <(docker ps -q 2>/dev/null || true)
    unhealthy="$(printf '%s\n' "$health_status" | grep -Ev ' healthy$' | grep -v '^[[:space:]]*$' || true)"
    if [[ -n "$health_status" ]]; then
      HEALTH_TOTAL_COUNT="$(printf '%s\n' "$health_status" | grep -c '[^[:space:]]' | tr -d '[:space:]')"
    else
      HEALTH_TOTAL_COUNT=0
    fi
    if [[ -n "$unhealthy" ]]; then
      unhealthy_count="$(printf '%s\n' "$unhealthy" | wc -l | tr -d '[:space:]')"
    else
      unhealthy_count=0
    fi
    HEALTH_READY_COUNT=$((HEALTH_TOTAL_COUNT - unhealthy_count))

    if [[ -z "$unhealthy" ]]; then
      ui_activity_finish ok 'Container health ready' "$(ui_timer_read health_wait)"
      break
    fi

    if [[ $elapsed -ge $timeout_seconds ]]; then
      ui_activity_finish fail 'Container health timed out' "$(ui_timer_read health_wait 2>/dev/null || printf 0)"
      ui_error 'Timed out waiting for containers to become healthy:'
      ui_info "$unhealthy"
      exit 1
    fi

    spin_char="$(_ui_spin_frame "$((i++))")"
    ui_activity_tick "$spin_char" 'Verifying container health' \
      "${HEALTH_READY_COUNT}/${HEALTH_TOTAL_COUNT}" "$(ui_timer_read health_wait)"
    sleep 2
    elapsed=$((elapsed + 2))
  done
}

# Recover the Kong api-gateway if its admin API is unavailable.
recover_api_gateway_if_needed() {
  local container_state admin_status

  container_state="$(docker inspect --format '{{.State.Status}}' api-gateway 2>/dev/null || true)"
  container_state="${container_state%% *}"
  admin_status="$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8001/status 2>/dev/null || true)"

  if [[ "$container_state" == 'running' && "$admin_status" == '200' ]]; then
    return 0
  fi
  if [[ "$container_state" == 'starting' || "$container_state" == 'restarting' ]]; then
    return 0
  fi

  ui_warn "api-gateway admin API unavailable (HTTP ${admin_status:-000}, state ${container_state:-missing}); attempting recovery..."

  if [[ -z "$container_state" || "$container_state" != 'running' ]]; then
    (
      cd "${DOCKER_DIR}"
      docker compose --profile core up -d
    )
    return 0
  fi

  docker exec api-gateway sh -lc 'rm -f /usr/local/kong/pids/nginx.pid && export KONG_PLUGINS="${KONG_PLUGINS},auth-headers-manager" && kong migrations bootstrap && kong migrations up && kong migrations finish && kong start' >/dev/null
}

# Wait until an HTTP endpoint answers with one of the expected status codes.
wait_for_http_ready() {
  local url="$1"
  local description="$2"
  local expected_codes="${3:-200}"
  local timeout_seconds="${4:-120}"
  local elapsed=0 status_code=""
  local i=0 spin_char

  ui_timer_start http_ready
  ui_activity_start "Verifying ${description}"
  while [[ $elapsed -lt $timeout_seconds ]]; do
    status_code="$(curl -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"

    if [[ " $expected_codes " == *" ${status_code} "* ]]; then
      ui_activity_finish ok "${description} responding HTTP ${status_code}" "$(ui_timer_read http_ready)"
      return 0
    fi

    spin_char="$(_ui_spin_frame "$((i++))")"
    ui_activity_tick "${spin_char}" "Verifying ${description}" "HTTP ${status_code:-000}" "$(ui_timer_read http_ready)"
    sleep 2
    elapsed=$((elapsed + 2))
  done

  ui_activity_finish fail "${description} did not become ready" "$(ui_timer_read http_ready 2>/dev/null || printf 0)"
  ui_error "Timed out waiting for ${description} at ${url} (last HTTP ${status_code:-000})."
  return 1
}

# On a failed bootstrap, print a bounded diagnostic snapshot: compose status plus
# the tail of logs for only the unhealthy/exited containers. No streaming — this
# is meant to inform a manual re-run, not to replace `docker logs`.
dump_failure_diagnostics() {
  local project="${COMPOSE_PROJECT_NAME:-folio-platform-minimal}"
  local broken='' cid name line run_total saw_container=false printed_header=false header_line=''
  local inspect_line inspect_id inspect_state inspect_health

  # Close the failing phase as failed and recap before the snapshot box, so the
  # operator sees how far the run got. No-ops when called outside a phase.
  run_total="$(ui_fmt_duration "$(ui_timer_read run_total 2>/dev/null || printf 0)")"
  ui_phase_finish failed
  ui_recap "${run_total}"

  ui_box_top "$(ui_glyph warn) diagnostic snapshot" '' warn
  [[ -n "${UI_FAILED_PHASE:-}" ]] && ui_box_kv 'Failed phase' "${UI_FAILED_PHASE}"
  [[ -n "${UI_FAILED_STEP:-}" ]] && ui_box_kv 'Failed step' "${UI_FAILED_STEP}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    line="${line//$'\t'/  }"
    case "${line}" in
      NAMES[[:space:]]*STATUS*) header_line="${line}"; continue ;;
    esac
    saw_container=true
    if [[ "${printed_header}" != true && -n "${header_line}" ]]; then
      ui_box_row "${header_line}"
      printed_header=true
    fi
    ui_box_row "${line}"
  done < <(docker ps -a --filter "label=com.docker.compose.project=${project}" \
    --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || true)

  [[ "${saw_container}" == true ]] || ui_box_row 'No compose containers were created before the failure.'

  while IFS= read -r cid || [[ -n "${cid}" ]]; do
    [[ -n "${cid}" ]] || continue
    inspect_line="$(docker inspect \
      --format '{{.Id}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
      "${cid}" 2>/dev/null || true)"
    inspect_id="${inspect_line%% *}"
    inspect_line="${inspect_line#* }"
    inspect_state="${inspect_line%% *}"
    inspect_health="${inspect_line#* }"
    [[ "${inspect_health}" == "${inspect_state}" ]] && inspect_health=''
    if [[ "${inspect_state}" == "exited" || "${inspect_state}" == "dead" || "${inspect_health}" == "unhealthy" ]]; then
      broken="${broken}${inspect_id}"$'\n'
    fi
  done < <(docker ps -aq --filter "label=com.docker.compose.project=${project}" 2>/dev/null || true)

  if [[ -n "$broken" ]]; then
    while read -r cid; do
      [[ -n "$cid" ]] || continue
      name="$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##')"
      ui_box_sep
      ui_box_row "${name} - last log lines"
      docker logs --tail 6 "$cid" 2>&1 \
        | while IFS= read -r line || [[ -n "${line}" ]]; do ui_box_row "  ${line}"; done || true
    done <<< "$broken"
  fi
  ui_box_bottom

  _ui_emit "$(ui_c run "$(ui_glyph arrow)") Re-run ./start.sh - every step is idempotent."
  [[ "${DOCKER_MEMORY_LOW:-false}" == true ]] \
    && _ui_emit "  $(ui_c dim 'Raise Docker memory to 12 GB+ in Docker Desktop -> Settings -> Resources, then retry.')"
  return 0
}
