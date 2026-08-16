#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/build.yml"
validator="$repo_root/tests/test-workflow.py"
fixture_dir="$(mktemp -d /tmp/airblue-workflow-fixtures.XXXXXX)"
trap 'rm -rf -- "$fixture_dir"' EXIT

python3 - "$workflow" "$fixture_dir/pr-or.yml" "$fixture_dir/latest-smoke.yml" \
  "$fixture_dir/authenticated-validation.yml" <<'PY'
import copy
import sys

import yaml

source, pr_or_path, latest_path, authenticated_path = sys.argv[1:]
with open(source, encoding="utf-8") as workflow_file:
    workflow = yaml.load(workflow_file, Loader=yaml.BaseLoader)

pr_or = copy.deepcopy(workflow)
condition = pr_or["jobs"]["publish"]["if"]
closing = condition.rfind("}}")
if closing < 0:
    raise SystemExit("publish condition has no closing expression delimiter")
pr_or["jobs"]["publish"]["if"] = (
    condition[:closing] + " || github.event_name == 'pull_request' " + condition[closing:]
)
with open(pr_or_path, "w", encoding="utf-8") as fixture_file:
    yaml.safe_dump(pr_or, fixture_file, sort_keys=False)

latest = copy.deepcopy(workflow)
for step in latest["jobs"]["validate"]["steps"]:
    if "tests/test-image.sh" in step.get("run", ""):
        step["run"] = step["run"].replace(
            '"$image_ref" -s < tests/test-image.sh',
            'ghcr.io/example/airblue:latest -s < tests/test-image.sh',
        )
        break
with open(latest_path, "w", encoding="utf-8") as fixture_file:
    yaml.safe_dump(latest, fixture_file, sort_keys=False)

authenticated = copy.deepcopy(workflow)
for step in authenticated["jobs"]["validate"]["steps"]:
    if step.get("uses") == "blue-build/github-action@v1.11":
        step["with"]["registry_username"] = "unexpected-user"
        break
with open(authenticated_path, "w", encoding="utf-8") as fixture_file:
    yaml.safe_dump(authenticated, fixture_file, sort_keys=False)
PY

expect_rejected() {
  local name="$1" fixture="$2" expected="$3" output

  if output="$(python3 "$validator" "$fixture" 2>&1)"; then
    printf 'FAIL: workflow validator accepted %s mutation\n' "$name" >&2
    exit 1
  fi
  grep -Fq -- "$expected" <<< "$output" || {
    printf 'FAIL: %s mutation failed for the wrong reason\n%s\n' "$name" "$output" >&2
    exit 1
  }
}

python3 "$validator" "$workflow"
expect_rejected 'PR-OR publish condition' "$fixture_dir/pr-or.yml" \
  'publish condition allows pull_request'
expect_rejected 'latest smoke target' "$fixture_dir/latest-smoke.yml" \
  'smoke must execute the exact local image reference'
expect_rejected 'authenticated validation pull' "$fixture_dir/authenticated-validation.yml" \
  'validate BlueBuild inputs must exactly use empty registry username/token and signing key'

printf 'workflow validator mutations: PASS\n'
