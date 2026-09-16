#!/usr/bin/env bash
#
# test-release-tag-guard-live.sh — functional test of scripts/rasputin-release-tag-guard.sh
# against the REAL GitHub Actions API, for a real release tag. Read-only: it
# lists runs and jobs and changes nothing.
#
# WHY
#   The unit tests (test-release-tag-guard.sh) prove the decision logic against
#   fixture responses shaped like the API. This proves the guard's queries work
#   against the API itself — endpoint, filters, pagination, field names — and
#   that its verdict agrees with evidence gathered a DIFFERENT way:
#     1. The set of workflow_dispatch runs the guard considered must equal the
#        set `gh run list --commit` reports for the same commit.
#     2. If release.yml AT THAT COMMIT has no "Snort rules freshness gate" step,
#        no run on that commit can have passed the gate, so the guard MUST fail
#        (exit 1). If the step does exist there, the verdict is printed and
#        cross-checked against each run's jobs as `gh run view` reports them.
#
# NEEDS: gh (authenticated, with read access to the repo's Actions), jq, git,
#   and a clone of this repo with tags fetched (`git fetch --tags`).
#
# Usage:
#   ./scripts/test-release-tag-guard-live.sh [tag]     # default tag: 2026.09.3

set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$SRC/scripts/rasputin-release-tag-guard.sh"
REPO="geekdojo/rasputin-openwrt-firewall"
TAG="${1:-2026.09.3}"
for tool in gh jq git; do
	command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 2; }
done
GATE="$(sed -n 's/^GATE_STEP="\(.*\)"$/\1/p' "$GUARD")"

pass=0
fail=0
ok()  { printf '  ✓ %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  ✗ %s\n' "$*" >&2; fail=$((fail + 1)); }

SHA="$(git -C "$SRC" rev-parse --verify --quiet "refs/tags/$TAG^{commit}")" \
	|| { echo "tag $TAG not found locally — run: git fetch --tags" >&2; exit 2; }
echo "tag $TAG -> commit $SHA"

TMP="$(mktemp -d -t rasputin-tag-guard-live.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "== the guard, against the real API"
rc=0
"$GUARD" "$REPO" "$SHA" > "$TMP/guard.log" 2>&1 || rc=$?
sed 's/^/    | /' "$TMP/guard.log"
if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
	ok "guard answered (exit $rc), no API error"
else
	bad "guard could not answer (exit $rc)"
fi

echo "== cross-check 1: the runs it considered"
guard_ids="$( { grep -oE '^    run [0-9]+:' "$TMP/guard.log" | grep -oE '[0-9]+'; grep -oE 'pre-flight run [0-9]+' "$TMP/guard.log" | grep -oE '[0-9]+'; } | sort -u)"
list_ids="$(gh run list --repo "$REPO" --workflow release.yml --commit "$SHA" --event workflow_dispatch \
	--limit 100 --json databaseId --jq '.[].databaseId' | sort -u)" \
	|| { echo "gh run list failed" >&2; exit 2; }
echo "    guard reported: $(printf '%s' "$guard_ids" | tr '\n' ' ')"
echo "    gh run list:    $(printf '%s' "$list_ids" | tr '\n' ' ')"
if [ "$rc" -eq 0 ]; then
	# On a pass the guard names only the qualifying run; it must be in the list.
	if [ -n "$guard_ids" ] && printf '%s\n' "$list_ids" | grep -qx -- "$guard_ids"; then
		ok "the qualifying run is a workflow_dispatch run on $SHA"
	else
		bad "the qualifying run '$guard_ids' is not in gh run list's dispatch runs on $SHA"
	fi
elif [ "$guard_ids" = "$list_ids" ]; then
	ok "guard considered exactly the dispatch runs gh run list reports"
else
	bad "guard's runs differ from gh run list's"
fi

echo "== cross-check 2: the verdict"
if git -C "$SRC" show "$SHA:.github/workflows/release.yml" | grep -qE "name:[[:space:]]*\"?$GATE\"?[[:space:]]*\$"; then
	echo "    release.yml at $SHA HAS a \"$GATE\" step; checking runs one by one"
	want=1
	while IFS= read -r id; do
		[ -n "$id" ] || continue
		v="$(gh run view "$id" --repo "$REPO" --json conclusion,jobs)" || { echo "gh run view $id failed" >&2; exit 2; }
		if printf '%s' "$v" | jq -e --arg step "$GATE" '
			.conclusion == "success" and
			any(.jobs[]; .name == "build" and .conclusion == "success" and
				any(.steps[]; .name == $step and .conclusion == "success"))' >/dev/null; then
			want=0
		fi
	done <<<"$list_ids"
	if [ "$rc" -eq "$want" ]; then
		ok "guard exit $rc matches gh run view evidence (want $want)"
	else
		bad "guard exit $rc but gh run view evidence says $want"
	fi
else
	echo "    release.yml at $SHA has NO \"$GATE\" step: no run on it can have passed the gate"
	if [ "$rc" -eq 1 ]; then
		ok "guard refuses this commit (exit 1)"
	else
		bad "guard exit $rc for a commit whose workflow has no gate"
	fi
	n_runs="$(printf '%s\n' "$list_ids" | grep -c . || true)"
	n_predates="$(grep -c "run predates the gate" "$TMP/guard.log" || true)"
	if [ "$n_runs" = "$n_predates" ]; then
		ok "each of the $n_runs dispatch run(s) was rejected for lacking the gate"
	else
		bad "$n_runs dispatch run(s) but $n_predates 'run predates the gate' rejection(s)"
	fi
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "tag guard (live, $TAG): $pass check(s) passed"
	exit 0
fi
echo "tag guard (live, $TAG): $fail check(s) FAILED, $pass passed" >&2
exit 1
