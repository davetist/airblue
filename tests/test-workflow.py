#!/usr/bin/env python3
"""Semantic contract for Airblue's GitHub Actions image pipeline."""

from __future__ import annotations

import ast
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    print("FAIL: PyYAML is required to validate the workflow", file=sys.stderr)
    raise SystemExit(1)


ROOT = Path(__file__).resolve().parent.parent
if len(sys.argv) > 2:
    print(f"usage: {Path(sys.argv[0]).name} [workflow.yml]", file=sys.stderr)
    raise SystemExit(2)
WORKFLOW_PATH = (
    Path(sys.argv[1]).resolve()
    if len(sys.argv) == 2
    else ROOT / ".github" / "workflows" / "build.yml"
)
PUBLIC_KEY_PATH = ROOT / "cosign.pub"
GITIGNORE_PATH = ROOT / ".gitignore"
ACTION = "blue-build/github-action@v1.11"
EXPECTED_VALIDATE_INPUTS = {
    "recipe": "recipe.yml",
    "cosign_private_key": "",
    "registry_username": "${{ github.repository_owner }}",
    "registry_token": "${{ github.token }}",
    "registry_namespace": "${{ github.repository_owner }}",
    "pr_event_number": "${{ github.event.number }}",
    "maximize_build_space": "true",
    "build_opts": "--build-driver podman",
    "push": "false",
    "skip_checkout": "true",
}
EXPECTED_PUBLISH_INPUTS = {
    "recipe": "recipe.yml",
    "cosign_private_key": "${{ secrets.SIGNING_SECRET }}",
    "registry_token": "${{ github.token }}",
    "registry_namespace": "${{ github.repository_owner }}",
    "pr_event_number": "${{ github.event.number }}",
    "maximize_build_space": "true",
    "push": "true",
}
EXPECTED_PUBLISH_CONDITION = " ".join(
    """${{ needs.validate.result == 'success' &&
    github.event_name != 'pull_request' &&
    (github.event_name == 'workflow_dispatch' ||
    github.event_name == 'schedule' ||
    (github.event_name == 'push' &&
    github.ref == format('refs/heads/{0}', github.event.repository.default_branch))) }}""".split()
)
EXPECTED_PATHS = [
    ".github/workflows/build.yml",
    "recipes/**",
    "scripts/**",
    "files/**",
    "tests/**",
]

failures: list[str] = []


