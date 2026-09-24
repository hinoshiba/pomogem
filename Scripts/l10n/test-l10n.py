#!/usr/bin/env python3
"""Regression tests for Scripts/l10n/l10n.py (run by Scripts/check-oss-readiness.sh)."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("l10n", HERE / "l10n.py")
assert SPEC is not None and SPEC.loader is not None
L10N = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(L10N)
REAL_CONFIG = json.loads((HERE / "table-map.json").read_text(encoding="utf-8"))


def has_xcstringstool():
    return shutil.which("xcrun") is not None and subprocess.run(
        ["xcrun", "--find", "xcstringstool"], capture_output=True
    ).returncode == 0


class FixtureRepo:
    """A throwaway checkout with the real table map and small catalogs."""

    def __init__(self, shipping=("ja",)):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        config = json.loads(json.dumps(REAL_CONFIG))
        config["shipping_languages"] = list(shipping)
        self.write("Scripts/l10n/table-map.json", json.dumps(config, ensure_ascii=False, indent=2))
        self.write("Scripts/l10n/glossary.json", (HERE / "glossary.json").read_text(encoding="utf-8"))
        for relative in config["catalogs"].values():
            self.catalog(relative, {})
        info = {
            "PomoGem/Info.plist": {"CFBundleDisplayName": "ポモジェム", "NSMotionUsageDescription": "動かします。"},
            "PomoGemWidgets/Info.plist": {"CFBundleDisplayName": "ポモジェム"},
            "PomoGemScreenTimeMonitor/Info.plist": {"CFBundleDisplayName": "ポモジェム スクリーンタイム"},
        }
        for relative, values in info.items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("wb") as handle:
                plistlib.dump(values, handle)
        for item in config["info_plist_catalogs"]:
            values = info[item["info_plist"]]
            self.catalog(item["catalog"], {
                key: {"extractionState": "manual", "localizations": {language: unit(value if language == "ja" else "PomoGem") for language in shipping}}
                for key, value in values.items()
            })
        self.write("PomoGemUITests/PomoGemUITestLanguage.swift", "enum PomoGemUITestLanguage {}\n")

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def catalog(self, relative, strings):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        L10N.write_catalog(path, {"sourceLanguage": "ja", "strings": strings, "version": "1.0"})

    def run(self, *arguments):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            code = L10N.main(["--root", str(self.root), *arguments])
        return code, output.getvalue()

    def close(self):
        self.directory.cleanup()


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


class CatalogFormatTests(unittest.TestCase):
    @unittest.skipUnless(has_xcstringstool(), "xcstringstool is part of Xcode")
    def test_writer_reproduces_xcstringstool_byte_for_byte(self):
        keys = ["a/b", 'say "hi"', "line1\nline2", "tab\there", "ctl\u0001x", "✦ 金", "😀", "！x", "%lld粒", "Zeta", "alpha", "é"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = {
                "source": str(root / "X.swift"),
                "tables": {"Home": [
                    {"key": key, "comment": f"c/{index}", "location": {"startingColumn": 1, "startingLine": index + 1, "startingOffset": index}}
                    for index, key in enumerate(keys)
                ]},
                "version": 1,
            }
            (root / "X.stringsdata").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
            catalog = root / "Home.xcstrings"
            L10N.write_catalog(catalog, {"sourceLanguage": "ja", "strings": {
                "%lld粒": {"localizations": {"en": {"variations": {"plural": {"one": unit("%lld gem"), "other": unit("%lld gems")}}}}},
                "old": {"extractionState": "stale", "localizations": {"en": unit("Old")}},
            }, "version": "1.0"})
            subprocess.run(["xcrun", "xcstringstool", "sync", str(catalog), "--stringsdata", str(root / "X.stringsdata")], check=True)
            written = catalog.read_text(encoding="utf-8")
            self.assertEqual(L10N.dump_catalog(json.loads(written)), written)
            self.assertIn('"%lld粒" : {\n      "comment" : "c/8"', written)

    def test_empty_catalog_layout(self):
        self.assertEqual(
            L10N.dump_catalog(L10N.empty_catalog()),
            '{\n  "sourceLanguage" : "ja",\n  "strings" : {\n\n  },\n  "version" : "1.0"\n}',
        )


class TableMapTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FixtureRepo()
        self.repo = L10N.Repo(self.fixture.root)

    def tearDown(self):
        self.fixture.close()

    def test_first_matching_rule_wins(self):
        self.assertEqual(self.repo.table_for("PomoGem/Features/Settings/StorageTransferSettingsSection.swift"), "Storage")
        self.assertEqual(self.repo.table_for("PomoGem/Features/Settings/SettingsView.swift"), "Settings")
        self.assertEqual(self.repo.table_for("PomoGem/Features/Settings/ScreenTimeSettingsView.swift"), "ScreenTime")
        self.assertEqual(self.repo.table_for("PomoGem/Features/Overview/ProgressCrystal.swift"), "Progress")
        self.assertEqual(self.repo.table_for("PomoGem/App/StorageTransferLateArrivalBanner.swift"), "Launch")
        self.assertEqual(self.repo.table_for("PomoGem/Core/Localization/LocalizedFormat.swift"), "Common")
        self.assertIsNone(self.repo.table_for("PomoGem/Debug/Fixture.swift"))
        self.assertEqual(self.repo.table_for("PomoGem/Brand/New.swift"), "UNASSIGNED")

    def test_every_rule_table_has_a_catalog(self):
        for rule in REAL_CONFIG["rules"]:
            if rule["table"] not in (None, "UNASSIGNED"):
                self.assertIn(rule["table"], REAL_CONFIG["catalogs"], rule["glob"])


class LeftoverTests(unittest.TestCase):
    SOURCE = '''import SwiftUI
struct V: View {
    let n: Int
    let ok: Bool
    var body: some View {
        VStack {
            Text("集中", tableName: "Home")
            Text(String(localized: "休憩", table: "Home", comment: "Break"))
            Text(String(localized: "\\(n)粒", table: "Home", comment: "count"))
            Text(LocalizedStringResource("記録", table: "Home"))
            Text(String(localized: "home.rest", defaultValue: "少し休む", table: "Home"))
            Text("未変換")
            Text(verbatim: "そのまま")
            Text(String(localized: "表なし"))
            Text(String(localized: "\\(ok ? "はい" : "いいえ")", table: "Home"))
            // l10n-ignore: persisted legacy value
            Text("保存値")
            Text("同じ行") // l10n-ignore: fixture
        }
        .accessibilityLabel(Text("瓶", tableName: "Home"))
    }
    func f(name: String) -> Bool {
        print("デバッグ")
        logger.error("失敗しました")
        return name == "英語"
    }
}
#if DEBUG
let debugOnly = "デバッグ専用"
#endif
#Preview { Text("プレビュー") }
'''

    def test_classifies_every_kind(self):
        fixture = FixtureRepo()
        try:
            fixture.write("PomoGem/Features/Home/V.swift", self.SOURCE)
            repo = L10N.Repo(fixture.root)
            found = {(literal.text, literal.kind) for literal in L10N.scan_leftovers(repo)}
            self.assertEqual(found, {
                ("未変換", "literal"),
                ("そのまま", "verbatim"),
                ("表なし", "untabled"),
                ("はい", "nested"),
                ("いいえ", "nested"),
                ("英語", "logic"),
            })
        finally:
            fixture.close()

    def test_static_errors(self):
        fixture = FixtureRepo()
        try:
            fixture.write("PomoGem/Features/Home/W.swift", '''import SwiftUI
let a = Text("x").accessibilityIdentifier(String(localized: "id", table: "Home"))
let name = "Home"
let b = String(localized: "集中", table: name)
''')
            code, output = fixture.run("check")
            self.assertEqual(code, 1)
            self.assertIn("[identifier]", output)
            self.assertIn("[table-literal]", output)
        finally:
            fixture.close()


class UITestLanguageTests(unittest.TestCase):
    def check(self, source):
        fixture = FixtureRepo()
        try:
            fixture.write("PomoGemUITests/SampleUITests.swift", source)
            return fixture.run("check")
        finally:
            fixture.close()

    def test_pinned_launches_pass(self):
        code, output = self.check('''
func a() {
    let app = XCUIApplication()
    app.launchArguments = []
    PomoGemUITestLanguage.configureJapanese(app)
    app.launch()
    app.terminate()
    app.launch()
    XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
}
func b() {
    let app = configuredApp()
    app.launch()
}
''')
        self.assertEqual(code, 0, output)

    def test_unpinned_or_reset_launches_fail(self):
        code, output = self.check('''
func a() {
    let application = XCUIApplication()
    application.launch()
}
func b() {
    let app = XCUIApplication()
    PomoGemUITestLanguage.configureJapanese(app)
    app.launchArguments = ["-flag", "1"]
    app.launch()
}
''')
        self.assertEqual(code, 1)
        self.assertIn("`application` launches without", output)
        self.assertIn("`app` launches without", output)

    def test_raw_pin_is_reported_but_only_enforced_with_strict(self):
        source = '''
func a() {
    let app = XCUIApplication()
    app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
    app.launch()
}
'''
        code, output = self.check(source)
        self.assertEqual(code, 0, output)
        self.assertIn("[ui-test-language] 1", output)
        fixture = FixtureRepo()
        try:
            fixture.write("PomoGemUITests/SampleUITests.swift", source)
            code, output = fixture.run("check", "--strict")
            self.assertEqual(code, 1)
            self.assertIn("pin the language with PomoGemUITestLanguage", output)
        finally:
            fixture.close()


class CatalogCheckTests(unittest.TestCase):
    def test_fresh_fixture_passes(self):
        fixture = FixtureRepo()
        try:
            code, output = fixture.run("check")
            self.assertEqual(code, 0, output)
        finally:
            fixture.close()

    def test_english_before_activation_is_an_error(self):
        fixture = FixtureRepo()
        try:
            fixture.catalog("PomoGem/Localization/Home.xcstrings", {"集中": {"localizations": {"en": unit("Focus")}}})
            code, output = fixture.run("check")
            self.assertEqual(code, 1)
            self.assertIn("[language]", output)
        finally:
            fixture.close()

    def test_stray_and_default_catalogs_are_errors(self):
        fixture = FixtureRepo()
        try:
            fixture.catalog("PomoGem/Localizable.xcstrings", {})
            fixture.write("PomoGem/en.lproj/Home.strings", '"a" = "b";\n')
            code, output = fixture.run("check")
            self.assertEqual(code, 1)
            self.assertIn("default Localizable table", output)
            self.assertIn("legacy .lproj", output)
        finally:
            fixture.close()

    def test_translations_are_checked_once_a_table_is_activated(self):
        fixture = FixtureRepo(shipping=("ja", "en"))
        try:
            fixture.catalog("PomoGem/Localization/Home.xcstrings", {
                "集中": {"localizations": {"en": unit("Focus")}},
                "未訳": {},
                "%lld粒": {"localizations": {"en": {"variations": {"plural": {"one": unit("%lld gem")}}}}},
                "%1$@と%2$lld": {"localizations": {"en": unit("%1$@ and %2$@")}},
                "瓶": {"localizations": {"en": unit("瓶 jar")}},
                "太字": {"localizations": {"en": unit("**Bold**")}},
                "記録": {"localizations": {"en": unit("Log", state="needs_review")}},
            })
            fixture.catalog("PomoGem/Localization/Log.xcstrings", {"記録": {}})
            code, output = fixture.run("check")
            self.assertEqual(code, 1)
            self.assertIn("'未訳' has no 'en' value", output)
            self.assertIn("'other' form", output)
            self.assertIn("format specifiers", output)
            self.assertIn("Japanese characters left", output)
            self.assertIn("Markdown", output)
            self.assertIn("needs_review", output)
            errors = output.split("not enforced yet")[0]
            self.assertNotIn("Log.xcstrings: '記録' has no 'en' value", errors, "an untouched table is not enforced yet")
            code, output = fixture.run("check", "--strict")
            self.assertIn("Log.xcstrings: '記録' has no 'en' value", output.split("not enforced yet")[0])
        finally:
            fixture.close()

    def test_voice_and_glossary(self):
        fixture = FixtureRepo(shipping=("ja", "en"))
        try:
            fixture.catalog("PomoGem/Localization/Home.xcstrings", {
                "瓶に積む": {"localizations": {"en": unit("Add to the bottle")}},
                "連続しない": {"localizations": {"en": unit("No streaks, no hurry.")}},
            })
            code, output = fixture.run("check", "--strict")
            self.assertIn("'bottle' breaks the product voice", output)
            self.assertIn("glossary term 瓶 should read 'jar'", output)
            self.assertNotIn("'streak' breaks", output)
            self.assertNotIn("'hurry' breaks", output)
        finally:
            fixture.close()

    def test_info_plist_catalog_must_repeat_info_plist(self):
        fixture = FixtureRepo()
        try:
            fixture.catalog("PomoGem/Localization/InfoPlist.xcstrings", {
                "CFBundleDisplayName": {"extractionState": "manual", "localizations": {"ja": unit("ポモ")}},
            })
            fixture.catalog("PomoGemWidgets/Localization/InfoPlist.xcstrings", {})
            code, output = fixture.run("check")
            self.assertEqual(code, 1)
            self.assertIn("differs from PomoGem/Info.plist", output)
            self.assertIn("NSMotionUsageDescription from PomoGem/Info.plist has no entry", output)
            self.assertIn("PomoGemWidgets/Localization/InfoPlist.xcstrings: CFBundleDisplayName is required", output)
        finally:
            fixture.close()

    def test_non_canonical_layout_is_reported(self):
        fixture = FixtureRepo()
        try:
            fixture.write("PomoGem/Localization/Home.xcstrings", '{"sourceLanguage": "ja", "strings": {}, "version": "1.0"}\n')
            code, output = fixture.run("check")
            self.assertEqual(code, 0, output)
            self.assertIn("[format] 1", output)
            self.assertEqual(fixture.run("format", "--check")[0], 1)
            self.assertEqual(fixture.run("format")[0], 0)
            self.assertEqual(fixture.run("format", "--check")[0], 0)
        finally:
            fixture.close()


class StringsdataTests(unittest.TestCase):
    def build(self, fixture, entries_by_file, targets=("PomoGem", "PomoGemWidgets", "PomoGemScreenTimeMonitor"), outside=False):
        derived = fixture.root / "DD"
        for target in targets:
            directory = derived / "Build/Intermediates.noindex/PomoGem.build/Debug-iphonesimulator" / f"{target}.build/Objects-normal/arm64"
            directory.mkdir(parents=True, exist_ok=True)
            for relative, tables in entries_by_file.get(target, {}).items():
                source = fixture.root / relative
                if not source.exists():
                    fixture.write(relative, "// source\n")
                path = Path("/elsewhere") / relative if outside else source
                data = {"source": str(path), "tables": {
                    table: [{"key": key, "location": {"startingColumn": 1, "startingLine": 1, "startingOffset": 0}} for key in keys]
                    for table, keys in tables.items()
                }, "version": 1}
                stringsdata = directory / (Path(relative).stem + ".stringsdata")
                stringsdata.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
                os.utime(stringsdata, (source.stat().st_mtime + 5, source.stat().st_mtime + 5))
        return str(derived)

    def test_routing_and_drift(self):
        fixture = FixtureRepo()
        try:
            fixture.catalog("PomoGem/Localization/Common.xcstrings", {"・": {}})
            fixture.catalog("PomoGem/Localization/Home.xcstrings", {"集中": {}, "消えた": {}})
            derived = self.build(fixture, {
                "PomoGem": {
                    "PomoGem/Core/Localization/LocalizedFormat.swift": {"Common": ["・"]},
                    "PomoGem/Features/Home/HomeView.swift": {"Home": ["集中", "新規"], "Common": ["・", "勝手"], "Settings": ["設定"], "Localizable": ["表なし"], "Typo": ["x"]},
                },
                "PomoGemWidgets": {"PomoGemWidgets/Widget.swift": {"Widgets": []}},
                "PomoGemScreenTimeMonitor": {"PomoGemScreenTimeMonitor/Monitor.swift": {}},
            })
            code, output = fixture.run("check", "--derived-data", derived, "--verbose")
            self.assertEqual(code, 1)
            self.assertIn("unknown table 'Typo'", output)
            self.assertIn("'勝手' is not a Common string", output)
            self.assertNotIn("'・' is not a Common string", output)
            self.assertIn("uses table 'Settings'; files here use 'Home'", output)
            self.assertIn("'新規' is not in PomoGem/Localization/Home.xcstrings", output)
            self.assertIn("'消えた' is no longer in code", output)
            self.assertIn("go to the default Localizable table", output)
        finally:
            fixture.close()

    def test_missing_target_output_fails_closed(self):
        fixture = FixtureRepo()
        try:
            derived = self.build(fixture, {"PomoGem": {"PomoGem/Features/Home/HomeView.swift": {}}}, targets=("PomoGem",))
            code, output = fixture.run("check", "--derived-data", derived)
            self.assertEqual(code, 1)
            self.assertIn("no .stringsdata for PomoGemWidgets", output)
        finally:
            fixture.close()

    def test_output_from_another_checkout_is_rejected(self):
        fixture = FixtureRepo()
        try:
            derived = self.build(fixture, {target: {f"{target}/A.swift": {}} for target in ("PomoGem", "PomoGemWidgets", "PomoGemScreenTimeMonitor")}, outside=True)
            code, output = fixture.run("check", "--derived-data", derived)
            self.assertEqual(code, 1)
            self.assertIn("outside this checkout", output)
        finally:
            fixture.close()


class EditingTests(unittest.TestCase):
    def test_set_and_carry(self):
        fixture = FixtureRepo(shipping=("ja", "en"))
        try:
            fixture.catalog("PomoGem/Localization/Home.xcstrings", {"集中する": {}, "集中を始める": {}, "%lld粒": {}})
            translations = fixture.write("en.json", json.dumps({
                "集中する": "Focus",
                "%lld粒": {"plural": {"one": "%lld gem", "other": "%lld gems"}},
            }, ensure_ascii=False))
            self.assertEqual(fixture.run("set", "--table", "Home", "--from", str(translations))[0], 0)
            path = fixture.root / "PomoGem/Localization/Home.xcstrings"
            strings = json.loads(path.read_text(encoding="utf-8"))["strings"]
            self.assertEqual(strings["集中する"]["localizations"]["en"], unit("Focus"))
            self.assertEqual(strings["%lld粒"]["localizations"]["en"]["variations"]["plural"]["other"], unit("%lld gems"))
            self.assertEqual(L10N.dump_catalog(json.loads(path.read_text(encoding="utf-8"))), path.read_text(encoding="utf-8"))

            strings["集中する"]["extractionState"] = "stale"
            L10N.write_catalog(path, {"sourceLanguage": "ja", "strings": strings, "version": "1.0"})
            self.assertEqual(fixture.run("carry", "--table", "Home", "--from", "集中する", "--to", "集中を始める")[0], 0)
            strings = json.loads(path.read_text(encoding="utf-8"))["strings"]
            self.assertNotIn("集中する", strings)
            self.assertEqual(strings["集中を始める"]["localizations"]["en"], unit("Focus", state="needs_review"))

            unknown = fixture.write("unknown.tsv", "ない\tNothing\n")
            with self.assertRaises(SystemExit):
                fixture.run("set", "--table", "Home", "--from", str(unknown))
        finally:
            fixture.close()

    def test_set_refuses_a_language_that_is_not_active(self):
        fixture = FixtureRepo()
        try:
            fixture.catalog("PomoGem/Localization/Home.xcstrings", {"集中する": {}})
            translations = fixture.write("en.tsv", "集中する\tFocus\n")
            with self.assertRaises(SystemExit):
                fixture.run("set", "--table", "Home", "--from", str(translations))
        finally:
            fixture.close()


class BundleTests(unittest.TestCase):
    def make_app(self, fixture, name, languages):
        """A fake built app whose InfoPlist.strings repeat the fixture catalogs."""
        app = fixture.root / name / "PomoGem.app"
        catalogs = {item["bundle"]: item["catalog"] for item in REAL_CONFIG["info_plist_catalogs"]}
        for bundle_name, relative in REAL_CONFIG["bundle_paths"].items():
            bundle = app / relative
            bundle.mkdir(parents=True, exist_ok=True)
            strings = L10N.load_catalog(fixture.root / catalogs[bundle_name])["strings"]
            for language, bundles in languages.items():
                if bundle_name not in bundles:
                    continue
                directory = bundle / f"{language}.lproj"
                directory.mkdir(parents=True, exist_ok=True)
                values = {
                    key: ((entry.get("localizations") or {}).get(language) or unit("PomoGem"))["stringUnit"]["value"]
                    for key, entry in strings.items()
                }
                with (directory / "InfoPlist.strings").open("wb") as handle:
                    plistlib.dump(values, handle)
        return app

    def test_exact_shipping_localizations(self):
        fixture = FixtureRepo()
        try:
            every = set(REAL_CONFIG["bundle_paths"])
            app = self.make_app(fixture, "ok", {"ja": every})
            code, output = fixture.run("verify-bundle", str(app))
            self.assertEqual(code, 0, output)
            app = self.make_app(fixture, "missing", {"ja": every - {"PomoGemScreenTimeMonitor.appex"}})
            code, output = fixture.run("verify-bundle", str(app))
            self.assertEqual(code, 1)
            self.assertIn("PomoGemScreenTimeMonitor.appex: ja.lproj is missing", output)
            app = self.make_app(fixture, "early", {"ja": every, "en": {"PomoGem.app"}})
            code, output = fixture.run("verify-bundle", str(app))
            self.assertEqual(code, 1)
            self.assertIn("en.lproj ships, but 'en' is not in shipping_languages", output)
        finally:
            fixture.close()

    def test_english_needs_every_table_once_activated(self):
        fixture = FixtureRepo(shipping=("ja", "en"))
        try:
            fixture.catalog("PomoGem/Localization/Home.xcstrings", {"集中": {"localizations": {"en": unit("Focus")}}})
            every = set(REAL_CONFIG["bundle_paths"])
            app = self.make_app(fixture, "app", {"ja": every, "en": every})
            code, output = fixture.run("verify-bundle", str(app))
            self.assertEqual(code, 1)
            self.assertIn("PomoGem.app: en.lproj has no Home table", output)
            (app / "en.lproj" / "Home.strings").write_text('"集中" = "Focus";\n', encoding="utf-8")
            code, output = fixture.run("verify-bundle", str(app))
            self.assertEqual(code, 0, output)
        finally:
            fixture.close()


if __name__ == "__main__":
    unittest.main()
