import os
import tempfile
import unittest

import check_purity

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def problems_for(files):
    """Check a small tree: `files` maps a path under the root to its text."""
    with tempfile.TemporaryDirectory() as root:
        for path, text in files.items():
            full = os.path.join(root, path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8") as handle:
                handle.write(text)
        return check_purity.check(root)


class PurityTest(unittest.TestCase):
    def test_the_real_tree_is_pure(self):
        self.assertEqual(check_purity.check(ROOT), [])

    def test_a_new_folder_is_checked(self):
        self.assertTrue(problems_for({"src/hashes/a.agc": "def f() -> Void\n  puts(1)\nend\n"}))

    def test_outcome_is_built_only_in_command_agc(self):
        text = "def f() -> Int\n  return Outcome(session: s)\nend\n"
        self.assertTrue(problems_for({"src/commands/strings.agc": text}))
        self.assertEqual(problems_for({"src/commands/command.agc": text}), [])

    def test_missing_src_fails(self):
        self.assertTrue(problems_for({"README.md": "x"}))

    def test_heredoc_cannot_hide_a_call(self):
        text = 'x = <<~EOS\n  say "hi\nEOS\nTime.now_ms()\ny = "a"\n'
        self.assertTrue(problems_for({"src/store/a.agc": text}))

    def test_impure_call_fails(self):
        self.assertTrue(problems_for({"src/store/a.agc": "def f() -> Int\n  return Time.now_ms()\nend\n"}))

    def test_code_in_interpolation_fails(self):
        self.assertTrue(problems_for({"src/store/a.agc": 'def f() -> String\n  return "x#{File.read("a")}"\nend\n'}))

    def test_server_import_fails_in_every_spelling(self):
        for path in ["../server/x", "../../src/server/x", "../server"]:
            with self.subTest(path=path):
                text = 'import X from "%s"\n' % path
                self.assertTrue(problems_for({"src/commands/a.agc": text, "src/server/x.agc": ""}))

    def test_impure_std_module_fails_under_an_alias(self):
        for module in ["std/http", "std/logger", "std/cache"]:
            with self.subTest(module=module):
                self.assertTrue(problems_for({"src/store/a.agc": 'import Z from "%s"\n' % module}))

    def test_the_words_in_a_comment_or_a_string_pass(self):
        text = (
            "# Time and Task and File are only words here\n"
            'import Re from "std/regex"\n'
            'import K from "../resp/k"\n'
            "def f() -> String\n"
            '  return "ERR Time out, Process #{1} Task"  # puts\n'
            "end\n"
        )
        self.assertEqual(problems_for({"src/store/a.agc": text, "src/resp/k.agc": ""}), [])

    def test_agents_md_lists_the_same_names(self):
        with open(os.path.join(ROOT, "AGENTS.md"), encoding="utf-8") as handle:
            text = handle.read()
        for name in check_purity.IMPURE_NAMES:
            self.assertIn("`%s`" % name, text)


if __name__ == "__main__":
    unittest.main()
