"""Checks that the pure core does no I/O (AGENTS.md, "Rules").

Every folder under src/ except src/server is pure. A file there may not
  (a) import src/server, a path outside src/, or a std/ module that is not in
      PURE_STD, and
  (b) use an impure builtin name in code (comments and the text of string
      literals are ignored; the code inside "#{...}" is checked).

Standard library only. Heredoc text is read as code.
"""

import os
import re
import sys

# Keep this list and the one in AGENTS.md the same (a test compares them).
IMPURE_NAMES = [
    "File", "Dir", "Path", "System", "Process", "IO", "TCP", "TLS", "Socket",
    "Listener", "Time", "Random", "Task", "Channel", "ATS", "Profile",
    "LogRegistry", "HTTP", "HttpClient", "HttpServer", "puts", "print",
]
PURE_STD = ["binary", "cookie", "eag", "html", "mime", "option_parser", "regex", "toml", "uri", "utc"]
IMPURE_SUBTREE = "src/server"

NAME_RE = re.compile(r"\b(%s)\b" % "|".join(IMPURE_NAMES))
FROM_RE = re.compile(r'\bfrom\s+"([^"]*)"')


TOKEN_RE = re.compile(r'"(?:\\.|#\{[^}]*\}|[^"\\])*"|#[^\n]*')
INTERPOLATION_RE = re.compile(r"#\{([^}]*)\}")


def blank(token):
    """A string literal keeps only its `#{}` code; a comment keeps nothing."""
    text = token.group(0)
    if text.startswith("#"):
        return ""
    return " ".join(INTERPOLATION_RE.findall(text))


def import_paths(text):
    paths = []
    pending = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if stripped.startswith("import "):
            pending = True
        if pending:
            found = FROM_RE.search(stripped)
            if found:
                paths.append(found.group(1))
                pending = False
    return paths


def import_problem(root, file, path):
    if path.startswith("std/"):
        return None if path[4:] in PURE_STD else "impure std module %r" % path
    target = os.path.normpath(os.path.join(os.path.dirname(file), path))
    relative = os.path.relpath(target, root)
    if relative == IMPURE_SUBTREE or relative.startswith(IMPURE_SUBTREE + os.sep):
        return "imports the I/O shell (%s)" % path
    if not relative.startswith("src" + os.sep) and relative != "src":
        return "imports %r from outside src/" % path
    return None


def pure_files(root):
    src = os.path.join(root, "src")
    for folder, dirs, files in os.walk(src):
        relative = os.path.relpath(folder, root)
        if relative == IMPURE_SUBTREE:
            dirs[:] = []
            continue
        for name in sorted(files):
            if name.endswith(".agc"):
                yield os.path.join(folder, name)


def check(root):
    if not os.path.isdir(os.path.join(root, "src")):
        return ["src/ is missing"]
    problems = []
    for file in pure_files(root):
        with open(file, encoding="utf-8") as handle:
            text = handle.read()
        shown = os.path.relpath(file, root)
        for path in import_paths(text):
            problem = import_problem(root, file, path)
            if problem:
                problems.append("%s: %s" % (shown, problem))
        for number, line in enumerate(TOKEN_RE.sub(blank, text).splitlines(), 1):
            found = NAME_RE.search(line)
            if found:
                problems.append("%s:%d: %s is not allowed in the pure core" % (shown, number, found.group(1)))
    return problems


def main():
    problems = check(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    for problem in problems:
        print("purity: " + problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
