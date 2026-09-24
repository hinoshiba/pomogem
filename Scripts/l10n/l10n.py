#!/usr/bin/env python3
"""PomoGem localization tooling (see Docs/Localization.md).

Commands
  status                     Summarize every String Catalog.
  sync --derived-data DIR    Merge the compiler's .stringsdata into all feature catalogs.
  check [--strict] [--derived-data DIR] [--tables T,...]
                             Lint catalogs, code and UI tests. Without --strict the
                             check is a report: it fails only on problems that are
                             wrong today and passes while literals are still being
                             converted. --strict (the English integration turns it
                             on) enforces everything.
  report [--package ID | --table T | --file PATH]
                             List Japanese literals that are not localized yet.
  set --table T --from FILE [--language en] [--state translated]
                             Bulk-write translations from a .json or .tsv file.
  carry --table T --from OLD --to NEW [--language en]
                             Move a translation to an edited Japanese key and mark it
                             needs_review.
  format [--check]           Rewrite catalogs in Xcode's exact JSON layout.
  verify-bundle APP          Assert the built app and both extensions carry exactly the
                             shipping localizations.

Keys are the Japanese source text. A missing translation falls back to that key,
so Japanese output never depends on these catalogs.
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import plistlib
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from swiftlex import lex  # noqa: E402

DEFAULT_ROOT = Path(__file__).resolve().parents[2]
CONFIG_RELATIVE = Path("Scripts/l10n/table-map.json")
GLOSSARY_RELATIVE = Path("Scripts/l10n/glossary.json")
UI_TEST_DIRECTORY = "PomoGemUITests"
UI_TEST_LANGUAGE_HELPER = "PomoGemUITests/PomoGemUITestLanguage.swift"

# Kana, kanji, CJK punctuation and full-width forms. Used both to find
# Japanese literals in code and to reject Japanese left inside a translation.
JAPANESE = re.compile(r"[\u3000-\u303f\u3040-\u309f\u30a0-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uff00-\uffef]")
FORMAT_SPECIFIER = re.compile(
    r"%(?:(?P<position>\d+)\$)?(?P<flags>[-+ #0']*)(?P<width>\d+|\*)?(?:\.(?P<precision>\d+|\*))?"
    r"(?P<length>hh|h|ll|l|q|L|z|t|j)?(?P<conversion>[@dDiuUxXoOfFeEgGcCsSpaA%])"
    r"|%#@(?P<substitution>[A-Za-z0-9_]+)@"
)
MARKDOWN = re.compile(r"\*\*|__|`|\[[^\]]+\]\([^)]+\)|(?<![\w*])\*[^*\s][^*]*\*(?!\w)|(?<![\w_])_[^_\s][^_]*_(?!\w)")
IGNORE_LINE = re.compile(r"//\s*l10n-ignore:\s*\S")
IGNORE_BEGIN = re.compile(r"//\s*l10n-ignore-begin:\s*\S")
IGNORE_END = re.compile(r"//\s*l10n-ignore-end\b")
LOCALIZABLE_INFO_KEYS = re.compile(r"^(CFBundleDisplayName|CFBundleName|NS\w+UsageDescription)$")

DIAGNOSTIC_CALLEES = {
    "print", "debugPrint", "dump", "fatalError", "assertionFailure", "assert", "precondition",
    "preconditionFailure", "NSLog", "os_log",
}
LOG_METHODS = {"debug", "info", "notice", "error", "fault", "warning", "trace", "critical", "log"}
LOGIC_CALLEES = {
    "contains", "hasPrefix", "hasSuffix", "replacingOccurrences", "firstIndex", "lastIndex",
    "components", "range", "split", "starts", "trimmingCharacters",
}
TABLE_LABEL_BY_CALLEE = {
    "Text": "tableName",
    "LocalizedStringResource": "table",
    "LocalizedStringKey": None,
}


# --------------------------------------------------------------------------
# Repository and configuration


def glob_to_regex(pattern):
    out = []
    index = 0
    while index < len(pattern):
        if pattern.startswith("**", index):
            out.append(".*")
            index += 2
        elif pattern[index] == "*":
            out.append("[^/]*")
            index += 1
        elif pattern[index] == "?":
            out.append("[^/]")
            index += 1
        else:
            out.append(re.escape(pattern[index]))
            index += 1
    return re.compile("^" + "".join(out) + "$")


class Repo:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.config = json.loads((self.root / CONFIG_RELATIVE).read_text(encoding="utf-8"))
        glossary_path = self.root / GLOSSARY_RELATIVE
        self.glossary = json.loads(glossary_path.read_text(encoding="utf-8")) if glossary_path.exists() else {}
        self.source_language = self.config["source_language"]
        self.shipping_languages = list(self.config["shipping_languages"])
        self.catalogs = dict(self.config["catalogs"])
        self.rules = [(glob_to_regex(rule["glob"]), rule) for rule in self.config["rules"]]
        self.info_plist_catalogs = list(self.config.get("info_plist_catalogs", []))

    def path(self, relative):
        return self.root / relative

    def relative(self, path):
        return Path(os.path.realpath(path)).relative_to(os.path.realpath(self.root)).as_posix()

    def rule_for(self, relative_path):
        for regex, rule in self.rules:
            if regex.match(relative_path):
                return rule
        return None

    def table_for(self, relative_path):
        rule = self.rule_for(relative_path)
        return rule["table"] if rule else "UNASSIGNED"

    def swift_sources(self):
        files = []
        for top in self.config["source_roots"]:
            base = self.root / top
            if not base.exists():
                continue
            for directory, _, names in os.walk(base):
                for name in names:
                    if name.endswith(".swift"):
                        files.append(Path(directory, name).relative_to(self.root).as_posix())
        return sorted(files)

    def target_languages(self):
        return [language for language in self.shipping_languages if language != self.source_language]


# --------------------------------------------------------------------------
# String Catalog I/O in Xcode's exact layout


def _catalog_sort_key(key):
    return unicodedata.normalize("NFC", key)


def dump_catalog_value(value, indent=0):
    """Serialize like xcstringstool: sorted keys, ' : ', 2 spaces, `{\\n\\n}` for empty objects."""
    pad = " " * indent
    inner = " " * (indent + 2)
    if isinstance(value, dict):
        if not value:
            return "{\n\n" + pad + "}"
        items = []
        for key in sorted(value, key=_catalog_sort_key):
            items.append(inner + json.dumps(key, ensure_ascii=False) + " : " + dump_catalog_value(value[key], indent + 2))
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(value, list):
        if not value:
            return "[\n\n" + pad + "]"
        return "[\n" + ",\n".join(inner + dump_catalog_value(item, indent + 2) for item in value) + "\n" + pad + "]"
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, (int, float)):
        return json.dumps(value)
    return json.dumps(value, ensure_ascii=False)


def dump_catalog(document):
    # xcstringstool writes no trailing newline; matching it keeps Xcode from rewriting files.
    return dump_catalog_value(document)


def load_catalog(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write_catalog(path, document):
    Path(path).write_text(dump_catalog(document), encoding="utf-8")


def empty_catalog(source_language="ja"):
    return {"sourceLanguage": source_language, "strings": {}, "version": "1.0"}


def string_units(localization):
    """Yield (label, stringUnit) for every leaf of one language's localization."""
    unit = localization.get("stringUnit")
    if unit is not None:
        yield "value", unit
    for kind, forms in (localization.get("variations") or {}).items():
        for form, nested in forms.items():
            for label, leaf in string_units(nested):
                yield f"{kind}.{form}" + ("" if label == "value" else "." + label), leaf


