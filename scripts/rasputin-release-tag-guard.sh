#!/usr/bin/env bash
#
# rasputin-release-tag-guard.sh — refuse a release TAG build unless the exact
# commit it points at already passed a pre-flight build, freshness gate included.
#
# WHY (geekdojo/geekdojo-brain#208)
#   Release tags are immutable: a tag build that fails burns the version. On
#   2026-09-16 the firewall's 2026.09.2 tag failed on a Snort rules pin that a
#   dispatch build had validated green hours earlier, and the whole lockstep line
#   was withdrawn and re-cut as 2026.09.3. The rules now come from a content-
#   addressed mirror (so upstream moving cannot change what a tag builds) and
#   the freshness check runs only on the pre-flight — which means a tag build is
#   only safe AFTER a pre-flight. This guard makes "after" a checked fact
#   instead of a step someone has to remember.
#
# THE RULE — a tag build passes only if some run of release.yml has ALL of:
#   - event == workflow_dispatch
#   - head_sha == the tagged commit (the API is asked to filter on it, and the
#     result is re-checked here, so an API that ignored the filter cannot let a
#     run on another commit through)
#   - status == completed and conclusion == success
#   - a job named "build" with conclusion == success
#   - in that job, a step named exactly $GATE_STEP with conclusion == success
#   Checking the gate STEP, not just the run, is the point: a validate-only
#   dispatch (full_build=false) also concludes "success" but its build job is
#   skipped, and a run from before the gate existed has no such step at all.
#
# EXIT
#   0  a qualifying pre-flight exists
#   1  none does — the error says exactly why each candidate run was rejected
#   2  the question could not be answered (bad arguments, Actions API error).
#      Never read as "no runs": an API failure is not evidence of anything.
#
# NEEDS
#   gh (authenticated; in Actions GH_TOKEN with `actions: read`) and jq.
#
# Usage:
#   ./scripts/rasputin-release-tag-guard.sh <owner/repo> <40-hex commit sha>
#   e.g. ./scripts/rasputin-release-tag-guard.sh geekdojo/rasputin-openwrt-firewall "$(git rev-parse '2026.09.3^{commit}')"
#
# Tests: scripts/test-release-tag-guard.sh (fixture API responses) and
# scripts/test-release-tag-guard-live.sh (read-only, the real API).

set -euo pipefail

WORKFLOW_FILE="release.yml"
BUILD_JOB="build"
# Must equal the `name:` of the gate step in .github/workflows/release.yml.
# scripts/test-release-tag-guard.sh fails if the two ever differ.
GATE_STEP="Snort rules freshness gate"
PREFLIGHT_CMD="gh workflow run release.yml -f full_build=true --ref main"

usage() { echo "usage: $0 <owner/repo> <40-hex commit sha>" >&2; exit 2; }
[ "$#" -eq 2 ] || usage
repo="$1"
sha="$2"
printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || usage
printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$' || usage

api_fail() {
	echo "::error::tag guard could not query the GitHub Actions API ($1). Refusing to build: an API error is not evidence that a pre-flight ran." >&2
	echo "  If this is a permissions error, the job needs 'actions: read'." >&2
	exit 2
}

echo "tag guard: looking for a green pre-flight of $WORKFLOW_FILE on $repo@$sha"

runs_json="$(gh api --paginate \
	"repos/$repo/actions/workflows/$WORKFLOW_FILE/runs?event=workflow_dispatch&head_sha=$sha&per_page=100" \
	--jq '.workflow_runs[] | {id, run_number, event, head_sha, head_branch, status, conclusion, html_url}')" \
	|| api_fail "listing $WORKFLOW_FILE runs"

run_ids="$(printf '%s\n' "$runs_json" | jq -rs 'map(select(type == "object") | .id) | unique | .[]')" \
	|| api_fail "parsing the runs response"

