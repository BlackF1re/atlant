#!/usr/bin/env python3
"""Validate AtlANTian GitHub automation structure and maintenance policy."""

from __future__ import annotations

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
DEPENDABOT = ROOT / ".github" / "dependabot.yml"

EXPECTED_WORKFLOWS = {
    "ci.yml": "CI",
    "build-release.yml": "Build & Release",
    "debian-watch.yml": "Debian Base Watch",
    "dependabot-actions-automerge.yml": "Dependabot Auto-merge",
    "image-download-metrics.yml": "Image Download Metric",
}
EXPECTED_PERMISSIONS = {
    "ci.yml": {"contents": "read"},
    "build-release.yml": {"contents": "read"},
    "debian-watch.yml": {"contents": "write", "actions": "write"},
    "dependabot-actions-automerge.yml": {
        "actions": "write",
        "contents": "write",
        "pull-requests": "read",
    },
    "image-download-metrics.yml": {"contents": "write"},
}


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"automation validation: {message}")


def load_yaml(path: Path) -> dict:
    try:
        with path.open(encoding="utf-8") as stream:
            data = yaml.safe_load(stream)
    except (OSError, yaml.YAMLError) as exc:
        fail(f"cannot parse {path.relative_to(ROOT)}: {exc}")
    if not isinstance(data, dict):
        fail(f"{path.relative_to(ROOT)} must contain a mapping at the top level")
    return data


def workflow_trigger(data: dict) -> object:
    return data.get("on", data.get(True))


def checkout_step(data: dict) -> dict:
    for job in (data.get("jobs") or {}).values():
        for step in job.get("steps") or []:
            if str(step.get("uses", "")).startswith("actions/checkout@"):
                return step
    fail("workflow is missing actions/checkout")


def job_steps(data: dict, job_id: str) -> list[dict]:
    job = (data.get("jobs") or {}).get(job_id) or {}
    steps = job.get("steps") or []
    if not isinstance(steps, list):
        fail(f"job {job_id!r} has invalid steps")
    return steps


def step_named(data: dict, job_id: str, name: str) -> dict:
    for step in job_steps(data, job_id):
        if step.get("name") == name:
            return step
    fail(f"job {job_id!r} is missing step {name!r}")


def require_run(step: dict, needle: str, context: str) -> None:
    if needle not in str(step.get("run", "")):
        fail(f"{context}: missing command fragment {needle!r}")