def source_text(key, entry, source_language):
    unit = ((entry.get("localizations") or {}).get(source_language) or {}).get("stringUnit")
    if unit and "value" in unit:
        return unit["value"]
    return key


def specifiers(text, substitutions=None):
    """Map argument index -> conversion, plus the number of %% escapes."""
    arguments = {}
    percent_escapes = 0
    implicit = 0
    for match in FORMAT_SPECIFIER.finditer(text):
        if match.group("substitution"):
            substitution = (substitutions or {}).get(match.group("substitution"))
            if substitution is None:
                arguments[("missing-substitution", match.group("substitution"))] = "?"
                continue
            arguments[int(substitution.get("argNum", 0))] = substitution.get("formatSpecifier", "?")
            continue
        if match.group("conversion") == "%":
            percent_escapes += 1
            continue
        if match.group("position"):
            index = int(match.group("position"))
        else:
            implicit += 1
            index = implicit
        arguments[index] = (match.group("length") or "") + match.group("conversion")
    return arguments, percent_escapes


# --------------------------------------------------------------------------
# Findings


class Findings:
    def __init__(self, strict):
        self.strict = strict
        self.errors = []
        self.warnings = collections.OrderedDict()

    def error(self, category, message):
        self.errors.append((category, message))

    def enforce(self, category, message, enforced=False):
        """An error once enforced (strict mode or an activated table); a warning before."""
        if self.strict or enforced:
            self.error(category, message)
        else:
            self.warn(category, message)

    def warn(self, category, message):
        self.warnings.setdefault(category, []).append(message)


# --------------------------------------------------------------------------
# Swift source analysis


def ignored_lines(source):
    """Line numbers exempted by `// l10n-ignore: reason` (same or previous line) or a begin/end block."""
    lines = source.split("\n")
    ignored = set()
    in_block = False
    for number, line in enumerate(lines, start=1):
        if IGNORE_BEGIN.search(line):
            in_block = True
        if in_block:
            ignored.add(number)
        if IGNORE_END.search(line):
            in_block = False
        if IGNORE_LINE.search(line):
            ignored.add(number)
            stripped = line.strip()
            if stripped.startswith("//"):
                ignored.add(number + 1)
    return ignored


def excluded_ranges(masked):
    """#Preview / PreviewProvider bodies and `#if DEBUG` regions never ship."""
    ranges = []
    for match in re.finditer(r"#Preview\b[^{]*\{|struct\s+\w+\s*:\s*PreviewProvider\s*\{", masked):
        depth = 0
        index = match.end() - 1
        while index < len(masked):
            if masked[index] == "{":
                depth += 1
            elif masked[index] == "}":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        ranges.append((match.start(), index))
    stack = []
    position = 0
    for line in masked.split("\n"):
        stripped = line.strip()
        if stripped.startswith("#if"):
            condition = stripped
            stack.append([condition, position, "DEBUG" in condition and "!DEBUG" not in condition])
        elif stripped.startswith("#elseif") or stripped.startswith("#else"):
            if stack:
                condition, start, is_debug = stack[-1]
                if is_debug:
                    ranges.append((start, position))
                stack[-1] = [stripped, position, ("!DEBUG" in condition) and not is_debug]
        elif stripped.startswith("#endif"):
            if stack:
                condition, start, is_debug = stack.pop()
                if is_debug:
                    ranges.append((start, position))
        position += len(line) + 1
    return ranges


class SwiftFile:
    """Bracket structure of one masked Swift file, for questions about the call around a literal."""

    OPENERS = {"(": ")", "[": "]", "{": "}"}
    CLOSERS = {")": "(", "]": "[", "}": "{"}

    def __init__(self, relative_path, source):
        self.path = relative_path
        self.source = source
        self.literals, self.masked = lex(source)
        self.line_starts = [0]
        for index, character in enumerate(source):
            if character == "\n":
                self.line_starts.append(index + 1)
        self.match = {}
        self.parent_of_literal = {}
        starts = sorted(literal["start"] for literal in self.literals)
        stack = []
        cursor = 0
        masked = self.masked
        for index, character in enumerate(masked):
            while cursor < len(starts) and starts[cursor] == index:
                self.parent_of_literal[index] = stack[-1] if stack else None
                cursor += 1
            if character in self.OPENERS:
                stack.append(index)
            elif character in self.CLOSERS:
                wanted = self.CLOSERS[character]
                while stack and masked[stack[-1]] != wanted:
                    stack.pop()
                if stack:
                    self.match[stack.pop()] = index
        while cursor < len(starts):
            self.parent_of_literal[starts[cursor]] = stack[-1] if stack else None
            cursor += 1

    def line_of(self, offset):
        low, high = 0, len(self.line_starts) - 1
        while low < high:
            middle = (low + high + 1) // 2
            if self.line_starts[middle] <= offset:
                low = middle
            else:
                high = middle - 1
        return low + 1

    def callee(self, opener):
        if opener is None or self.masked[opener] != "(":
            return "", ""
        before = self.masked[max(0, opener - 160):opener]
        match = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^<>()]*>)?\s*$", before)
        if not match:
            return "", ""
        name = match.group(1)
        receiver = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*" + re.escape(name) + r"\s*(?:<[^<>()]*>)?\s*$", before)
        return name, receiver.group(1) if receiver else ""

    def arguments(self, opener):
        """Top-level arguments of the call at `opener`: list of (label, start, end)."""
        close = self.match.get(opener, len(self.masked))
        result = []
        depth = 0
        start = opener + 1
        for index in range(opener + 1, close):
            character = self.masked[index]
            if character in self.OPENERS:
                depth += 1
            elif character in self.CLOSERS:
                depth -= 1
            elif character == "," and depth == 0:
                result.append(self._argument(start, index))
                start = index + 1
        if close > start:
            result.append(self._argument(start, close))
        return result

    def _argument(self, start, end):
        text = self.masked[start:end]
        match = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*:(?!:)", text)
        if match:
            return match.group(1), start + match.end(), end
        return "", start, end

    def argument_containing(self, opener, offset):
        for label, start, end in self.arguments(opener):
            if start <= offset < end:
                return label, start, end
        return "", opener + 1, self.match.get(opener, len(self.masked))


