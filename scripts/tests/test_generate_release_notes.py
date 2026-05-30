import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "generate-release-notes.py"


class GenerateReleaseNotesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp_dir.name)
        self.run_git("init")
        self.run_git("config", "user.name", "Release Bot")
        self.run_git("config", "user.email", "release@example.com")

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def run_git(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["git", *args], cwd=self.repo, text=True, check=True, capture_output=True)

    def commit(self, subject: str, body: str | None = None) -> None:
        args = ["commit", "--allow-empty", "-m", subject]
        if body is not None:
            args.extend(["-m", body])
        self.run_git(*args)

    def tag(self, name: str) -> None:
        self.run_git("tag", name)

    def run_generator(self, tag: str = "v1.0.1") -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--tag",
                tag,
                "--repo",
                str(self.repo),
                "--markdown-out",
                str(self.repo / "release_notes.md"),
                "--sparkle-html-out",
                str(self.repo / "release_notes.html"),
            ],
            cwd=self.repo,
            text=True,
            capture_output=True,
        )

    def read_outputs(self) -> tuple[str, str]:
        return (
            (self.repo / "release_notes.md").read_text(encoding="utf-8"),
            (self.repo / "release_notes.html").read_text(encoding="utf-8"),
        )

    def seed_release_history(self) -> None:
        self.commit("feat: previous release baseline", "不应该出现在当前版本")
        self.tag("v1.0.0")
        self.commit(
            "feat(settings): 新增设置能力",
            "详细变更：\n"
            "1. 新增Git语言统计范围的偏好设置\n"
            "2. 支持 <settings> & 特殊字符展示",
        )
        self.commit("fix: 修复启动崩溃")
        self.commit("perf: 优化统计刷新", "- 减少重复扫描\n- 降低菜单栏刷新开销")
        self.commit("build(ci): 优化构建流程", "1. 缓存构建工具\n2. 精简发布脚本")
        self.commit("chore(release): v1.0.1 [skip ci]")
        self.tag("v1.0.1")

    def test_uses_commit_body_groups_by_type_and_filters_release_bump(self) -> None:
        self.seed_release_history()

        result = self.run_generator()

        self.assertEqual(result.returncode, 0, result.stderr)
        markdown, html = self.read_outputs()
        self.assertIn("## 更新内容", markdown)
        self.assertIn("### 新功能", markdown)
        self.assertIn("- 新增Git语言统计范围的偏好设置", markdown)
        self.assertIn("### 修复", markdown)
        self.assertIn("- 修复启动崩溃", markdown)
        self.assertIn("### 性能", markdown)
        self.assertIn("- 减少重复扫描", markdown)
        self.assertIn("### 工程与发布", markdown)
        self.assertIn("- 缓存构建工具", markdown)
        self.assertNotIn("chore(release)", markdown)
        self.assertNotIn("previous release baseline", markdown)
        self.assertIn("支持 &lt;settings&gt; &amp; 特殊字符展示", html)

    def test_markdown_override_only_replaces_sparkle_html(self) -> None:
        self.seed_release_history()
        override_dir = self.repo / "release-notes" / "sparkle"
        override_dir.mkdir(parents=True)
        (override_dir / "v1.0.1.md").write_text(
            "# 重点更新\n\n"
            "这次弹窗只讲用户最关心的内容。\n\n"
            "- 新增更完整的统计范围设置\n"
            "1. 优化更新说明展示\n",
            encoding="utf-8",
        )

        result = self.run_generator()

        self.assertEqual(result.returncode, 0, result.stderr)
        markdown, html = self.read_outputs()
        self.assertIn("- 新增Git语言统计范围的偏好设置", markdown)
        self.assertIn("<h1>重点更新</h1>", html)
        self.assertIn("<p>这次弹窗只讲用户最关心的内容。</p>", html)
        self.assertIn("<li>新增更完整的统计范围设置</li>", html)
        self.assertIn("<li>优化更新说明展示</li>", html)
        self.assertNotIn("新增Git语言统计范围的偏好设置", html)

    def test_html_override_takes_priority_over_markdown_override(self) -> None:
        self.seed_release_history()
        override_dir = self.repo / "release-notes" / "sparkle"
        override_dir.mkdir(parents=True)
        (override_dir / "v1.0.1.md").write_text("# Markdown 覆盖\n", encoding="utf-8")
        (override_dir / "v1.0.1.html").write_text("<h2>HTML 覆盖</h2>\n<ul><li>优先使用 HTML</li></ul>", encoding="utf-8")

        result = self.run_generator()

        self.assertEqual(result.returncode, 0, result.stderr)
        _, html = self.read_outputs()
        self.assertIn("<h2>HTML 覆盖</h2>", html)
        self.assertIn("<li>优先使用 HTML</li>", html)
        self.assertNotIn("Markdown 覆盖", html)

    def test_override_containing_cdata_terminator_fails(self) -> None:
        self.seed_release_history()
        override_dir = self.repo / "release-notes" / "sparkle"
        override_dir.mkdir(parents=True)
        (override_dir / "v1.0.1.html").write_text("<p>bad ]]></p>", encoding="utf-8")

        result = self.run_generator()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("would break appcast CDATA", result.stderr)


if __name__ == "__main__":
    unittest.main()
