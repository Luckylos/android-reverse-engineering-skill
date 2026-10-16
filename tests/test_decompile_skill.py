#!/usr/bin/env python3
"""Run: python3 -m unittest discover -s tests -p 'test_decompile_skill.py' -v
Smoke requires Java JDK and jadx. Uses a generated JAR and temporary HOME.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SKILLS = ROOT / "plugins/android-reverse-engineering/skills"
ENTRY = SKILLS / "decompile/SKILL.md"
COMPANION = SKILLS / "android-reverse-engineering"


class PortableEntryTests(unittest.TestCase):
    def text(self):
        self.assertTrue(ENTRY.is_file(), "portable decompile Skill is missing")
        return ENTRY.read_text(encoding="utf-8")

    def test_discoverable_metadata(self):
        text = self.text()
        self.assertTrue(text.startswith("---\n"))
        metadata = text.split("---", 2)[1]
        self.assertRegex(metadata, r"(?m)^name: decompile$")
        self.assertRegex(metadata, r"(?m)^description: Use when .+")
        for suffix in ("APK", "XAPK", "JAR", "AAR"):
            self.assertIn(suffix, metadata)
        self.assertLess(len(metadata.split("description: ", 1)[1].strip()), 1024)

    def test_no_client_or_machine_path_binding(self):
        text = self.text()
        self.assertNotIn("CLAUDE_PLUGIN_ROOT", text)
        self.assertNotIn("$" + "{1", text)
        self.assertNotRegex(text, r"/(?:root|home|Users)/|[A-Z]:\\")
        self.assertNotIn("allowed-tools:", text)
        self.assertLess(len(text.split()), 1000)

    def test_companion_is_explicit_not_an_assumed_layout(self):
        text = self.text()
        self.assertIn("android-reverse-engineering", text)
        self.assertIn("skill registry", text)
        self.assertIn("Do not guess", text)
        self.assertIn("If the companion is missing", text)
        for name in ("check-deps.sh", "decompile.sh"):
            self.assertTrue((COMPANION / "scripts" / name).is_file())
            self.assertIn(name, text)

    def test_installation_requires_approval(self):
        text = self.text()
        self.assertIn("INSTALL_REQUIRED:", text)
        self.assertIn("INSTALL_OPTIONAL:", text)
        self.assertIn("explicit approval", text)
        self.assertIn("Do not install", text)
        fence = chr(96) * 3
        for block in re.findall(fence + r"bash\n(.*?)" + fence, text, re.S):
            self.assertNotIn("install-dep", block)
            self.assertNotIn("sudo", block)

    def test_input_output_and_quoting_contract(self):
        text = self.text()
        for term in ("absolute", "overwrite", "missing", "set the three variables"):
            self.assertIn(term, text)
        self.assertIn('bash "$ANDROID_SKILL_DIR/scripts/check-deps.sh"', text)
        self.assertIn('bash "$ANDROID_SKILL_DIR/scripts/decompile.sh" -o "$output" "$input"', text)

    def test_fernflower_checks_actual_wrapper_requirements(self):
        text = self.text()
        for term in ("FERNFLOWER_JAR_PATH", "CLI alone", "dex2jar", "jadx"):
            self.assertIn(term, text)

    def test_result_and_framework_checks_are_not_exit_code_only(self):
        text = self.text()
        for token in ("fingerprint.sh", "Flutter", "React Native", "Xamarin",
                      "exit code", "zero", "partial", "AndroidManifest.xml",
                      "xapk-manifest.json", "JAR/AAR", "secrets"):
            self.assertIn(token, text)

    def test_install_docs_distinguish_skill_from_slash_alias(self):
        self.text()
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        for term in ("skills/decompile", "/skill:decompile", "does not create"):
            self.assertIn(term, readme)
        self.assertIn("magpie", readme.lower())

    def test_generated_jar_with_spaces_really_decompiles(self):
        self.text()
        for command in ("java", "javac", "jar", "jadx"):
            self.assertIsNotNone(shutil.which(command), f"missing smoke dependency: {command}")
        with tempfile.TemporaryDirectory(prefix="decompile smoke ") as temp:
            work = Path(temp)
            home = work / "home"
            home.mkdir()
            source = work / "WorkflowSmoke.java"
            source.write_text(
                'package example; public final class WorkflowSmoke { '
                'public static String endpoint() { return "https://api.example.test/v1"; } '
                'public static int add(int a, int b) { return a + b; } }\n',
                encoding="utf-8",
            )
            classes = work / "classes"
            classes.mkdir()
            jar = work / "Sample library.jar"
            output = work / "new output"
            env = os.environ.copy()
            env.update(HOME=str(home), XDG_CACHE_HOME=str(home / ".cache"),
                       XDG_CONFIG_HOME=str(home / ".config"),
                       PYTHONDONTWRITEBYTECODE="1")
            for argv in (["javac", "--release", "8", "-d", str(classes), str(source)],
                         ["jar", "--create", "--file", str(jar), "-C", str(classes), "."]):
                result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run(
                ["bash", str(COMPANION / "scripts/decompile.sh"), "-o", str(output), str(jar)],
                cwd=work, env=env, capture_output=True, text=True, timeout=120,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            recovered = list(output.rglob("WorkflowSmoke.java"))
            self.assertTrue(recovered, result.stdout + result.stderr)
            self.assertEqual(len(recovered), 1)
            self.assertIn("https://api.example.test/v1", recovered[0].read_text(encoding="utf-8"))
            # Decompilers may rename parameters; verify behavior, not source spelling.
            roundtrip = work / "roundtrip"
            roundtrip.mkdir()
            runner = work / "SmokeRunner.java"
            runner.write_text(
                'public class SmokeRunner { public static void main(String[] args) { '
                'if (example.WorkflowSmoke.add(7, 5) != 12 || '
                'example.WorkflowSmoke.add(-9, 4) != -5 || '
                '!"https://api.example.test/v1".equals(example.WorkflowSmoke.endpoint())) '
                'throw new AssertionError("roundtrip behavior changed"); '
                'System.out.println("roundtrip OK"); } }\n',
                encoding="utf-8",
            )
            for argv in (["javac", "--release", "8", "-d", str(roundtrip),
                          str(recovered[0]), str(runner)],
                         ["java", "-cp", str(roundtrip), "SmokeRunner"]):
                result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.strip(), "roundtrip OK")


if __name__ == "__main__":
    unittest.main()