class Literal:
    __slots__ = ("path", "line", "kind", "text", "table")

    def __init__(self, path, line, kind, text, table):
        self.path = path
        self.line = line
        self.kind = kind
        self.text = text
        self.table = table


def classify_literal(swift, literal, ranges):
    """Return None when the literal is fine as is, or the kind of leftover it is."""
    start = literal["start"]
    for range_start, range_end in ranges:
        if range_start <= start <= range_end:
            return None
    opener = swift.parent_of_literal.get(start)
    callee, receiver = swift.callee(opener)
    before = swift.masked[max(0, start - 200):start].rstrip()
    after = swift.masked[literal["end"]:literal["end"] + 80].lstrip()
    if callee in DIAGNOSTIC_CALLEES or (callee in LOG_METHODS and re.search(r"log", receiver, re.I)):
        return None
    label = ""
    starts_argument = True
    if opener is not None and swift.masked[opener] == "(":
        label, argument_start, _ = swift.argument_containing(opener, start)
        starts_argument = not swift.masked[argument_start:start].strip()
    if label == "comment":
        return None
    if starts_argument and literal["depth"] == 0:
        if label in ("localized", "defaultValue"):
            arguments = swift.arguments(opener)
            if any(name == "table" for name, _, _ in arguments) or label == "defaultValue":
                return None
            return "untabled"
        if callee in TABLE_LABEL_BY_CALLEE and label == "":
            table_label = TABLE_LABEL_BY_CALLEE[callee]
            if table_label and any(name == table_label for name, _, _ in swift.arguments(opener)):
                return None
    if label == "verbatim":
        return "verbatim"
    if (re.search(r"(==|!=|~=)\s*$", before) or re.match(r"(==|!=)", after)
            or callee in LOGIC_CALLEES or re.search(r"\bcase\s*$", before)):
        return "logic"
    if literal["depth"] > 0:
        return "nested"
    return "literal"


def scan_leftovers(repo, paths=None):
    """Japanese literals in shipping code that are not localized and not annotated."""
    leftovers = []
    for relative in paths if paths is not None else repo.swift_sources():
        table = repo.table_for(relative)
        if table is None:
            continue
        source = repo.path(relative).read_text(encoding="utf-8")
        if not JAPANESE.search(source):
            continue
        swift = SwiftFile(relative, source)
        ranges = excluded_ranges(swift.masked)
        ignored = ignored_lines(source)
        for literal in swift.literals:
            if not JAPANESE.search(literal["plain"]):
                continue
            line = swift.line_of(literal["start"])
            if line in ignored:
                continue
            kind = classify_literal(swift, literal, ranges)
            if kind:
                leftovers.append(Literal(relative, line, kind, literal["text"], table))
    return leftovers


def static_code_checks(repo, findings):
    """Checks that are wrong today, whatever the conversion progress."""
    for relative in repo.swift_sources():
        source = repo.path(relative).read_text(encoding="utf-8")
        if "localized" not in source and "accessibilityIdentifier" not in source and "tableName" not in source \
                and "LocalizedStringResource" not in source and "NSLocalizedString" not in source:
            continue
        swift = SwiftFile(relative, source)
        masked = swift.masked
        for match in re.finditer(r"\.accessibilityIdentifier\s*\(", masked):
            opener = match.end() - 1
            body = masked[opener:swift.match.get(opener, opener)]
            if re.search(r"String\s*\(\s*localized\s*:|LocalizedStringResource\s*\(|NSLocalizedString\s*\(|Text\s*\(", body):
                findings.error("identifier", f"{relative}:{swift.line_of(opener)}: accessibility identifiers are never localized")
        for pattern, table_label in (
            (r"\bString\s*\(\s*localized\s*:", "table"),
            (r"\bAttributedString\s*\(\s*localized\s*:", "table"),
            (r"\bLocalizedStringResource\s*\(", "table"),
            (r"\bText\s*\(", "tableName"),
        ):
            for match in re.finditer(pattern, masked):
                opener = masked.index("(", match.start())
                for label, start, end in swift.arguments(opener):
                    if label == table_label and not masked[start:end].strip().startswith('"'):
                        findings.error(
                            "table-literal",
                            f"{relative}:{swift.line_of(start)}: `{table_label}:` must be a string literal so the compiler can extract the key",
                        )
        for match in re.finditer(r"\bNSLocalizedString\s*\(", masked):
            findings.enforce("nslocalizedstring", f"{relative}:{swift.line_of(match.start())}: use String(localized:table:comment:) instead of NSLocalizedString")


# --------------------------------------------------------------------------
# UI tests launch in Japanese