# Assemble one document: [run + {jobs: [...]}, ...]. Jobs come from the LATEST
# attempt of each run, matching the run's own status/conclusion.
doc_runs="[]"
while IFS= read -r id; do
	[ -n "$id" ] || continue
	printf '%s' "$id" | grep -Eq '^[0-9]+$' || api_fail "unexpected run id '$id'"
	jobs_json="$(gh api --paginate "repos/$repo/actions/runs/$id/jobs?filter=latest&per_page=100" \
		--jq '.jobs[] | {name, status, conclusion, steps: [(.steps // [])[] | {name, status, conclusion}]}')" \
		|| api_fail "listing jobs of run $id"
	run="$(printf '%s\n' "$runs_json" | jq -cs --argjson id "$id" 'map(select(.id == $id)) | first')" \
		|| api_fail "reading run $id"
	doc_runs="$(jq -c --argjson run "$run" --slurpfile jobs <(printf '%s\n' "$jobs_json") \
		'. + [$run + {jobs: $jobs}]' <<<"$doc_runs")" || api_fail "assembling run $id"
done <<<"$run_ids"

# The decision. One line per candidate run: "<verdict>\t<run id>\t<reason>\t<url>".
verdicts="$(jq -r --arg sha "$sha" --arg job "$BUILD_JOB" --arg step "$GATE_STEP" '
	.[] as $r
	| ([$r.jobs[] | select(.name == $job)] | first) as $b
	| ([($b.steps // [])[] | select(.name == $step)] | first) as $g
	| [ (if $r.event != "workflow_dispatch" then "reject"
	     elif $r.head_sha != $sha then "reject"
	     elif $r.status != "completed" then "reject"
	     elif $b == null then "reject"
	     elif $b.conclusion == "skipped" then "reject"
	     elif $g == null then "reject"
	     elif $g.conclusion != "success" then "reject"
	     elif $b.conclusion != "success" then "reject"
	     elif $r.conclusion != "success" then "reject"
	     else "PASS" end),
	    ($r.id | tostring),
	    (if $r.event != "workflow_dispatch" then "event is \($r.event), not workflow_dispatch"
	     elif $r.head_sha != $sha then "ran on a different commit (\($r.head_sha))"
	     elif $r.status != "completed" then "not finished (status \($r.status))"
	     elif $b == null then "has no \"\($job)\" job"
	     elif $b.conclusion == "skipped" then "validate-only dispatch: the \"\($job)\" job was skipped, so the freshness gate never ran"
	     elif $g == null then "\"\($job)\" job has no \"\($step)\" step (run predates the gate)"
	     elif $g.conclusion != "success" then "freshness gate step concluded \($g.conclusion)"
	     elif $b.conclusion != "success" then "freshness gate passed but the \"\($job)\" job concluded \($b.conclusion)"
	     elif $r.conclusion != "success" then "run concluded \($r.conclusion)"
	     else "freshness gate passed, build and run succeeded" end),
	    $r.html_url
	  ]
	| @tsv' <<<"$doc_runs")" || api_fail "evaluating runs"

pass_line="$(printf '%s\n' "$verdicts" | awk -F '\t' '$1 == "PASS" { print; exit }')"
if [ -n "$pass_line" ]; then
	IFS=$'\t' read -r _ pass_id pass_reason pass_url <<<"$pass_line"
	echo "tag guard: OK — pre-flight run $pass_id on $sha: $pass_reason"
	echo "  $pass_url"
	exit 0
fi

{
	echo "::error::No green pre-flight build on commit $sha. Run the pre-flight on this commit first: $PREFLIGHT_CMD"
	echo "A release tag build requires a successful workflow_dispatch run of $WORKFLOW_FILE on the EXACT commit the"
	echo "tag points at, whose \"$BUILD_JOB\" job ran and passed \"$GATE_STEP\"."
	if [ -z "$verdicts" ]; then
		echo "  Found: no workflow_dispatch runs of $WORKFLOW_FILE on $sha at all."
	else
		echo "  Found these workflow_dispatch runs, none of which qualifies:"
		printf '%s\n' "$verdicts" | while IFS=$'\t' read -r _ id reason url; do
			echo "    run $id: $reason"
			echo "      $url"
		done
	fi
	echo "To fix: make sure main is at $sha, run \`$PREFLIGHT_CMD\`, wait for it to go green,"
	echo "then re-run this tag build (Re-run all jobs). The tag itself does not need to be re-cut:"
	echo "this guard failed before anything was built or published."
} >&2
exit 1