def require(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def strings(value: Any) -> list[str]:
    if isinstance(value, dict):
        return [item for child in value.values() for item in strings(child)]
    if isinstance(value, list):
        return [item for child in value for item in strings(child)]
    return [value] if isinstance(value, str) else []


def action_steps(job: dict[str, Any]) -> list[dict[str, Any]]:
    return [step for step in job.get("steps", []) if step.get("uses") == ACTION]


def evaluate_publish_condition(
    condition: str,
    *,
    event_name: str,
    ref: str,
    default_branch: str,
    validate_result: str = "success",
) -> bool:
    """Evaluate the small, deliberately constrained expression used by this workflow."""

    expression = condition.replace("${{", "").replace("}}", "").strip()
    expression = expression.replace(
        "format('refs/heads/{0}', github.event.repository.default_branch)",
        repr(f"refs/heads/{default_branch}"),
    )
    substitutions = {
        "needs.validate.result": validate_result,
        "github.event_name": event_name,
        "github.ref": ref,
    }
    for variable, value in substitutions.items():
        expression = expression.replace(variable, repr(value))
    expression = expression.replace("&&", " and ").replace("||", " or ")

    tree = ast.parse(expression, mode="eval")
    allowed_nodes = (
        ast.Expression,
        ast.BoolOp,
        ast.And,
        ast.Or,
        ast.Compare,
        ast.Eq,
        ast.NotEq,
        ast.Constant,
    )
    if any(not isinstance(node, allowed_nodes) for node in ast.walk(tree)):
        raise ValueError("publish condition contains unsupported syntax")
    return bool(eval(compile(tree, "<publish-condition>", "eval"), {"__builtins__": {}}, {}))


if not WORKFLOW_PATH.is_file():
    failures.append(f"workflow is missing: {WORKFLOW_PATH}")
    workflow: dict[str, Any] = {}
else:
    try:
        workflow = yaml.load(WORKFLOW_PATH.read_text(), Loader=yaml.BaseLoader)
    except yaml.YAMLError as error:
        failures.append(f"workflow YAML is malformed: {error}")
        workflow = {}

events = workflow.get("on", {})
require(
    set(events) == {"workflow_dispatch", "pull_request", "push", "schedule"},
    "workflow triggers must be manual, pull request, push, and schedule only",
)
require(events.get("schedule") == [{"cron": "0 6 * * 0"}], "weekly cron is not 0 6 * * 0")
for event in ("pull_request", "push"):
    require(events.get(event, {}).get("paths") == EXPECTED_PATHS, f"{event} paths are incorrect")

jobs = workflow.get("jobs", {})
require(set(jobs) == {"validate", "publish"}, "workflow must contain separate validate and publish jobs")

validate = jobs.get("validate", {})
require(
    validate.get("permissions") == {"contents": "read", "packages": "read"},
    "validate job must have contents: read and packages: read only",
)
require("needs" not in validate, "validate job must not depend on the privileged publish job")
validate_actions = action_steps(validate)
require(len(validate_actions) == 1, "validate job must invoke BlueBuild v1.11 exactly once")
if validate_actions:
    validate_inputs = validate_actions[0].get("with", {})
    require(
        validate_inputs == EXPECTED_VALIDATE_INPUTS,
        "validate BlueBuild inputs must exactly use the owner and read-only GitHub token, empty signing key, push false, and the Podman driver",
    )

validate_strings = strings(validate)
require(not any("secrets." in value for value in validate_strings), "validate job must not reference secrets")
require(
    [value for value in validate_strings if "github.token" in value] == ["${{ github.token }}"],
    "validate job may use github.token only as the registry token",
)

validate_steps = validate.get("steps", [])
source_index = next(
    (index for index, step in enumerate(validate_steps) if "tests/test-recipe.sh" in step.get("run", "")),
    -1,
)
build_index = next((index for index, step in enumerate(validate_steps) if step.get("uses") == ACTION), -1)
smoke_index = next(
    (index for index, step in enumerate(validate_steps) if "tests/test-image.sh" in step.get("run", "")),
    -1,
)
require(source_index >= 0 and source_index < build_index, "source contract must run before the validate build")
require(build_index >= 0 and smoke_index > build_index, "exact-local smoke must run after the validate build")
if smoke_index >= 0:
    smoke = validate_steps[smoke_index]
    smoke_run = smoke.get("run", "")
    smoke_env = smoke.get("env", {})
    smoke_lines = [
        line.strip()
        for line in smoke_run.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    expected_image_assignment = 'image_ref="${IMAGE_REGISTRY,,}/airblue:${GITHUB_SHA::7}-44"'
    expected_smoke_command = (
        'podman run --pull=never --rm --interactive --entrypoint /usr/bin/bash '
        '"$image_ref" -s < tests/test-image.sh'
    )
    require(
        smoke_env.get("IMAGE_REGISTRY") == "ghcr.io/${{ github.repository_owner }}",
        "smoke registry must derive from github.repository_owner",
    )
    require(
        smoke_lines.count(expected_image_assignment) == 1,
        "smoke must select the current SHA Fedora 44 tag",
    )
    require(
        smoke_lines.count('podman image exists "$image_ref"') == 1,
        "smoke must require the local image",
    )
    podman_run_lines = [line for line in smoke_lines if line.startswith("podman run ")]
    require(
        podman_run_lines == [expected_smoke_command],
        "smoke must execute the exact local image reference",
    )
    require("latest" not in smoke_run.lower(), "smoke must not use a latest tag")
    require(
        not any(
            command in smoke_run.lower()
            for command in ("podman pull", "docker pull", "skopeo copy", "--pull=always")
        ),
        "smoke must not pull an image from a registry",
    )

publish = jobs.get("publish", {})
require(publish.get("needs") == "validate", "publish job must depend on validate")
require(
    publish.get("permissions") == {"contents": "read", "packages": "write"},
    "publish job permissions must be contents: read and packages: write only",
)
publish_if = " ".join(publish.get("if", "").split())
require(
    publish_if == EXPECTED_PUBLISH_CONDITION,
    "publish condition must exactly match the authorized event gate",
)
publish_truth_table = (
    ("pull_request", "refs/pull/1/merge", "success", False, "pull_request"),
    ("pull_request", "refs/heads/main", "success", False, "pull_request on default ref"),
    ("push", "refs/heads/feature", "success", False, "non-default push"),
    ("push", "refs/heads/main", "success", True, "default-branch push"),
    ("schedule", "refs/heads/main", "success", True, "schedule"),
    ("workflow_dispatch", "refs/heads/feature", "success", True, "workflow_dispatch"),
    ("issues", "refs/heads/main", "success", False, "other event"),
    ("push", "refs/heads/main", "failure", False, "failed validation"),
)
try:
    for event_name, ref, result, expected, label in publish_truth_table:
        actual = evaluate_publish_condition(
            publish_if,
            event_name=event_name,
            ref=ref,
            default_branch="main",
            validate_result=result,
        )
        if label.startswith("pull_request") and actual:
            failures.append("publish condition allows pull_request")
        elif actual != expected:
            failures.append(f"publish condition truth table mismatch for {label}")
except (SyntaxError, ValueError) as error:
    failures.append(f"publish condition cannot be safely evaluated: {error}")

publish_actions = action_steps(publish)
require(len(publish_actions) == 1, "publish job must invoke BlueBuild v1.11 exactly once")
if publish_actions:
    publish_inputs = publish_actions[0].get("with", {})
    require(
        publish_inputs == EXPECTED_PUBLISH_INPUTS,
        "publish BlueBuild inputs must exactly use signing secret, GitHub token, push true, and standard driver",
    )

workflow_text = WORKFLOW_PATH.read_text() if WORKFLOW_PATH.is_file() else ""
for forbidden in ("podman manifest push", "cosign sign", "cosign login", "skopeo inspect"):
    require(forbidden not in workflow_text, f"workflow must not implement custom publication: {forbidden}")
require("id-token: write" not in workflow_text, "workflow must not grant unused id-token permission")

if PUBLIC_KEY_PATH.is_file():
    public_key = PUBLIC_KEY_PATH.read_text().strip()
    require(
        public_key.startswith("-----BEGIN PUBLIC KEY-----")
        and public_key.endswith("-----END PUBLIC KEY-----"),
        "cosign.pub is not a PEM public key",
    )
else:
    failures.append("repository-root cosign.pub is missing")

if GITIGNORE_PATH.is_file():
    ignored = {line.strip() for line in GITIGNORE_PATH.read_text().splitlines()}
    require("cosign.key" in ignored, ".gitignore must ignore cosign.key")
else:
    failures.append("repository-root .gitignore is missing")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)

print("workflow contract: PASS")