def ui_test_language_checks(repo, findings):
    directory = repo.path(UI_TEST_DIRECTORY)
    if not directory.exists():
        return
    helper = repo.path(UI_TEST_LANGUAGE_HELPER)
    if not helper.exists():
        findings.error("ui-test-language", f"{UI_TEST_LANGUAGE_HELPER} is missing")
    for path in sorted(directory.glob("*.swift")):
        relative = path.relative_to(repo.root).as_posix()
        if relative == UI_TEST_LANGUAGE_HELPER:
            continue
        source = path.read_text(encoding="utf-8")
        _, masked = lex(source)
        swift_lines = [0]
        for index, character in enumerate(source):
            if character == "\n":
                swift_lines.append(index + 1)

        def line_of(offset):
            import bisect
            return bisect.bisect_right(swift_lines, offset)

        for match in re.finditer(r'"-AppleLanguages"', source):
            findings.enforce("ui-test-language", f"{relative}:{line_of(match.start())}: pin the language with PomoGemUITestLanguage.configureJapanese(app)")
        events = []
        for match in re.finditer(r"(?:\b(?:let|var)\s+)?\b([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*XCUIApplication\s*)?=\s*(?!=)(.{0,40})", masked):
            name, rhs = match.group(1), match.group(2)
            if name in ("launchArguments", "launchEnvironment"):
                continue
            if re.match(r"XCUIApplication\s*\(\s*\)", rhs):
                events.append((match.start(), name, "new"))
            elif not rhs.lstrip().startswith("="):
                events.append((match.start(), name, "assigned"))
        for match in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\.launchArguments\s*=(?!=)", masked):
            events.append((match.start(), match.group(1), "reset"))
        for match in re.finditer(r"PomoGemUITestLanguage\.configure\w*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)", masked):
            events.append((match.start(), match.group(1), "pinned"))
        for match in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\.launchArguments\s*\+?=\s*\[[^\]]*\"-AppleLanguages\"", source):
            events.append((match.end(), match.group(1), "pinned"))
        for match in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\.launch\(\s*\)", masked):
            events.append((match.start(), match.group(1), "launch"))
        state = {}
        for offset, name, event in sorted(events):
            if event == "new":
                state[name] = "unpinned"
            elif event == "assigned":
                state.pop(name, None)
            elif event == "reset":
                if state.get(name) == "pinned" or name not in state:
                    state[name] = "unpinned"
            elif event == "pinned":
                state[name] = "pinned"
            elif event == "launch" and state.get(name) == "unpinned":
                findings.error(
                    "ui-test-language",
                    f"{relative}:{line_of(offset)}: `{name}` launches without PomoGemUITestLanguage.configureJapanese({name})",
                )
                state[name] = "reported"


# --------------------------------------------------------------------------
# Catalog checks


def catalog_paths_on_disk(repo):
    found = []
    for top in repo.config["source_roots"]:
        base = repo.path(top)
        if not base.exists():
            continue
        for directory, directories, names in os.walk(base):
            for name in directories:
                if name.endswith(".lproj"):
                    found.append(("lproj", Path(directory, name).relative_to(repo.root).as_posix()))
            for name in names:
                if name.endswith(".xcstrings"):
                    found.append(("xcstrings", Path(directory, name).relative_to(repo.root).as_posix()))
                elif name.endswith(".strings") or name.endswith(".stringsdict"):
                    found.append(("strings", Path(directory, name).relative_to(repo.root).as_posix()))
    return found


def check_catalog_files(repo, findings):
    expected = set(repo.catalogs.values()) | {item["catalog"] for item in repo.info_plist_catalogs}
    for kind, relative in catalog_paths_on_disk(repo):
        if kind == "xcstrings" and relative not in expected:
            if Path(relative).name == "Localizable.xcstrings":
                findings.error("catalog", f"{relative}: the default Localizable table must stay empty; pass table: \"<Table>\" instead")
            else:
                findings.error("catalog", f"{relative}: catalog is not listed in {CONFIG_RELATIVE}")
        elif kind != "xcstrings":
            findings.error("catalog", f"{relative}: legacy .lproj/.strings files are not used; add strings to a String Catalog")
    documents = {}
    for table, relative in repo.catalogs.items():
        path = repo.path(relative)
        if not path.exists():
            findings.error("catalog", f"{relative}: missing catalog for table {table}")
            continue
        text = path.read_text(encoding="utf-8")
        try:
            document = json.loads(text)
        except ValueError as error:
            findings.error("catalog", f"{relative}: invalid JSON ({error})")
            continue
        if document.get("sourceLanguage") != repo.source_language:
            findings.error("catalog", f"{relative}: sourceLanguage must be {repo.source_language!r}")
        if document.get("version") != "1.0" or set(document) - {"sourceLanguage", "strings", "version"}:
            findings.error("catalog", f"{relative}: unexpected catalog layout (version 1.0 with sourceLanguage/strings only)")
        if dump_catalog(document) != text:
            findings.enforce("format", f"{relative}: not in Xcode's JSON layout; run Scripts/l10n/l10n.py format")
        documents[table] = document
    return documents


def enforced_tables(repo, documents):
    """A table is enforced once it holds a value in any target language."""
    targets = set(repo.target_languages())
    enforced = set()
    for table, document in documents.items():
        for entry in document.get("strings", {}).values():
            if targets & set((entry.get("localizations") or {}).keys()):
                enforced.add(table)
                break
    return enforced


def glossary_rules(repo):
    rules = []
    for term in repo.glossary.get("terms", []):
        japanese = term.get("ja", "")
        if "(" in japanese or not japanese:
            continue
        rules.append(term)
    return rules


def english_mentions(value, english_term):
    lowered = value.lower()
    for alternative in english_term.split(" / "):
        word = alternative.strip().lower()
        if not word:
            continue
        if re.search(r"(?<![a-z])" + re.escape(word) + r"(?:s|es)?(?![a-z])", lowered):
            return True
    return False


def check_translation(repo, findings, table, key, entry, language, localization, enforced):
    where = f"{repo.catalogs[table]}: {key!r} [{language}]"
    source = source_text(key, entry, repo.source_language)
    source_arguments, source_percent = specifiers(source)
    substitutions = localization.get("substitutions") or {}
    leaves = list(string_units(localization))
    for name, substitution in substitutions.items():
        for label, unit in string_units(substitution):
            leaves.append((f"substitution.{name}.{label}", unit))
    if not leaves:
        findings.enforce("translation", f"{where}: no value", enforced)
        return
    plural_forms = set(((localization.get("variations") or {}).get("plural") or {}).keys())
    if plural_forms and "other" not in plural_forms:
        findings.error("translation", f"{where}: plural variations need an 'other' form")
    for label, unit in leaves:
        value = unit.get("value", "")
        state = unit.get("state")
        if state != "translated":
            findings.enforce("translation-state", f"{where} {label}: state is {state!r}, not 'translated'", enforced)
        if JAPANESE.search(value):
            findings.error("translation", f"{where} {label}: Japanese characters left in {value!r}")
        if MARKDOWN.search(value) and not MARKDOWN.search(source):
            findings.error("translation", f"{where} {label}: Markdown in {value!r} would be rendered by SwiftUI")
        if label.startswith("substitution."):
            continue
        arguments, percent = specifiers(value, substitutions)
        if arguments != source_arguments:
            findings.error(
                "translation",
                f"{where} {label}: format specifiers {sorted(arguments.items(), key=str)} differ from the source {sorted(source_arguments.items(), key=str)}",
            )
        if percent != source_percent:
            findings.warn("translation-percent", f"{where} {label}: '%%' count differs from the source")
    if language != "en":
        return
    values = [unit.get("value", "") for _, unit in leaves]
    combined = " ".join(values)
    for term in glossary_rules(repo):
        if term["ja"] not in source:
            continue
        if term.get("lint") in ("error", "warn") and not english_mentions(combined, term["en"]):
            message = f"{where}: glossary term {term['ja']} should read {term['en']!r}"
            if term.get("lint") == "error":
                findings.enforce("glossary", message, False)
            else:
                findings.warn("glossary", message)
        for forbidden in term.get("forbidden_en", []):
            if re.search(r"(?<![A-Za-z])" + re.escape(forbidden) + r"(?![A-Za-z])", combined, re.I):
                findings.warn("glossary", f"{where}: {forbidden!r} is not used for {term['ja']} (glossary: {term['en']})")
    stripped = combined
    for allowed in repo.glossary.get("forbidden_en_allowed", []):
        stripped = re.sub(r"(?<![A-Za-z])" + allowed + r"(?![A-Za-z])", " ", stripped, flags=re.I)
    for forbidden in repo.glossary.get("forbidden_en_anywhere", []):
        if re.search(r"(?<![A-Za-z])" + re.escape(forbidden), stripped, re.I):
            findings.enforce("voice", f"{where}: {forbidden!r} breaks the product voice (Docs/EngagementArchitecture.md)")


