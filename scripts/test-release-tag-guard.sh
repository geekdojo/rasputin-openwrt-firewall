#!/usr/bin/env bash
#
# test-release-tag-guard.sh — unit tests for scripts/rasputin-release-tag-guard.sh.
#
# WHY
#   The guard decides whether an immutable release tag may build. Its dangerous
#   failure is a false PASS — a validate-only dispatch, a run on another commit,
#   or a run from before the freshness gate existed all "succeed" in the Actions
#   UI — and nothing downstream would notice. Each case pins one decision, and
#   exactly one shape passes. (geekdojo/geekdojo-brain#208)
#
# HOW
#   A stub `gh` on PATH answers `gh api` from fixture files built here in the
#   shape of the real Actions API responses (field names checked against
#   geekdojo/rasputin-openwrt-firewall run 35058906510), and applies the
#   guard's own --jq filter to them with jq, as gh does. The stub also records
#   every endpoint so the tests can check the guard asked the API to filter on
#   event and head_sha. It deliberately does NOT apply those filters itself: it
#   plays an API that ignored them, which is the case the guard's own
#   head_sha/event re-check exists for.
#
#   The last check reads .github/workflows/release.yml: the guard looks for a
#   step by NAME, so a renamed step would make every tag build fail — or worse,
#   a guard updated without the workflow would pass nothing ever again. The name
#   must appear exactly once.
#
# NEEDS: bash, jq.
#
# Usage: ./scripts/test-release-tag-guard.sh

set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$SRC/scripts/rasputin-release-tag-guard.sh"
command -v jq >/dev/null 2>&1 || { echo "missing tool: jq" >&2; exit 2; }

TMP="$(mktemp -d -t rasputin-tag-guard-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf '  ✓ %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  ✗ %s\n' "$*" >&2; fail=$((fail + 1)); }

REPO="geekdojo/rasputin-openwrt-firewall"
SHA="86f35906520d42f4afacb3f1abf02af1efa176fe"
OTHER="bb3bcd5aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
GATE="$(sed -n 's/^GATE_STEP="\(.*\)"$/\1/p' "$GUARD")"
[ -n "$GATE" ] || { echo "could not read GATE_STEP from $GUARD" >&2; exit 2; }

# --- stub gh ---------------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal `gh api [--paginate] <endpoint> [--jq <filter>]` over fixture files.
set -uo pipefail
[ "${1:-}" = api ] || { echo "stub gh: only 'api' is supported" >&2; exit 1; }
shift
endpoint="" filter="."
while [ "$#" -gt 0 ]; do
	case "$1" in
		--paginate) ;;
		--jq) filter="$2"; shift ;;
		-*) echo "stub gh: unexpected flag $1" >&2; exit 1 ;;
		*) endpoint="$1" ;;
	esac
	shift
