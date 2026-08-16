import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "build-sing-box.yml"


class BuildWorkflowTests(unittest.TestCase):
  def test_actions_are_pinned_and_go_version_comes_from_upstream(self):
    workflow = WORKFLOW.read_text(encoding="utf-8")

    self.assertIn("actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09", workflow)
    self.assertIn("actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16", workflow)
    self.assertNotIn("actions/checkout@v5", workflow)
    self.assertNotIn("actions/setup-go@v6", workflow)
    self.assertIn("go-version-file: sing-box-src/go.mod", workflow)

  def test_build_tags_match_features_that_are_actually_packaged(self):
    workflow = WORKFLOW.read_text(encoding="utf-8")

    self.assertIn('select(. != "with_naive_outbound")', workflow)
    self.assertNotIn('final_tags="${final_tags},with_v2ray_api,with_purego"', workflow)
    for required_tag in ("with_v2ray_api", "with_wireguard", "with_acme"):
      self.assertIn(f"grep {required_tag}", workflow)

  def test_release_contains_corresponding_source_and_keeps_history(self):
    workflow = WORKFLOW.read_text(encoding="utf-8")

    self.assertIn("sing-box-source-", workflow)
    self.assertIn("sing-box-LICENSE", workflow)
    self.assertIn("BUILD_INFO.json", workflow)
    self.assertNotIn("Delete old releases", workflow)
    self.assertNotIn("grep -v \"^${new_tag}$\"", workflow)

  def test_incomplete_existing_release_is_repaired(self):
    workflow = WORKFLOW.read_text(encoding="utf-8")

    for required_asset in (
      "sing-box-linux-amd64",
      "sing-box-linux-arm64",
      "sing-box-source-${version}.tar.gz",
      "sing-box-LICENSE",
      "BUILD_INFO.json",
      "sha256sum.txt",
    ):
      self.assertIn(required_asset, workflow)
    self.assertIn("missing_assets", workflow)
    self.assertIn('gh release upload "$tag" release-files/*', workflow)
    self.assertIn("--clobber", workflow)
    self.assertIn('gh release edit "$tag"', workflow)


if __name__ == "__main__":
  unittest.main()