def check_catalog_contents(repo, findings, documents, tables=None):
    allowed = set(repo.shipping_languages)
    targets = repo.target_languages()
    enforced = enforced_tables(repo, documents)
    for table, document in documents.items():
        if tables and table not in tables:
            continue
        for key, entry in document.get("strings", {}).items():
            localizations = entry.get("localizations") or {}
            for language in localizations:
                if language not in allowed:
                    findings.error(
                        "language",
                        f"{repo.catalogs[table]}: {key!r} has a {language!r} value, but {language!r} is not in "
                        f"shipping_languages ({CONFIG_RELATIVE}); activate the language first (Docs/Localization.md)",
                    )
            if entry.get("extractionState") == "stale":
                findings.enforce("stale", f"{repo.catalogs[table]}: {key!r} is stale (no longer in code); delete it or carry its translation", table in enforced)
                continue
            if entry.get("shouldTranslate") is False:
                continue
            for language in targets:
                localization = localizations.get(language)
                if localization is None:
                    findings.enforce("missing-translation", f"{repo.catalogs[table]}: {key!r} has no {language!r} value", table in enforced)
                    continue
                check_translation(repo, findings, table, key, entry, language, localization, table in enforced)
    return enforced


def check_info_plist_catalogs(repo, findings):
    allowed = set(repo.shipping_languages)
    for item in repo.info_plist_catalogs:
        relative = item["catalog"]
        path = repo.path(relative)
        if not path.exists():
            findings.error("infoplist", f"{relative}: missing InfoPlist catalog")
            continue
        text = path.read_text(encoding="utf-8")
        try:
            document = json.loads(text)
        except ValueError as error:
            findings.error("infoplist", f"{relative}: invalid JSON ({error})")
            continue
        if dump_catalog(document) != text:
            findings.enforce("format", f"{relative}: not in Xcode's JSON layout; run Scripts/l10n/l10n.py format")
        if document.get("sourceLanguage") != repo.source_language:
            findings.error("infoplist", f"{relative}: sourceLanguage must be {repo.source_language!r}")
        with repo.path(item["info_plist"]).open("rb") as handle:
            info = plistlib.load(handle)
        strings = document.get("strings", {})
        for key in sorted(info):
            if LOCALIZABLE_INFO_KEYS.match(key) and key != "CFBundleName" and key not in strings:
                findings.error("infoplist", f"{relative}: {key} from {item['info_plist']} has no entry, so it would not be localized")
        if "CFBundleDisplayName" not in strings:
            findings.error("infoplist", f"{relative}: CFBundleDisplayName is required so every bundle carries {repo.source_language}.lproj")
        for key, entry in strings.items():
            if not LOCALIZABLE_INFO_KEYS.match(key):
                findings.error("infoplist", f"{relative}: {key!r} is not a localizable Info.plist key")
            if entry.get("extractionState") != "manual":
                findings.error("infoplist", f"{relative}: {key} must be a manual entry (extractionState 'manual')")
            localizations = entry.get("localizations") or {}
            for language in localizations:
                if language not in allowed:
                    findings.error("language", f"{relative}: {key} has a {language!r} value, but {language!r} is not in shipping_languages")
            for language in repo.shipping_languages:
                unit = (localizations.get(language) or {}).get("stringUnit") or {}
                value = unit.get("value")
                if value is None:
                    findings.error("infoplist", f"{relative}: {key} needs an explicit {language!r} value")
                    continue
                if unit.get("state") != "translated":
                    findings.error("infoplist", f"{relative}: {key} [{language}] must be 'translated'")
                if language == repo.source_language and value != info.get(key):
                    findings.error("infoplist", f"{relative}: {key} [{language}] {value!r} differs from {item['info_plist']} {info.get(key)!r}")
                if language != repo.source_language and JAPANESE.search(value):
                    findings.error("infoplist", f"{relative}: {key} [{language}] still contains Japanese")


# --------------------------------------------------------------------------
# Compiler output (.stringsdata)


def collect_stringsdata(repo, derived_data, configuration=None):
    """The newest .stringsdata per source file of the three product targets.

    Returns (entries, missing_targets, problems, paths). Output compiled from
    another checkout, or older than its source file, is a problem: syncing it
    would write someone else's (or yesterday's) strings into the catalogs.
    """
    intermediates = Path(derived_data) / "Build" / "Intermediates.noindex"
    found = {}
    missing_targets = []
    problems = []
    root = os.path.realpath(repo.root)
    generated = os.path.realpath(derived_data)
    for target in repo.config["product_targets"]:
        candidates = []
        for project in intermediates.glob("*.build"):
            for configuration_directory in project.glob("*"):
                if configuration and not configuration_directory.name.startswith(configuration):
                    continue
                candidates.extend((configuration_directory / f"{target}.build").glob("Objects-normal/*/*.stringsdata"))
        if not candidates:
            missing_targets.append(target)
            continue
        for path in candidates:
            data = json.loads(path.read_text(encoding="utf-8"))
            source = os.path.realpath(data.get("source", ""))
            if source.startswith(generated + os.sep):
                continue  # code Xcode generates into DerivedData (asset symbols), never localized
            if not source.startswith(root + os.sep):
                problems.append(f"{path.name} was compiled from {source}, outside this checkout")
                continue
            if not os.path.exists(source):
                continue  # a deleted or renamed file; its old output is ignored
            relative = Path(source).relative_to(root).as_posix()
            modified = path.stat().st_mtime
            key = (target, relative)
            if key not in found or found[key][0] < modified:
                found[key] = (modified, data, path)
    entries = []
    paths = []
    for (target, relative), (modified, data, path) in sorted(found.items()):
        if os.path.getmtime(repo.path(relative)) > modified + 1:
            problems.append(f"{relative} changed after it was compiled; build again first")
        paths.append(str(path))
        for table, items in data.get("tables", {}).items():
            for item in items:
                entries.append({
                    "target": target,
                    "source": relative,
                    "table": table,
                    "key": item["key"],
                    "value": item.get("value"),
                    "line": (item.get("location") or {}).get("startingLine", 0),
                })
    return entries, missing_targets, problems, paths


