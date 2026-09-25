import ast
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYNC = (ROOT / "containers/sync/sync.sh").read_text()
MIRROR_DOCKERFILE = (ROOT / "containers/mirror/Dockerfile").read_text()
SYNC_DOCKERFILE = (ROOT / "containers/sync/Dockerfile").read_text()
CONFIG = (ROOT / "environments/config.hcl").read_text()
MAKEFILE = (ROOT / "Makefile").read_text()
README = (ROOT / "README.md").read_text()
MANIFEST_UPDATER = (ROOT / "lambdas/manifest_updater/handler.py").read_text()
PATCH_VARIABLES = (ROOT / "modules/patch-manager/variables.tf").read_text()
FROZEN_STORE_MAIN = (ROOT / "modules/frozen-store/main.tf").read_text()
SYNC_ENGINE_MAIN = (ROOT / "modules/sync-engine/main.tf").read_text()
SYNC_ENGINE_VARIABLES = (ROOT / "modules/sync-engine/variables.tf").read_text()
SYNC_ENGINE_ENV = (ROOT / "environments/_env/sync-engine.hcl").read_text()
MIRROR_MAIN = (ROOT / "modules/mirror/main.tf").read_text()
BUCKET_LAYOUT = (ROOT / "docs/diagrams/frozen-repo-bucket-layout.svg").read_text()
ARCHITECTURE = (ROOT / "docs/diagrams/frozen-repo-architecture.svg").read_text()
WORKFLOW = (ROOT / "docs/diagrams/frozen-repo-workflow.svg").read_text()