done
printf '%s\n' "$endpoint" >> "$STUB_LOG"
case "$endpoint" in
	*/actions/workflows/release.yml/runs\?*) file="$FIXTURES/runs.json" ;;
	*/actions/runs/*/jobs\?*)
		id="${endpoint#*/actions/runs/}"; id="${id%%/*}"
		file="$FIXTURES/jobs-$id.json" ;;
	*) echo "stub gh: no fixture route for $endpoint" >&2; exit 1 ;;
esac
[ -f "$file" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
jq -c "$filter" "$file"
STUB
chmod +x "$TMP/bin/gh"

# --- fixture builders (real API field names; irrelevant fields trimmed) ---------
# run_json ID HEAD_SHA EVENT STATUS CONCLUSION
run_json() {
	jq -n --argjson id "$1" --arg sha "$2" --arg event "$3" --arg status "$4" --arg conclusion "$5" --arg repo "$REPO" '{
		id: $id, name: "release", node_id: "WFR_fixture", head_branch: "main", head_sha: $sha,
		path: ".github/workflows/release.yml", display_title: "release", run_number: ($id % 1000),
		event: $event, status: $status,
		conclusion: (if $conclusion == "null" then null else $conclusion end),
		workflow_id: 170000001, check_suite_id: 1, run_attempt: 1,
		url: "https://api.github.com/repos/\($repo)/actions/runs/\($id)",
		html_url: "https://github.com/\($repo)/actions/runs/\($id)",
		jobs_url: "https://api.github.com/repos/\($repo)/actions/runs/\($id)/jobs",
		created_at: "2026-09-16T05:17:10Z", updated_at: "2026-09-16T05:30:00Z" }'
}
# runs FILE RUN_JSON... — a workflow-runs response
runs() {
	local out="$1"; shift
	printf '%s\n' "$@" | jq -s '{total_count: length, workflow_runs: .}' > "$out"
}
# step NAME CONCLUSION
step() { jq -nc --arg n "$1" --arg c "$2" '{name: $n, status: "completed", conclusion: $c, number: 1, started_at: "2026-09-16T05:17:27Z", completed_at: "2026-09-16T05:17:27Z"}'; }
# job NAME CONCLUSION STEP_JSON...
job() {
	local name="$1" conclusion="$2"; shift 2
	printf '%s\n' "$@" | jq -sc --arg n "$name" --arg c "$conclusion" '{
		id: 90000001, run_id: 1, name: $n, status: "completed", conclusion: $c,
		head_branch: "main", head_sha: "fixture", workflow_name: "release", run_attempt: 1,
		labels: ["ubuntu-latest"], steps: map(select(. != null))}'
}
# jobs FILE JOB_JSON...
jobs() {
	local out="$1"; shift
	printf '%s\n' "$@" | jq -s '{total_count: length, jobs: .}' > "$out"
}
validate_job() { job validate success "$(step "Set up job" success)" "$(step "Validate shipped files" success)"; }
build_job() { # build_job JOB_CONCLUSION GATE_CONCLUSION|none
	if [ "$2" = none ]; then
		job build "$1" "$(step "Set up job" success)" "$(step "Fetch Snort3 Community Rules" success)" "$(step "ImageBuilder build" success)"
	else
		job build "$1" "$(step "Set up job" success)" "$(step "$GATE" "$2")" "$(step "Fetch Snort3 Community Rules" success)" "$(step "ImageBuilder build" success)"
	fi
}
skipped_job() { printf '%s' "{\"id\": 90000009, \"name\": \"$1\", \"status\": \"completed\", \"conclusion\": \"skipped\", \"steps\": []}"; }

# --- runner -----------------------------------------------------------------------
# case_dir NAME — fresh fixture dir; sets FIX
case_dir() { FIX="$TMP/$1"; mkdir -p "$FIX"; }
# check NAME WANT_EXIT — run the guard against $FIX
check() {
	local name="$1" want="$2" got=0
	: > "$FIX/calls.log"
	PATH="$TMP/bin:$PATH" FIXTURES="$FIX" STUB_LOG="$FIX/calls.log" \
		"$GUARD" "$REPO" "$SHA" > "$FIX/out.log" 2>&1 || got=$?
	if [ "$got" -eq "$want" ]; then
		ok "$name: exit $got"
	else
		bad "$name: exit $got, want $want"
		sed 's/^/      | /' "$FIX/out.log" >&2
	fi
}
has()   { if grep -Fq -- "$2" "$FIX/out.log"; then ok "$1: $3"; else bad "$1: $3 (missing: $2)"; fi; }
hasnt() { if grep -Fq -- "$2" "$FIX/out.log"; then bad "$1: $3 (unexpected: $2)"; else ok "$1: $3"; fi; }
PREFLIGHT="Run the pre-flight on this commit first: gh workflow run release.yml -f full_build=true --ref main"

echo "== decisions"

case_dir no-runs
runs "$FIX/runs.json"
check no-runs 1
has no-runs "$PREFLIGHT" "tells the operator to run the pre-flight"
has no-runs "no workflow_dispatch runs of release.yml on $SHA at all" "says there were no runs"
if grep -q "event=workflow_dispatch" "$FIX/calls.log" && grep -q "head_sha=$SHA" "$FIX/calls.log"; then
	ok "no-runs: asked the API to filter on event and head_sha"
else
	bad "no-runs: query did not filter on event + head_sha: $(cat "$FIX/calls.log")"
fi

case_dir other-commit
runs "$FIX/runs.json" "$(run_json 101 "$OTHER" workflow_dispatch completed success)"
jobs "$FIX/jobs-101.json" "$(validate_job)" "$(build_job success success)"
check other-commit 1
has other-commit "run 101: ran on a different commit ($OTHER)" "rejects a green gate run on another commit"
has other-commit "$PREFLIGHT" "tells the operator to run the pre-flight"

case_dir validate-only
runs "$FIX/runs.json" "$(run_json 102 "$SHA" workflow_dispatch completed success)"
jobs "$FIX/jobs-102.json" "$(validate_job)" "$(skipped_job build)" "$(skipped_job smoke-fw)" "$(skipped_job sign-and-release)"
check validate-only 1
has validate-only "run 102: validate-only dispatch" "rejects a successful validate-only dispatch"

case_dir build-failed
runs "$FIX/runs.json" "$(run_json 103 "$SHA" workflow_dispatch completed failure)"
jobs "$FIX/jobs-103.json" "$(validate_job)" "$(build_job failure success)" "$(skipped_job smoke-fw)"
check build-failed 1
has build-failed "run 103: freshness gate passed but the \"build\" job concluded failure" "rejects a failed build job even with the gate green"

case_dir gate-failed
runs "$FIX/runs.json" "$(run_json 104 "$SHA" workflow_dispatch completed failure)"
jobs "$FIX/jobs-104.json" "$(validate_job)" "$(build_job failure failure)"
check gate-failed 1
has gate-failed "run 104: freshness gate step concluded failure" "rejects a failed freshness gate"

case_dir pre-gate
runs "$FIX/runs.json" "$(run_json 105 "$SHA" workflow_dispatch completed success)"
jobs "$FIX/jobs-105.json" "$(validate_job)" "$(build_job success none)"
check pre-gate 1
has pre-gate "run 105: \"build\" job has no \"$GATE\" step (run predates the gate)" "rejects a full build from before the gate existed"

case_dir smoke-failed
runs "$FIX/runs.json" "$(run_json 106 "$SHA" workflow_dispatch completed failure)"
jobs "$FIX/jobs-106.json" "$(validate_job)" "$(build_job success success)" "$(job smoke-fw failure)"
check smoke-failed 1
has smoke-failed "run 106: run concluded failure" "rejects a run that failed after the build"

case_dir in-progress
runs "$FIX/runs.json" "$(run_json 107 "$SHA" workflow_dispatch in_progress null)"
jobs "$FIX/jobs-107.json" "$(validate_job)" "$(build_job success success)"
check in-progress 1
has in-progress "run 107: not finished (status in_progress)" "rejects an unfinished run"

case_dir push-event
runs "$FIX/runs.json" "$(run_json 108 "$SHA" push completed success)"
jobs "$FIX/jobs-108.json" "$(validate_job)" "$(build_job success success)"
check push-event 1
has push-event "run 108: event is push, not workflow_dispatch" "rejects a tag/push run as its own pre-flight"

case_dir pass
runs "$FIX/runs.json" "$(run_json 109 "$SHA" workflow_dispatch completed success)"
jobs "$FIX/jobs-109.json" "$(validate_job)" "$(build_job success success)" "$(job smoke-fw success)" "$(skipped_job sign-and-release)"
check pass 0
has pass "tag guard: OK — pre-flight run 109 on $SHA" "names the qualifying run"
hasnt pass "::error::" "no error annotation"

case_dir pass-among-rejects
runs "$FIX/runs.json" \
	"$(run_json 110 "$SHA" workflow_dispatch completed success)" \
	"$(run_json 111 "$SHA" workflow_dispatch completed success)" \
	"$(run_json 112 "$OTHER" workflow_dispatch completed success)"
jobs "$FIX/jobs-110.json" "$(validate_job)" "$(skipped_job build)"
jobs "$FIX/jobs-111.json" "$(validate_job)" "$(build_job success success)" "$(job smoke-fw success)"
jobs "$FIX/jobs-112.json" "$(validate_job)" "$(build_job success success)"
check pass-among-rejects 0
has pass-among-rejects "pre-flight run 111" "picks the one qualifying run"

echo "== could-not-determine is not \"no runs\""

case_dir runs-api-error
check runs-api-error 2
has runs-api-error "could not query the GitHub Actions API (listing release.yml runs)" "reports the API failure"
hasnt runs-api-error "no workflow_dispatch runs" "does not claim there were no runs"

case_dir jobs-api-error
runs "$FIX/runs.json" "$(run_json 113 "$SHA" workflow_dispatch completed success)"
check jobs-api-error 2
has jobs-api-error "could not query the GitHub Actions API (listing jobs of run 113)" "reports the jobs API failure"

echo "== arguments"
FIX="$TMP/args"; mkdir -p "$FIX"
got=0; "$GUARD" "$REPO" "not-a-sha" > "$FIX/out.log" 2>&1 || got=$?
[ "$got" -eq 2 ] && ok "bad sha: exit 2" || bad "bad sha: exit $got, want 2"
got=0; "$GUARD" "$REPO" > "$FIX/out.log" 2>&1 || got=$?
[ "$got" -eq 2 ] && ok "missing sha: exit 2" || bad "missing sha: exit $got, want 2"

echo "== release.yml agrees with the guard"
n="$(grep -cE "^[[:space:]]*-?[[:space:]]*name:[[:space:]]*\"?$GATE\"?[[:space:]]*\$" "$SRC/.github/workflows/release.yml")"
[ "$n" = 1 ] && ok "release.yml has exactly one step named \"$GATE\"" || bad "release.yml has $n steps named \"$GATE\", want 1"
build_block="$(awk '/^  build:$/{f=1; next} f && /^  [A-Za-z0-9_-]+:$/{f=0} f' "$SRC/.github/workflows/release.yml")"
printf '%s\n' "$build_block" | grep -qE "name:[[:space:]]*\"?$GATE\"?[[:space:]]*\$" \
	&& ok "the gate step lives in the \"build\" job" || bad "the gate step is not in the \"build\" job"

echo
if [ "$fail" -eq 0 ]; then
	echo "tag guard: $pass check(s) passed"
	exit 0
fi
echo "tag guard: $fail check(s) FAILED, $pass passed" >&2
exit 1