def check_code_against_catalogs(repo, findings, documents, derived_data, configuration=None):
    entries, missing_targets, problems, _ = collect_stringsdata(repo, derived_data, configuration)
    for target in missing_targets:
        findings.error(
            "stringsdata",
            f"no .stringsdata for {target} under {derived_data}; build it first (SWIFT_EMIT_LOC_STRINGS must stay YES)",
        )
    for problem in problems:
        findings.error("stringsdata", problem)
    if missing_targets:
        return
    enforced = enforced_tables(repo, documents)
    common_files_keys = {entry["key"] for entry in entries if entry["table"] == "Common" and repo.table_for(entry["source"]) == "Common"}
    common_manual = {key for key, value in documents.get("Common", {}).get("strings", {}).items() if value.get("extractionState") == "manual"}
    emitted = collections.defaultdict(set)
    default_table = collections.Counter()
    unassigned = set()
    seen = set()
    for entry in entries:
        table = entry["table"]
        source = entry["source"]
        # Shared files compile into two targets; judge each occurrence once.
        identity = (source, entry["line"], table, entry["key"])
        if identity in seen:
            continue
        seen.add(identity)
        expected = repo.table_for(source)
        where = f"{source}:{entry['line']}"
        emitted[table].add(entry["key"])
        if table == "Localizable":
            if expected is not None:
                default_table[source] += 1
            continue
        if table not in repo.catalogs:
            findings.error("table", f"{where}: unknown table {table!r} (tables: {', '.join(sorted(repo.catalogs))})")
            continue
        if expected is None:
            findings.enforce("table", f"{where}: Debug-only code is never localized (table {table!r})")
        elif expected == "UNASSIGNED":
            if source not in unassigned:
                unassigned.add(source)
                findings.enforce("unassigned", f"{source}: file has no table yet; add a rule to {CONFIG_RELATIVE}")
        elif table == "Common" and expected != "Common":
            if entry["key"] not in common_files_keys | common_manual:
                findings.enforce("common-frozen", f"{where}: {entry['key']!r} is not a Common string; use table {expected!r}")
        elif table != expected:
            findings.enforce("table", f"{where}: uses table {table!r}; files here use {expected!r}", expected in enforced)
        document = documents.get(table)
        if document is not None and entry["key"] not in document.get("strings", {}):
            findings.enforce("sync", f"{where}: {entry['key']!r} is not in {repo.catalogs[table]}; run Scripts/l10n/l10n.py sync", table in enforced)
    for table, document in documents.items():
        for key, value in document.get("strings", {}).items():
            state = value.get("extractionState")
            if state in ("manual", "stale"):
                continue
            if key not in emitted.get(table, set()):
                findings.enforce("sync", f"{repo.catalogs[table]}: {key!r} is no longer in code; run Scripts/l10n/l10n.py sync", table in enforced)
    for source, count in sorted(default_table.items()):
        findings.enforce(
            "default-table",
            f"{source}: {count} string(s) go to the default Localizable table; add tableName:/table:",
            repo.table_for(source) in enforced,
        )


# --------------------------------------------------------------------------
# Commands


def print_findings(findings, verbose, title):
    print(title)
    if findings.errors:
        print(f"\nerrors ({len(findings.errors)}):")
        for category, message in findings.errors:
            print(f"  [{category}] {message}")
    if findings.warnings:
        total = sum(len(items) for items in findings.warnings.values())
        print(f"\nnot enforced yet ({total}; --strict turns these into errors):")
        for category, items in findings.warnings.items():
            print(f"  [{category}] {len(items)}")
            shown = items if verbose else items[:3]
            for message in shown:
                print(f"      {message}")
            if len(items) > len(shown):
                print(f"      … {len(items) - len(shown)} more (--verbose lists all)")


def command_check(repo, arguments):
    findings = Findings(arguments.strict)
    tables = set(arguments.tables.split(",")) if arguments.tables else None
    if tables:
        unknown = tables - set(repo.catalogs)
        if unknown:
            raise SystemExit(f"error: unknown table(s): {', '.join(sorted(unknown))}")
    documents = check_catalog_files(repo, findings)
    enforced = check_catalog_contents(repo, findings, documents, tables)
    check_info_plist_catalogs(repo, findings)
    static_code_checks(repo, findings)
    ui_test_language_checks(repo, findings)
    leftovers = scan_leftovers(repo)
    per_kind = collections.Counter()
    unassigned = set()
    for literal in leftovers:
        if tables and literal.table not in tables:
            continue
        message = f"{literal.path}:{literal.line}: [{literal.kind}] {literal.text[:80]!r} is not localized"
        if literal.table == "UNASSIGNED" and literal.path not in unassigned:
            unassigned.add(literal.path)
            findings.enforce("unassigned", f"{literal.path}: file has no table yet; add a rule to {CONFIG_RELATIVE}")
        if arguments.strict or literal.table in enforced:
            findings.error("leftover", message + " (localize it, or annotate // l10n-ignore: <reason>)")
        else:
            per_kind[literal.kind] += 1
    if per_kind:
        files = len({literal.path for literal in leftovers if literal.table not in enforced})
        findings.warn(
            "leftover",
            f"{sum(per_kind.values())} Japanese literal(s) in {files} file(s) are not localized yet "
            f"({', '.join(f'{kind} {count}' for kind, count in sorted(per_kind.items()))}); see `l10n.py report`",
        )
    if arguments.derived_data:
        check_code_against_catalogs(repo, findings, documents, arguments.derived_data, arguments.configuration)
    mode = "strict" if arguments.strict else "report mode"
    scope = f", tables {', '.join(sorted(tables))}" if tables else ""
    stringsdata = "with compiler output" if arguments.derived_data else "static only"
    print_findings(findings, arguments.verbose, f"l10n check ({mode}, {stringsdata}{scope})")
    if findings.errors:
        print(f"\nFAILED: {len(findings.errors)} error(s).")
        return 1
    print("\nOK.")
    return 0