def validate_workflows() -> None:
    discovered = {
        path.name: path
        for path in sorted(WORKFLOWS.glob("*.yml")) + sorted(WORKFLOWS.glob("*.yaml"))
    }
    if set(discovered) != set(EXPECTED_WORKFLOWS):
        fail(
            "workflow inventory changed; expected "
            f"{sorted(EXPECTED_WORKFLOWS)}, got {sorted(discovered)}"
        )

    parsed: dict[str, dict] = {}
    for filename, expected_name in EXPECTED_WORKFLOWS.items():
        path = discovered[filename]
        data = load_yaml(path)
        parsed[filename] = data
        if data.get("name") != expected_name:
            fail(f"{filename}: workflow name must be {expected_name!r}")
        if workflow_trigger(data) is None:
            fail(f"{filename}: missing trigger configuration")
        if data.get("permissions") != EXPECTED_PERMISSIONS[filename]:
            fail(f"{filename}: workflow permissions differ from the least-privilege policy")
        jobs = data.get("jobs")
        if not isinstance(jobs, dict) or not jobs:
            fail(f"{filename}: must define at least one job")

        for job_id, job in jobs.items():
            if not isinstance(job, dict):
                fail(f"{filename}: job {job_id!r} must be a mapping")
            if not job.get("name"):
                fail(f"{filename}: job {job_id!r} must have a concise display name")
            if not job.get("timeout-minutes"):
                fail(f"{filename}: job {job_id!r} must have a timeout")
            steps = job.get("steps")
            if not isinstance(steps, list) or not steps:
                fail(f"{filename}: job {job_id!r} must define steps")
            for index, step in enumerate(steps, 1):
                if not isinstance(step, dict):
                    fail(f"{filename}: job {job_id!r} step {index} must be a mapping")
                if not step.get("name"):
                    fail(f"{filename}: job {job_id!r} step {index} must have a display name")

    for filename in ("ci.yml", "build-release.yml"):
        checkout = checkout_step(parsed[filename])
        if (checkout.get("with") or {}).get("persist-credentials") is not False:
            fail(f"{filename}: checkout credentials must not persist")

    build = parsed["build-release.yml"]
    publish_job = (build.get("jobs") or {}).get("publish", {})
    publish_permissions = publish_job.get("permissions")
    expected_publish_permissions = {"actions": "read", "contents": "write"}
    if publish_permissions != expected_publish_permissions:
        fail("build-release.yml: publish job permissions differ from publication policy")
    if (publish_job.get("env") or {}).get("ATLANTIAN_GITHUB_REPO") != "${{ github.repository }}":
        fail("build-release.yml: built images must derive the release repository from github.repository")

    dispatch = (workflow_trigger(build) or {}).get("workflow_dispatch") or {}
    publish = (dispatch.get("inputs") or {}).get("publish") or {}
    if publish.get("type") != "boolean" or publish.get("default") is not False:
        fail("build-release.yml: manual publish must be explicit and default to false")

    push_paths = ((workflow_trigger(build) or {}).get("push") or {}).get("paths") or []
    if "scripts/**" not in push_paths or "!scripts/generate-release-notes.sh" not in push_paths:
        fail("build-release.yml: presentation-only release notes must not trigger image builds")

    plan = step_named(build, "plan", "Find reusable verified build")
    plan_run = str(plan.get("run", ""))
    require_run(plan, "scripts/release-batch-state.sh", "release batch policy")
    require_run(plan, "release_input_commits >= 5", "release batch threshold")
    batch_state = (ROOT / "scripts" / "release-batch-state.sh").read_text(encoding="utf-8")
    if "scripts/generate-release-notes.sh" not in batch_state:
        fail("release batch state must exclude presentation-only release notes")

    ordered_release_steps = [
        "Validate source contracts",
        "Validate release inputs",
        "Build root filesystems",
        "Build Linux kernel",
        "Build release artifacts",
        "Validate release artifacts",
        "Validate SD image layout",
        "Validate NAND bundle",
        "Test SD upgrade",
        "Test NAND rebase",
        "Verify source tree integrity",
        "Seal verified artifact",
        "Attest verified build",
        "Upload verified artifact",
    ]
    actual_names = [step.get("name") for step in job_steps(build, "build")]
    positions = []
    for name in ordered_release_steps:
        if name not in actual_names:
            fail(f"build-release.yml: missing build stage {name!r}")
        positions.append(actual_names.index(name))
    if positions != sorted(positions):
        fail("build-release.yml: build stages are out of order")

    rootfs_step = step_named(build, "build", "Build root filesystems")
    kernel_step = step_named(build, "build", "Build Linux kernel")
    artifacts_step = step_named(build, "build", "Build release artifacts")
    require_run(rootfs_step, "bash ./scripts/build-incremental.sh rootfs", "archive-safe rootfs stage")
    require_run(kernel_step, "bash ./scripts/build-incremental.sh kernel", "archive-safe kernel stage")
    require_run(artifacts_step, "bash ./scripts/build-incremental.sh artifacts", "archive-safe artifact stage")
    require_run(step_named(build, "build", "Validate release artifacts"), "test-release-artifacts.sh", "artifact validation")
    require_run(step_named(build, "build", "Test SD upgrade"), "test-release-upgrade.sh", "SD release-upgrade gate")
    require_run(step_named(build, "build", "Test NAND rebase"), "test-nand-rebase.sh", "NAND rebase gate")
    require_run(step_named(build, "build", "Verify source tree integrity"), "git diff --exit-code", "source integrity gate")

    publication = step_named(build, "publish", "Check publication eligibility")
    publication_run = str(publication.get("run", ""))
    require_run(publication, "ALREADY_PUBLISHED", "publication state propagation")
    require_run(publication, "publish=false", "publication no-op result")
    require_run(publication, 'gh api "repos/$GITHUB_REPOSITORY/commits/main"', "authenticated main-tip verification")
    if "git fetch" in publication_run:
        fail("build-release.yml: publication eligibility must not require persisted Git credentials")

    publish_step = step_named(build, "publish", "Publish GitHub release")
    publish_run = str(publish_step.get("run", ""))
    require_run(publish_step, "gh release view", "publication race gate")
    require_run(publish_step, 'gh api "repos/$GITHUB_REPOSITORY/commits/$RELEASE_TAG"', "authenticated publication tag inspection")
    require_run(publish_step, "gh release create", "release publication")
    if "git ls-remote" in publish_run or "git fetch" in publish_run:
        fail("build-release.yml: publication must not require persisted Git credentials")

    build_driver = (ROOT / "scripts" / "build-incremental.sh").read_text(encoding="utf-8")
    if "ATLANTIAN_SKIP_PREFLIGHT" not in build_driver or "artifacts) image ;;" not in build_driver:
        fail("build-incremental.sh must expose the CI preflight skip and artifact-only stage")

    watcher = parsed["debian-watch.yml"]
    schedule = workflow_trigger(watcher).get("schedule") or []
    expected_schedule = {"cron": "17 6 * * *", "timezone": "Asia/Tomsk"}
    if schedule != [expected_schedule]:
        fail(f"debian-watch.yml: expected local schedule {expected_schedule!r}")
    snapshot_step = step_named(watcher, "refresh", "Commit snapshot")
    require_run(snapshot_step, "gh workflow run build-release.yml --ref main -f publish=false", "Debian snapshot validation")
    snapshot_run = str(snapshot_step.get("run", ""))
    require_run(snapshot_step, "git add debian-release.sha256 debian-updates-release.sha256 debian-security-release.sha256", "Debian snapshot commit scope")
    require_run(snapshot_step, "config/debian-snapshot.env", "Debian snapshot commit scope")
    forbidden_release_mutations = (
        "git add config/release.env",
        "config/debian-snapshot.env config/release.env",
        "sed -i",
        "sed -iE",
        "sed -i -E",
    )
    if any(token in snapshot_run for token in forbidden_release_mutations):
        fail("Debian snapshot refresh must not mutate or stage the AtlANTian release version")
    step_named(watcher, "refresh", "Report Debian major availability")

    metrics = parsed["image-download-metrics.yml"]
    metric_schedule = workflow_trigger(metrics).get("schedule") or []
    if metric_schedule != [{"cron": "17 * * * *"}]:
        fail("image download metric must refresh hourly at minute 17")
    release = workflow_trigger(metrics).get("release") or {}
    if release.get("types") != ["published"]:
        fail("image download metric must refresh after release publication")
    metric_step = step_named(metrics, "refresh", "Sum versioned image downloads")
    require_run(metric_step, 'test("^atlantian-[^/]+\\\\.img\\\\.xz$")', "image metric asset filter")
    require_run(metric_step, "gh api --paginate --slurp", "image metric complete release history")
    update_step = step_named(metrics, "refresh", "Update metric file")
    require_run(update_step, "git push origin HEAD:image-download-metrics", "image metric branch isolation")

    automerge = parsed["dependabot-actions-automerge.yml"]
    workflow_run = workflow_trigger(automerge).get("workflow_run") or {}
    if workflow_run.get("workflows") != ["CI"]:
        fail("Dependabot auto-merge must be gated by the CI workflow")
    require_run(
        step_named(automerge, "merge", "Validate and merge Dependabot update"),
        "gh workflow run build-release.yml --ref main -f publish=false",
        "Dependabot post-merge validation",
    )


def validate_dependabot() -> None:
    data = load_yaml(DEPENDABOT)
    updates = data.get("updates") or []
    if len(updates) != 1:
        fail("Dependabot must maintain exactly one ecosystem")
    config = updates[0]
    expected = {
        "package-ecosystem": "github-actions",
        "directory": "/",
        "target-branch": "main",
        "open-pull-requests-limit": 1,
        "rebase-strategy": "auto",
    }
    for key, value in expected.items():
        if config.get(key) != value:
            fail(f"Dependabot {key} must remain {value!r}")
    schedule = config.get("schedule") or {}
    if schedule != {"interval": "daily", "time": "11:17", "timezone": "Asia/Tomsk"}:
        fail("Dependabot schedule must remain daily at 11:17 Asia/Tomsk")
    groups = config.get("groups") or {}
    if (groups.get("github-actions") or {}).get("applies-to") != "version-updates":
        fail("Dependabot version updates must remain grouped")
    if (groups.get("github-actions-security") or {}).get("applies-to") != "security-updates":
        fail("Dependabot security updates must remain grouped")


def main() -> None:
    validate_workflows()
    validate_dependabot()
    print("automation YAML, permissions, API-backed publication, archive portability and Dependabot policy passed")


if __name__ == "__main__":
    main()
