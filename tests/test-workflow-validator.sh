#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/build.yml"
validator="$repo_root/tests/test-workflow.py"
fixture_dir="$(mktemp -d /tmp/airblue-workflow-fixtures.XXXXXX)"
trap 'rm -rf -- "$fixture_dir"' EXIT

python3 - "$workflow" "$fixture_dir/pr-or.yml" "$fixture_dir/latest-smoke.yml" \
  "$fixture_dir/anonymous-validation.yml" "$fixture_dir/validation-write.yml" \
  "$fixture_dir/no-pr-cosign.yml" "$fixture_dir/no-push-cosign.yml" <<'PY'
import copy
import sys

import yaml

(
    source,
    pr_or_path,
    latest_path,
    anonymous_path,
    validation_write_path,
    no_pr_cosign_path,
    no_push_cosign_path,
) = sys.argv[1:]
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

anonymous = copy.deepcopy(workflow)
for step in anonymous["jobs"]["validate"]["steps"]:
    if step.get("uses") == "blue-build/github-action@v1.11":
        step["with"]["registry_username"] = ""
        step["with"]["registry_token"] = ""
        break
with open(anonymous_path, "w", encoding="utf-8") as fixture_file:
    yaml.safe_dump(anonymous, fixture_file, sort_keys=False)

validation_write = copy.deepcopy(workflow)
validation_write["jobs"]["validate"]["permissions"]["packages"] = "write"
with open(validation_write_path, "w", encoding="utf-8") as fixture_file:
    yaml.safe_dump(validation_write, fixture_file, sort_keys=False)

no_pr_cosign = copy.deepcopy(workflow)
no_pr_cosign["on"]["pull_request"]["paths"].remove("cosign.pub")
with open(no_pr_cosign_path, "w", encoding="utf-8") as fixture_file:
    yaml.safe_dump(no_pr_cosign, fixture_file, sort_keys=False)

no_push_cosign = copy.deepcopy(workflow)
no_push_cosign["on"]["push"]["paths"].remove("cosign.pub")
with open(no_push_cosign_path, "w", encoding="utf-8") as fixture_file:
    yaml.safe_dump(no_push_cosign, fixture_file, sort_keys=False)
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
expect_rejected 'anonymous validation pull' "$fixture_dir/anonymous-validation.yml" \
  'validate BlueBuild inputs must exactly use the owner and read-only GitHub token'
expect_rejected 'validation package write permission' "$fixture_dir/validation-write.yml" \
  'validate job must have contents: read and packages: read only'
expect_rejected 'missing pull-request cosign trigger' "$fixture_dir/no-pr-cosign.yml" \
  'pull_request paths are incorrect'
expect_rejected 'missing push cosign trigger' "$fixture_dir/no-push-cosign.yml" \
  'push paths are incorrect'

printf 'workflow validator mutations: PASS\n'