def command_report(repo, arguments):
    paths = None
    if arguments.file:
        paths = [arguments.file]
    leftovers = scan_leftovers(repo, paths)
    selected = []
    for literal in leftovers:
        rule = repo.rule_for(literal.path) or {}
        if arguments.package and rule.get("package") != arguments.package:
            continue
        if arguments.table and literal.table != arguments.table:
            continue
        selected.append(literal)
    by_file = collections.OrderedDict()
    for literal in selected:
        by_file.setdefault(literal.path, []).append(literal)
    for path, items in by_file.items():
        print(f"{path} ({len(items)})")
        if not arguments.summary:
            for literal in items:
                print(f"  {literal.line:5d} [{literal.kind}] {literal.text[:100]}")
    kinds = collections.Counter(literal.kind for literal in selected)
    print(f"\n{len(selected)} literal(s) left in {len(by_file)} file(s): "
          + (", ".join(f"{kind} {count}" for kind, count in sorted(kinds.items())) or "none"))
    return 0


def command_status(repo, _arguments):
    languages = repo.shipping_languages
    print(f"source {repo.source_language}; shipping {', '.join(languages)}")
    for table, relative in list(repo.catalogs.items()) + [(item["bundle"] + " InfoPlist", item["catalog"]) for item in repo.info_plist_catalogs]:
        path = repo.path(relative)
        if not path.exists():
            print(f"  {table:28s} missing ({relative})")
            continue
        strings = load_catalog(path).get("strings", {})
        stale = sum(1 for entry in strings.values() if entry.get("extractionState") == "stale")
        per_language = []
        for language in sorted({language for entry in strings.values() for language in (entry.get("localizations") or {})}):
            states = collections.Counter()
            for entry in strings.values():
                localization = (entry.get("localizations") or {}).get(language)
                if localization is None:
                    continue
                for _, unit in string_units(localization):
                    states[unit.get("state", "?")] += 1
            per_language.append(f"{language}: " + ", ".join(f"{state} {count}" for state, count in sorted(states.items())))
        print(f"  {table:28s} {len(strings):4d} keys, {stale} stale" + ("; " + "; ".join(per_language) if per_language else ""))
    return 0


def feature_catalog_paths(repo):
    return [str(repo.path(relative)) for relative in repo.catalogs.values()]


def command_sync(repo, arguments):
    entries, missing_targets, problems, paths = collect_stringsdata(repo, arguments.derived_data, arguments.configuration)
    if missing_targets:
        raise SystemExit(f"error: no .stringsdata for {', '.join(missing_targets)} under {arguments.derived_data}; build the PomoGem scheme first")
    if problems:
        raise SystemExit("error: " + "\n       ".join(problems))
    unknown = sorted({entry["table"] for entry in entries} - set(repo.catalogs) - {"Localizable"})
    if unknown:
        raise SystemExit(f"error: code uses unknown table(s) {', '.join(unknown)}; fix the table: arguments first")
    for relative in repo.catalogs.values():
        if not repo.path(relative).exists():
            raise SystemExit(f"error: missing catalog {relative}")
    command = ["xcrun", "xcstringstool", "sync", *feature_catalog_paths(repo)]
    for path in paths:
        command += ["--stringsdata", path]
    subprocess.run(command, check=True)
    for relative in repo.catalogs.values():
        path = repo.path(relative)
        write_catalog(path, load_catalog(path))
    print(f"Synced {len(repo.catalogs)} catalogs from {len(paths)} .stringsdata files.")
    subprocess.run(["git", "-C", str(repo.root), "status", "--short", "--", *repo.catalogs.values()], check=False)
    return 0


def parse_translation_file(path):
    """Read {key: value | {"plural": {...}} | {"value": ..., "substitutions": {...}}} from JSON or TSV."""
    text = Path(path).read_text(encoding="utf-8")
    if str(path).endswith(".json"):
        return json.loads(text)
    result = collections.OrderedDict()
    for number, line in enumerate(text.split("\n"), start=1):
        if not line.strip() or line.startswith("#"):
            continue
        columns = line.split("\t")
        if len(columns) not in (2, 3):
            raise SystemExit(f"error: {path}:{number}: expected key<TAB>value[<TAB>plural.<category>]")
        key, value = columns[0], columns[1].replace("\\n", "\n").replace("\\t", "\t")
        if len(columns) == 3:
            kind, _, category = columns[2].partition(".")
            if kind != "plural" or not category:
                raise SystemExit(f"error: {path}:{number}: third column must be plural.<category>")
            result.setdefault(key, {"plural": collections.OrderedDict()})
            result[key]["plural"][category] = value
        else:
            result[key] = value
    return result


def localization_from(spec, state):
    def unit(value):
        return {"stringUnit": {"state": state, "value": value}}

    if isinstance(spec, str):
        return unit(spec)
    localization = {}
    if "value" in spec:
        localization.update(unit(spec["value"]))
    if "plural" in spec:
        localization["variations"] = {"plural": {form: unit(value) for form, value in spec["plural"].items()}}
    for name, substitution in (spec.get("substitutions") or {}).items():
        localization.setdefault("substitutions", {})[name] = {
            "argNum": int(substitution["argNum"]),
            "formatSpecifier": substitution["formatSpecifier"],
            "variations": {"plural": {form: unit(value) for form, value in substitution["plural"].items()}},
        }
    return localization


def command_set(repo, arguments):
    if arguments.table not in repo.catalogs:
        raise SystemExit(f"error: unknown table {arguments.table}")
    if arguments.language == repo.source_language:
        raise SystemExit("error: the source language comes from code; edit the Swift literal instead")
    if arguments.language not in repo.shipping_languages:
        raise SystemExit(f"error: {arguments.language!r} is not in shipping_languages; activate it first (Docs/Localization.md)")
    path = repo.path(repo.catalogs[arguments.table])
    document = load_catalog(path)
    translations = parse_translation_file(arguments.source)
    strings = document.setdefault("strings", {})
    written = 0
    for key, spec in translations.items():
        if key not in strings:
            raise SystemExit(f"error: {key!r} is not in {repo.catalogs[arguments.table]}; build and run `l10n.py sync` first")
        entry = strings[key]
        entry.setdefault("localizations", {})[arguments.language] = localization_from(spec, arguments.state)
        written += 1
    write_catalog(path, document)
    print(f"Wrote {written} {arguments.language} value(s) to {repo.catalogs[arguments.table]}.")
    return 0


