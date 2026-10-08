#!/usr/bin/env bash
#
# Clear-volumes semantics of ./stop.sh against hermetic docker stubs.
#
# Pins the destructive-reset contract:
#   1. clearing volumes removes ALL project-labelled volumes even when the
#      active Compose model is Kong and the volume (APISIX etcd-data) is
#      declared only in docker-compose.apisix.yml;
#   2. clearing volumes still works with zero project containers;
#   3. volumes without the project label are never removed;
#   4. ./stop.sh --yes keeps volumes (never calls docker volume rm).
#
# The clear-volumes cases source stop.sh and call its stop_teardown function
# directly — there is no non-interactive production seam for the destructive
# path, by design. Case 4 exercises the real entrypoint end-to-end.
#
# The gateway selection is session-local, so stop.sh must not depend on the
# right gateway file being active to clear volumes — hence case 1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
output_file="$(mktemp)"
docker_log="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${output_file}" "${docker_log}"' EXIT

# docker stub: records full invocations; project volumes are returned only for
# a project-label-filtered `volume ls`, so a missing filter would surface the
# unrelated volume too (and fail the case-3 assertion).
cat >"${stub_bin}/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${docker_log}"
case "\$1 \$2" in
  'compose ps')
    [[ -n "\${STOP_PS_FAILS:-}" ]] && { printf 'daemon down\n' >&2; exit 1; }
    [[ -n "\${STOP_HAS_CONTAINERS:-}" ]] && printf 'cid1\n'
    exit 0
    ;;
  'compose down')
    printf 'Container db Stopping\nContainer db Removed\n'
    ;;
  'volume ls')
    case " \$* " in
      *" --filter label=com.docker.compose.project=folio-platform-minimal "*)
        printf '%s\n' "\${STOP_PROJECT_VOLUMES:-}"
        ;;
      *)
        # Unscoped listing would also see foreign volumes.
        printf '%s\n' "\${STOP_PROJECT_VOLUMES:-}" 'somebody-elses-data'
        ;;
    esac
    [[ -z "\${STOP_VOLUME_LS_FAILS:-}" ]] || { printf 'daemon down\n' >&2; exit 1; }
    ;;
  'volume rm')
    printf 'volume rm: %s\n' "\$*"
    ;;
  *)
    printf 'unexpected docker call: %s\n' "\$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "${stub_bin}/docker"

# Source stop.sh in a subshell (the run/sourced guard keeps main asleep) and
# call the teardown function with an explicit decision pair. The status lands
# in teardown_status; call sites must use this wrapper instead of guarding
# run_teardown with || or if: a "tested" call context suppresses errexit inside
# the subshell (bash ignores a set -e armed there), and stop_teardown would run
# past a real failure.
teardown_status=0
run_teardown_checked() {
  : >"${docker_log}"
  set +e
  (
    cd "${PROJECT_ROOT}"
    export PATH="${stub_bin}:${PATH}" NO_COLOR=1 TERM=dumb
    # shellcheck source=/dev/null
    source ./stop.sh
    stop_teardown "$@"
  ) >"${output_file}" 2>&1
  teardown_status=$?
  set -e
}

expect_ok() {
  run_teardown_checked "$@"
  [[ ${teardown_status} -eq 0 ]] || { cat "${output_file}" >&2; fail "teardown $* exited ${teardown_status}"; }
}

# Case 1 — Kong is the effective stop model (no APIGW_TYPE), a project-labelled
# APISIX/etcd volume exists alongside the core volumes: all must go.
STOP_HAS_CONTAINERS=1 \
  STOP_PROJECT_VOLUMES='folio-platform-minimal_etcd-data
folio-platform-minimal_db
folio-platform-minimal_kafka-data
folio-platform-minimal_vault-data' \
  expect_ok true true

grep -q -- '--remove-orphans' "${docker_log}" || fail 'case 1: containers were not removed'
if grep -q -- '--volumes' "${docker_log}"; then
  fail 'case 1: down --volumes used; volume removal must be project-scoped, not model-scoped'
fi
grep -q -- 'volume rm folio-platform-minimal_etcd-data folio-platform-minimal_db folio-platform-minimal_kafka-data folio-platform-minimal_vault-data' "${docker_log}" \
  || { cat "${output_file}" >&2; fail 'case 1: etcd-data not removed under the Kong model'; }
grep -q 'Containers and project volumes removed.' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'case 1: missing completion line'; }

# Case 2 — zero project containers, project volumes still present: the request
# must still remove the volumes (no honest-no-op shortcut).
STOP_HAS_CONTAINERS='' \
  STOP_PROJECT_VOLUMES='folio-platform-minimal_etcd-data' \
  expect_ok true true

grep -q -- 'volume rm folio-platform-minimal_etcd-data' "${docker_log}" \
  || { cat "${output_file}" >&2; fail 'case 2: volumes not removed with no containers present'; }
if grep -q 'compose down' "${docker_log}"; then
  fail 'case 2: compose down invoked with nothing to tear down'
fi
if grep -q 'Nothing to stop' "${output_file}"; then
  cat "${output_file}" >&2
  fail 'case 2: clear-volumes request was treated as a no-op'
fi

# Case 3 — an unrelated volume must never be removed: the discovery listing
# must be project-label-filtered, and only its output may reach volume rm.
STOP_HAS_CONTAINERS='' \
  STOP_PROJECT_VOLUMES='folio-platform-minimal_db' \
  expect_ok true true

if grep -q -- 'somebody-elses-data' "${docker_log}"; then
  fail 'case 3: an unrelated volume entered the removal path'
fi
grep -q -- 'volume ls -q --filter label=com.docker.compose.project=folio-platform-minimal' "${docker_log}" \
  || fail 'case 3: volume discovery was not project-label-filtered'

# Case 4 — ./stop.sh --yes keeps volumes: no volume rm, no --volumes flag.
# This runs the real entrypoint, so it pins the documented --yes decision
# (containers removed, volumes kept) end-to-end.
: >"${docker_log}"
set +e
(
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:${PATH}" NO_COLOR=1 TERM=dumb STOP_HAS_CONTAINERS=1 \
    STOP_PROJECT_VOLUMES='folio-platform-minimal_db' ./stop.sh --yes
) >"${output_file}" 2>&1
yes_status=$?
set -e
[[ ${yes_status} -eq 0 ]] || { cat "${output_file}" >&2; fail 'case 4: --yes run failed'; }

if grep -q -- 'volume rm\|--volumes' "${docker_log}"; then
  cat "${docker_log}" >&2
  fail 'case 4: --yes touched volumes'
fi
grep -q 'Containers removed. Volumes kept.' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'case 4: --yes semantics changed'; }

# A volume-discovery failure must be loud, never a silent success.
export STOP_VOLUME_LS_FAILS=1
run_teardown_checked true true
[[ ${teardown_status} -ne 0 ]] || { cat "${output_file}" >&2; fail 'volume ls failure exited 0'; }
grep -q 'docker volume ls failed' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'volume ls failure was not reported'; }

printf 'ok  stop.sh clear-volumes: project-scoped removal, works without containers, spares foreign volumes, --yes keeps volumes\n'