class SyncSecurityTests(unittest.TestCase):
    def test_digest_only_rpm_is_not_accepted(self):
        self.assertIn('grep -q "digests signatures OK"', SYNC)
        self.assertNotIn('grep -q "digests OK"', SYNC)

    def test_missing_approval_artifact_never_falls_back_to_full_sync(self):
        block = re.search(
            r'Fetching approved package list.*?local approved_count',
            SYNC,
            re.DOTALL,
        )
        self.assertIsNotNone(block)
        self.assertNotIn("full_sync", block.group(0))
        self.assertIn("refusing to sync without an approval artifact", block.group(0))

    def test_full_sync_requires_explicit_baseline_authorization(self):
        self.assertIn('${BASELINE_APPROVED:-}', SYNC)
        self.assertIn('FULL_SYNC requires BASELINE_APPROVED=true', SYNC)

    def test_signature_rejection_blocks_repository_promotion(self):
        self.assertIn("refusing partial promotion", SYNC)
        self.assertIn("refusing partial update", SYNC)

    def test_full_and_selective_failures_propagate(self):
        self.assertIn("full sync is incomplete", SYNC)
        self.assertIn("selective sync is incomplete", SYNC)
        self.assertGreaterEqual(SYNC.count("if ! createrepo_c"), 2)
        self.assertIn("if ! mergerepo_c", SYNC)
        self.assertIn("Staging upload failed", SYNC)
        self.assertIn("Production promotion failed", SYNC)
        self.assertIn("Repodata promotion failed", SYNC)

    def test_full_sync_target_waits_for_successful_ecs_exit(self):
        self.assertIn("aws ecs wait tasks-stopped", MAKEFILE)
        self.assertIn("containers[?name==`sync`].exitCode", MAKEFILE)
        self.assertIn('if [ "$$exit_code" != "0" ]', MAKEFILE)
        seed_block = MAKEFILE.split("seed:", 1)[1].split("## single unit", 1)[0]
        self.assertNotIn("|| true", seed_block)
        self.assertIn("output -raw function_name", seed_block)
        self.assertIn("--query 'FunctionError'", seed_block)
        self.assertIn('if [ "$$function_error" != "None" ]', seed_block)

    def test_manifest_rebuild_requires_success_and_fails_closed(self):
        self.assertIn("_require_successful_sync_event(event)", MANIFEST_UPDATER)
        self.assertIn("Unsupported invocation event", MANIFEST_UPDATER)
        self.assertIn("if exit_code != 0", MANIFEST_UPDATER)
        self.assertIn("if errors:", MANIFEST_UPDATER)
        self.assertIn("Manifest rebuild aborted", MANIFEST_UPDATER)
        self.assertNotIn("manifest[os_ver][repo_id] = {}", MANIFEST_UPDATER)
        self.assertIn("Could not archive the previous manifest", MANIFEST_UPDATER)

    def test_manifest_event_accepts_successful_sync_with_failed_sidecar(self):
        tree = ast.parse(MANIFEST_UPDATER)
        function = next(
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef)
            and node.name == "_require_successful_sync_event"
        )
        module = ast.fix_missing_locations(ast.Module(body=[function], type_ignores=[]))
        namespace = {}
        exec(compile(module, "manifest-event-check", "exec"), namespace)
        validate = namespace["_require_successful_sync_event"]

        event = {
            "source": "aws.ecs",
            "detail-type": "ECS Task State Change",
            "detail": {
                "lastStatus": "STOPPED",
                "stoppedReason": "Essential container in task exited",
                "containers": [
                    {"name": "sync", "exitCode": 0},
                    {
                        "name": "aws-guardduty-agent-test",
                        "exitCode": None,
                        "reason": "CannotPullContainerError",
                    },
                ],
            },
        }
        validate(event)

        event["detail"]["containers"][0]["exitCode"] = 1
        with self.assertRaises(RuntimeError):
            validate(event)

    def test_patch_manager_uses_concrete_almalinux_product(self):
        self.assertIn('patch_product = "AlmaLinux8.10"', CONFIG)
        self.assertIn('product      = "AlmaLinux8.10"', PATCH_VARIABLES)
        self.assertNotIn('patch_product = "*"', CONFIG)
        self.assertNotIn('product      = "*"', PATCH_VARIABLES)

    def test_teardown_controls_are_safe_by_default(self):
        self.assertIn("frozen_store_force_destroy          = false", CONFIG)
        self.assertIn("sync_ecr_force_delete               = false", CONFIG)
        self.assertIn("mirror_ecr_force_delete             = false", CONFIG)
        self.assertIn("mirror_enable_deletion_protection   = true", CONFIG)
        self.assertIn("force_destroy = var.force_destroy", FROZEN_STORE_MAIN)
        self.assertIn("force_delete         = var.ecr_force_delete", SYNC_ENGINE_MAIN)
        self.assertIn("force_delete         = var.ecr_force_delete", MIRROR_MAIN)
        self.assertIn("enable_deletion_protection = var.enable_deletion_protection", MIRROR_MAIN)
        self.assertIn("## Detailed setup", README)
        self.assertIn("## Cleanup and teardown", README)

    def test_guardduty_agent_repository_is_allowed_for_execution_role(self):
        self.assertIn("var.additional_ecr_pull_repository_arns", SYNC_ENGINE_MAIN)
        self.assertIn("additional_ecr_pull_repository_arns", SYNC_ENGINE_VARIABLES)
        self.assertIn(
            "arn:aws:ecr:us-east-1:593207742271:repository/aws-guardduty-agent-fargate",
            SYNC_ENGINE_ENV,
        )

    def test_sigv4_proxy_uses_v112_release_commit(self):
        self.assertIn(
            "0281c3271e65ca05fbb143a2f8ffbde7eda41179",
            MIRROR_DOCKERFILE,
        )
        self.assertIn("v1.12", MIRROR_DOCKERFILE)

    def test_shipped_sample_uses_almalinux_lineage_only(self):
        self.assertIn("    alma810 = {", CONFIG)
        self.assertIn('patch_os      = "ALMA_LINUX"', CONFIG)
        self.assertIn("alma810/", BUCKET_LAYOUT)
        self.assertNotIn("rhel79", CONFIG + SYNC_DOCKERFILE + BUCKET_LAYOUT)
        self.assertNotIn("CentOS-7", SYNC_DOCKERFILE)
        self.assertNotIn("custom_packages79", SYNC_DOCKERFILE)
        self.assertTrue((ROOT / "containers/sync/pkg-lists/custom_packages_alma810.txt").is_file())

    def test_diagrams_are_dnf_only(self):
        visible = "\n".join(
            re.findall(r"<text[^>]*>(.*?)</text>", ARCHITECTURE + WORKFLOW, re.DOTALL)
        ).lower()
        self.assertIn("dnf", visible)
        self.assertNotIn("apt", visible)
        self.assertNotIn("yum", visible)

    def test_diagrams_describe_configurable_schedule_and_baseline(self):
        visible = "\n".join(
            re.findall(r"<text[^>]*>(.*?)</text>", ARCHITECTURE + WORKFLOW, re.DOTALL)
        ).lower()
        self.assertIn("configured schedule", visible)
        self.assertIn("initial baseline", visible)
        self.assertNotIn("guarantees", visible)


if __name__ == "__main__":
    unittest.main()