def command_carry(repo, arguments):
    if arguments.table not in repo.catalogs:
        raise SystemExit(f"error: unknown table {arguments.table}")
    path = repo.path(repo.catalogs[arguments.table])
    document = load_catalog(path)
    strings = document.get("strings", {})
    old = strings.get(arguments.old)
    new = strings.get(arguments.new)
    if old is None or new is None:
        raise SystemExit("error: both keys must exist; build and run `l10n.py sync` first")
    localization = (old.get("localizations") or {}).get(arguments.language)
    if localization is None:
        raise SystemExit(f"error: {arguments.old!r} has no {arguments.language} value to carry")
    carried = json.loads(json.dumps(localization))

    def mark(node):
        if isinstance(node, dict):
            if "stringUnit" in node:
                node["stringUnit"]["state"] = "needs_review"
            for value in node.values():
                mark(value)

    mark(carried)
    new.setdefault("localizations", {})[arguments.language] = carried
    if old.get("extractionState") == "stale":
        del strings[arguments.old]
    write_catalog(path, document)
    print(f"Carried {arguments.language} from {arguments.old!r} to {arguments.new!r} (needs_review).")
    return 0


def command_format(repo, arguments):
    changed = []
    for relative in list(repo.catalogs.values()) + [item["catalog"] for item in repo.info_plist_catalogs]:
        path = repo.path(relative)
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        formatted = dump_catalog(json.loads(text))
        if formatted != text:
            changed.append(relative)
            if not arguments.check:
                path.write_text(formatted, encoding="utf-8")
    for relative in changed:
        print(("would reformat " if arguments.check else "reformatted ") + relative)
    return 1 if (arguments.check and changed) else 0


def read_strings_file(path):
    with open(path, "rb") as handle:
        data = handle.read()
    try:
        return plistlib.loads(data)
    except Exception:
        text = data.decode("utf-16") if data.startswith((b"\xff\xfe", b"\xfe\xff")) else data.decode("utf-8")
        return dict(re.findall(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', text))


def command_verify_bundle(repo, arguments):
    app = Path(arguments.app)
    errors = []
    shipping = set(repo.shipping_languages)
    for bundle_name, relative in repo.config["bundle_paths"].items():
        bundle = (app / relative).resolve()
        if not bundle.exists():
            errors.append(f"{bundle_name}: missing at {bundle}")
            continue
        present = {path.name[:-len(".lproj")] for path in bundle.glob("*.lproj")}
        for language in sorted(shipping - present):
            errors.append(f"{bundle_name}: {language}.lproj is missing, so {language} users could be served another language")
        for language in sorted(present - shipping - {"Base"}):
            errors.append(f"{bundle_name}: {language}.lproj ships, but {language!r} is not in shipping_languages")
        info_catalog = next((item for item in repo.info_plist_catalogs if item["bundle"] == bundle_name), None)
        for language in sorted(shipping & present):
            strings_path = bundle / f"{language}.lproj" / "InfoPlist.strings"
            if not strings_path.exists():
                errors.append(f"{bundle_name}: {language}.lproj/InfoPlist.strings is missing")
                continue
            values = read_strings_file(strings_path)
            if info_catalog:
                catalog = load_catalog(repo.path(info_catalog["catalog"]))
                for key, entry in catalog.get("strings", {}).items():
                    expected = (((entry.get("localizations") or {}).get(language) or {}).get("stringUnit") or {}).get("value")
                    if expected is not None and values.get(key) != expected:
                        errors.append(f"{bundle_name}: {language}.lproj/InfoPlist.strings {key} is {values.get(key)!r}, expected {expected!r}")
            if language != repo.source_language:
                for table in repo.config["catalog_bundles"].get(bundle_name, []):
                    document = load_catalog(repo.path(repo.catalogs[table]))
                    if document.get("strings") and not any((bundle / f"{language}.lproj" / f"{table}{suffix}").exists() for suffix in (".strings", ".stringsdict")):
                        errors.append(f"{bundle_name}: {language}.lproj has no {table} table")
        print(f"{bundle_name}: " + (", ".join(sorted(present)) or "no .lproj"))
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"Bundles carry exactly the shipping localizations ({', '.join(repo.shipping_languages)}).")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=str(DEFAULT_ROOT), help=argparse.SUPPRESS)
    commands = parser.add_subparsers(dest="command", required=True)

    check = commands.add_parser("check", help="lint catalogs, code and UI tests")
    check.add_argument("--strict", action="store_true", help="enforce every rule (English integration)")
    check.add_argument("--derived-data", help="DerivedData of a build, to compare code with catalogs")
    check.add_argument("--configuration", help="build configuration prefix inside DerivedData (e.g. Debug)")
    check.add_argument("--tables", help="comma-separated tables to limit catalog and literal checks")
    check.add_argument("--verbose", action="store_true", help="list every finding")

    report = commands.add_parser("report", help="list Japanese literals that are not localized yet")
    report.add_argument("--package")
    report.add_argument("--table")
    report.add_argument("--file")
    report.add_argument("--summary", action="store_true", help="print per-file counts only")

    commands.add_parser("status", help="summarize catalogs")

    sync = commands.add_parser("sync", help="merge compiler output into all feature catalogs")
    sync.add_argument("--derived-data", required=True)
    sync.add_argument("--configuration")

    set_parser = commands.add_parser("set", help="bulk-write translations")
    set_parser.add_argument("--table", required=True)
    set_parser.add_argument("--from", dest="source", required=True)
    set_parser.add_argument("--language", default="en")
    set_parser.add_argument("--state", default="translated", choices=["translated", "needs_review"])

    carry = commands.add_parser("carry", help="move a translation to an edited key")
    carry.add_argument("--table", required=True)
    carry.add_argument("--from", dest="old", required=True)
    carry.add_argument("--to", dest="new", required=True)
    carry.add_argument("--language", default="en")

    format_parser = commands.add_parser("format", help="rewrite catalogs in Xcode's layout")
    format_parser.add_argument("--check", action="store_true")

    verify = commands.add_parser("verify-bundle", help="check localizations inside a built PomoGem.app")
    verify.add_argument("app")

    arguments = parser.parse_args(argv)
    repo = Repo(arguments.root)
    handlers = {
        "check": command_check,
        "report": command_report,
        "status": command_status,
        "sync": command_sync,
        "set": command_set,
        "carry": command_carry,
        "format": command_format,
        "verify-bundle": command_verify_bundle,
    }
    return handlers[arguments.command](repo, arguments)


if __name__ == "__main__":
    sys.exit(main())
