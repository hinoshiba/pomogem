#!/usr/bin/env python3
"""Regressions for authorization and test exclusion in the archive verifier."""

from __future__ import annotations

import ast
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Optional

sys.dont_write_bytecode = True
from release_profile_policy import (validate_profile_cloud_environment, read_release_version,
                                    validate_bundle_capability_allowlist,
                                    validate_archive_signing_classes)


class ProfileCloudEnvironmentTests(unittest.TestCase):
    def test_production_may_be_one_of_several_authorized_environments(self) -> None:
        for value in ("Production", ["Production"], ["Production", "Development"],
                      ["Development", "Production"]):
            with self.subTest(value=value):
                validate_profile_cloud_environment(value, "Production")

    def test_missing_production_unknown_values_and_malformed_allowlists_fail(self) -> None:
        for value in (None, True, 1, [], {}, ["Production", None], ["Production", 1],
                      ["Production", ["Development"]], "Development", ["Development"],
                      "", "production", "Production ", ["Production", "Unknown"],
                      {"Production"}, ("Production",)):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_profile_cloud_environment(value, "Production")

    def test_development_must_also_be_explicitly_authorized(self) -> None:
        validate_profile_cloud_environment("Development", "Development")
        validate_profile_cloud_environment(["Production", "Development"], "Development")
        with self.assertRaises(ValueError):
            validate_profile_cloud_environment("Production", "Development")


def verifier_bundle_check():
    # Execute the production function, not a test copy of its signed-value
    # guard. Other profile/certificate checks use fixtures because this suite
    # must not depend on a developer's profiles, identities, or private keys.
    script = Path(__file__).with_name("verify-release-archive.sh").read_text()
    for source in re.findall(r"<<'PY'\n(.*?)\nPY(?:\n|$)", script, re.DOTALL):
        module = ast.parse(source)
        function = next((node for node in module.body if isinstance(node, ast.FunctionDef)
                         and node.name == "validate_signed_bundle"), None)
        if function is None:
            continue

        def fail(message: str) -> None:
            raise ValueError(message)

        namespace = {
            "Optional": Optional,
            "TEAM_ID": "fixture-team",
            "APP_GROUP": "group.example.app",
            "validate_bundle_capability_allowlist": validate_bundle_capability_allowlist,
            "validate_profile_cloud_environment": validate_profile_cloud_environment,
            "validate_profile_basics": lambda profile, *_: profile["Entitlements"],
            "require_host_signature_capabilities": lambda *_: None,
            "require_host_profile_capabilities": lambda *_: None,
            "profile_type": lambda profile, *_: profile["FixtureType"],
            "fail": fail,
        }
        compiled = compile(ast.Module(body=[function], type_ignores=[]), str(Path(__file__)), "exec")
        exec(compiled, namespace)
        return namespace["validate_signed_bundle"]
    raise AssertionError("The production validate_signed_bundle function was not found")


class SignedCloudEnvironmentTests(unittest.TestCase):
    def check_bundle(self, *, kind: str, signed_cloud: str, profile_cloud: object):
        is_development = kind == "development"
        entitlements = {
            "application-identifier": "fixture-team.example.app",
            "com.apple.developer.team-identifier": "fixture-team",
            "get-task-allow": is_development,
            "com.apple.developer.family-controls": True,
            "com.apple.developer.usernotifications.time-sensitive": True,
            "com.apple.security.application-groups": ["group.example.app"],
            "com.apple.developer.icloud-container-environment": signed_cloud,
            "aps-environment": "development" if is_development else "production",
        }
        profile_entitlements = dict(entitlements)
        profile_entitlements["com.apple.developer.icloud-container-environment"] = profile_cloud
        return verifier_bundle_check()(
            label="fixture app", bundle_id="example.app", signed_entitlements=entitlements,
            profile={"FixtureType": kind, "Entitlements": profile_entitlements},
            identity="apple-development" if is_development else "apple-distribution",
            certificate_path="unused", is_neutral_widget=False,
        )

    def test_distribution_accepts_production_with_both_environments_authorized(self) -> None:
        self.assertEqual(self.check_bundle(kind="app-store-connect", signed_cloud="Production",
                         profile_cloud=["Production", "Development"]),
                         ("app-store-connect", False, "Production"))

    def test_distribution_still_rejects_signed_development_even_when_authorized(self) -> None:
        with self.assertRaisesRegex(ValueError, "signed CloudKit environment"):
            self.check_bundle(kind="app-store-connect", signed_cloud="Development",
                              profile_cloud=["Production", "Development"])

    def test_distribution_rejects_an_unusable_profile_allowlist(self) -> None:
        for value in (None, ["Development"], ["Production", "Unknown"]):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "profile CloudKit environment"):
                self.check_bundle(kind="app-store-connect", signed_cloud="Production",
                                  profile_cloud=value)

    def test_development_archive_still_requires_signed_development(self) -> None:
        self.assertEqual(self.check_bundle(kind="development", signed_cloud="Development",
                         profile_cloud=["Production", "Development"]),
                         ("development", True, "Development"))
        with self.assertRaisesRegex(ValueError, "signed CloudKit environment"):
            self.check_bundle(kind="development", signed_cloud="Production",
                              profile_cloud=["Production", "Development"])

    def test_non_app_store_distribution_remains_rejected(self) -> None:
        for kind in ("ad-hoc", "enterprise"):
            with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, "non-App-Store"):
                self.check_bundle(kind=kind, signed_cloud="Production",
                                  profile_cloud=["Production", "Development"])


def verifier_payload_check():
    script = Path(__file__).with_name("verify-release-archive.sh").read_text()
    for source in re.findall(r"<<'PY'\n(.*?)\nPY(?:\n|$)", script, re.DOTALL):
        function = next((node for node in ast.parse(source).body
                         if isinstance(node, ast.FunctionDef)
                         and node.name == "validate_release_payload_topology"), None)
        if function is None:
            continue

        def fail(message: str) -> None:
            raise ValueError(message)

        namespace = {"Path": Path, "fail": fail}
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(Path(__file__)), "exec"), namespace)
        return namespace["validate_release_payload_topology"]
    raise AssertionError("The production payload topology check was not found")


class ReleaseTestExclusionTests(unittest.TestCase):
    def test_nested_xctest_payload_is_rejected_including_widget_contents(self) -> None:
        check = verifier_payload_check()
        for relative in ("PlugIns/PomoGemTests.xctest",
                         "PlugIns/PomoGemWidgets.appex/PlugIns/Injected.XCTEST",
                         "PlugIns/PomoGemScreenTimeMonitor.appex/PlugIns/Injected.XCTEST"):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / relative).mkdir(parents=True)
                with self.assertRaisesRegex(ValueError, "XCTest payload"):
                    check(root)

    def test_reviewed_payload_remains_allowed_and_preview_exclusion_is_preserved(self) -> None:
        check = verifier_payload_check()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "PlugIns/PomoGemWidgets.appex").mkdir(parents=True)
            (root / "PomoGem").write_bytes(b"ordinary executable fixture")
            check(root)
            for name in ("PomoGem.debug.dylib", "__preview.dylib", "source.preview-thunk.dylib"):
                with self.subTest(name=name):
                    artifact = root / name
                    artifact.write_bytes(b"fixture")
                    with self.assertRaisesRegex(ValueError, "Debug or preview"):
                        check(root)
                    artifact.unlink()

    def test_real_device_gates_are_rejected_by_the_actual_binary_scan(self) -> None:
        script = Path(__file__).with_name("verify-release-archive.sh").read_text()
        function = re.search(r"^scan_release_binary\(\) \{\n.*?^\}", script, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(function)
        shell = "set -euo pipefail\nfail() { exit 71; }\n" + function.group(0) + \
            '\naudit_tmp=$1\nscan_release_binary "$2" fixture\n'
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fixture-binary"
            for marker in ("POMOGEM_REAL_STORAGE_TRANSFER", "POMOGEM_REAL_TRANSFER_LIFECYCLE",
                           "POMOGEM_REAL_CLOUD_AUDIT", "POMOGEM_UI_TEST_STORAGE_TRANSFER",
                           "liveForIsolatedTesting", "POMOGEM_REAL_SCREENTIME",
                           "ScreenTimeSettingsUITestFixture", "StorageTransferSettingsUITestFixture",
                           "RealDeviceScreenTimeUITests",
                           "$s7PomoGem22StorageTransferRuntimeC22liveForIsolatedTestingACyKFZ"):
                with self.subTest(marker=marker):
                    fixture.write_bytes(b"ordinary string\n" + marker.encode() + b"\n")
                    result = subprocess.run(["/bin/bash", "-c", shell, "payload-test", directory, str(fixture)],
                                            capture_output=True, check=False)
                    self.assertEqual(result.returncode, 71)
            fixture.write_bytes(b"ordinary release executable strings\nStorageTransferRuntime\n"
                                b"StorageTransferReleasePolicy\nallowsCloudReplacement\nisolatedTesting\n")
            result = subprocess.run(["/bin/bash", "-c", shell, "payload-test", directory, str(fixture)],
                                    capture_output=True, check=False)
            self.assertEqual(result.returncode, 0)

    def test_ci_scan_rejects_dedicated_factory_in_host_and_nested_widget(self) -> None:
        # Execute the checked-in CI step against inert files. This also catches
        # regressions where the archive scanner is updated but CI is not.
        workflow = Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml"
        match = re.search(
            r"^      - name: Reject UI-test hooks in Release app\n"
            r"        shell: bash\n        run: \|\n(?P<body>(?:          .*\n|\n)+)",
            workflow.read_text(), re.MULTILINE,
        )
        self.assertIsNotNone(match)
        shell = "\n".join(line[10:] for line in match.group("body").splitlines())
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "DerivedData-CI-Release/Build/Products/Release-iphonesimulator/PomoGem.app"
            widget = bundle / "PlugIns/PomoGemWidgets.appex/PomoGemWidgets"
            widget.parent.mkdir(parents=True)
            monitor = bundle / "PlugIns/PomoGemScreenTimeMonitor.appex/PomoGemScreenTimeMonitor"
            monitor.parent.mkdir(parents=True)
            host = bundle / "PomoGem"
            ordinary = b"StorageTransferRuntime\nStorageTransferReleasePolicy\nallowsCloudReplacement\nisolatedTesting\n"
            environment = dict(os.environ, RUNNER_TEMP=directory)
            for binary in (host, widget, monitor):
                for marker in ("liveForIsolatedTesting",
                               "$s7PomoGem22StorageTransferRuntimeC22liveForIsolatedTestingACyKFZ"):
                    with self.subTest(binary=binary.name, marker=marker):
                        host.write_bytes(ordinary)
                        widget.write_bytes(ordinary)
                        monitor.write_bytes(ordinary)
                        binary.write_bytes(ordinary + b"\x00" + marker.encode() + b"\x00")
                        result = subprocess.run(["/bin/bash", "-c", shell], env=environment,
                                                capture_output=True, check=False)
                        self.assertEqual(result.returncode, 1)
                        self.assertIn(b"forbidden UI-test or Debug hook tokens", result.stderr)
            host.write_bytes(ordinary)
            widget.write_bytes(ordinary)
            monitor.write_bytes(ordinary)
            result = subprocess.run(["/bin/bash", "-c", shell], env=environment,
                                    capture_output=True, check=False)
            self.assertEqual(result.returncode, 0)



class ScreenTimeCapabilityTests(unittest.TestCase):
    def check(self, entitlements: dict, role: str = "monitor", *, profile: bool = False):
        validate_bundle_capability_allowlist(entitlements, role=role, team_id="fixture-team",
            bundle_id="example.app", app_group="group.example.app", is_profile=profile)

    time_sensitive = "com.apple.developer.usernotifications.time-sensitive"

    def screen_capabilities(self):
        return {"com.apple.developer.family-controls": True,
                "com.apple.security.application-groups": ["group.example.app"]}

    def role_capabilities(self, role: str):
        capabilities = self.screen_capabilities()
        if role == "app":
            capabilities[self.time_sensitive] = True
        return capabilities

    def test_family_controls_requires_explicit_boolean_authorization_in_both_products(self):
        for role in ("app", "monitor"):
            for profile in (False, True):
                self.check(self.role_capabilities(role), role, profile=profile)
                for value in (None, False, 1, "true", []):
                    entitlements = self.role_capabilities(role)
                    entitlements["com.apple.developer.family-controls"] = value
                    with self.subTest(role=role, profile=profile, value=value), self.assertRaises(ValueError):
                        self.check(entitlements, role, profile=profile)

    def test_time_sensitive_is_required_by_the_app_and_rejected_elsewhere(self):
        for profile in (False, True):
            self.check(self.role_capabilities("app"), "app", profile=profile)
            for value in (None, False, 1, "true", []):
                entitlements = self.role_capabilities("app")
                if value is None:
                    del entitlements[self.time_sensitive]
                else:
                    entitlements[self.time_sensitive] = value
                with self.subTest(profile=profile, value=value), \
                        self.assertRaisesRegex(ValueError, "Time Sensitive"):
                    self.check(entitlements, "app", profile=profile)
            with self.subTest(role="monitor", profile=profile), self.assertRaises(ValueError):
                self.check(self.screen_capabilities() | {self.time_sensitive: True},
                           "monitor", profile=profile)
            with self.subTest(role="widget", profile=profile), self.assertRaises(ValueError):
                self.check({self.time_sensitive: True}, "widget", profile=profile)

    def test_monitor_group_must_be_exact_without_wildcards_or_extra_groups(self):
        for profile in (False, True):
            for value in (None, [], "group.example.app", ["group.*"], ["group.other"],
                          ["group.example.app", "group.other"],
                          ["group.example.app", "group.example.app"]):
                entitlements = self.screen_capabilities()
                entitlements["com.apple.security.application-groups"] = value
                with self.subTest(value=value, profile=profile), self.assertRaises(ValueError):
                    self.check(entitlements, profile=profile)

    def test_monitor_rejects_cloud_push_document_and_unreviewed_capabilities(self):
        for profile in (False, True):
            for key in ("aps-environment", "com.apple.developer.icloud-services",
                        "com.apple.developer.icloud-container-identifiers",
                        "com.apple.developer.ubiquity-kvstore-identifier",
                        "com.apple.developer.networking.networkextension"):
                with self.subTest(key=key, profile=profile), self.assertRaises(ValueError):
                    self.check(self.screen_capabilities() | {key: "unexpected"}, profile=profile)

    def test_widget_has_neither_screen_time_nor_account_data_capabilities(self):
        for profile in (False, True):
            self.check({}, "widget", profile=profile)
            for key, value in self.screen_capabilities().items():
                with self.subTest(key=key, profile=profile), self.assertRaises(ValueError):
                    self.check({key: value}, "widget", profile=profile)
            with self.assertRaises(ValueError):
                self.check({"com.apple.developer.icloud-services": ["CloudKit"]},
                           "widget", profile=profile)

    def test_keychain_wildcard_is_profile_authorization_only(self):
        for profile in (False, True):
            self.check(self.screen_capabilities() |
                       {"keychain-access-groups": ["fixture-team.example.app"]}, profile=profile)
        self.check(self.screen_capabilities() | {"keychain-access-groups": ["fixture-team.*"]},
                   profile=True)
        for value in (["fixture-team.*"], ["other-team.example.app"], []):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.check(self.screen_capabilities() | {"keychain-access-groups": value})

    def test_monitor_takes_non_cloud_branch_in_actual_verifier(self):
        entitlements = self.screen_capabilities() | {
            "application-identifier": "fixture-team.example.app",
            "com.apple.developer.team-identifier": "fixture-team", "get-task-allow": False,
        }
        self.assertEqual(verifier_bundle_check()(label="fixture monitor", bundle_id="example.app",
            signed_entitlements=entitlements,
            profile={"FixtureType": "app-store-connect", "Entitlements": entitlements},
            identity="apple-distribution", certificate_path="unused",
            is_neutral_widget=False, is_screen_time_monitor=True), ("app-store-connect", False, None))
        profile = {"FixtureType": "app-store-connect", "Entitlements": dict(entitlements)}
        del profile["Entitlements"]["com.apple.developer.family-controls"]
        with self.assertRaisesRegex(ValueError, "Family Controls"):
            verifier_bundle_check()(label="fixture monitor", bundle_id="example.app",
                signed_entitlements=entitlements, profile=profile, identity="apple-distribution",
                certificate_path="unused", is_neutral_widget=False, is_screen_time_monitor=True)


class ArchiveSigningCoherenceTests(unittest.TestCase):
    def distribution(self):
        return {"app": ("app-store-connect", False, "Production"),
                "widget": ("app-store-connect", False, None),
                "monitor": ("app-store-connect", False, None)}

    def test_all_three_products_are_required_and_must_share_distribution_class(self):
        validate_archive_signing_classes(self.distribution(), distribution=True)
        for role in ("widget", "monitor"):
            omitted = self.distribution()
            del omitted[role]
            with self.assertRaises(ValueError):
                validate_archive_signing_classes(omitted, distribution=True)
            for value in (("development", True, None), ("ad-hoc", False, None),
                          ("app-store-connect", False, "Production")):
                with self.subTest(role=role, value=value), self.assertRaises(ValueError):
                    validate_archive_signing_classes(self.distribution() | {role: value}, distribution=True)

    def test_raw_development_is_never_distribution_ready(self):
        development = {"app": ("development", True, "Development"),
                       "widget": ("development", True, None), "monitor": ("development", True, None)}
        validate_archive_signing_classes(development, distribution=False)
        with self.assertRaises(ValueError):
            validate_archive_signing_classes(development, distribution=True)


class SourceReleaseVersionTests(unittest.TestCase):
    def source(self, version="1.1.0", build="10"):
        return f'settings:\n  base:\n    MARKETING_VERSION: "{version}"\n    CURRENT_PROJECT_VERSION: "{build}"\n'

    def test_checkout_version_is_used_without_archive_or_environment_input(self):
        self.assertEqual(read_release_version(self.source()), ("1.1.0", "10"))
        self.assertEqual(read_release_version(self.source("2.0", "123")), ("2.0", "123"))
        project = Path(__file__).resolve().parents[1] / "project.yml"
        version, build = read_release_version(project.read_text())
        self.assertRegex(version, r"^[0-9]+\.[0-9]+(?:\.[0-9]+)?$")
        self.assertRegex(build, r"^[1-9][0-9]*$")

    def test_overrides_missing_values_interpolation_and_non_numeric_versions_fail(self):
        candidates = ["", self.source() + '        MARKETING_VERSION: "2.0"\n',
                      self.source("$(VERSION)"), self.source("1.0; echo unsafe"),
                      self.source(build="0"), self.source(build="1.2"),
                      self.source().replace('    MARKETING_VERSION:', '        MARKETING_VERSION:')]
        for value in candidates:
            with self.subTest(value=value), self.assertRaises(ValueError):
                read_release_version(value)


class ArchiveMetadataTopologyTests(unittest.TestCase):
    def run_archive_metadata(self, root: Path, *, mutation=None):
        script = Path(__file__).with_name("verify-release-archive.sh").read_text()
        source = next(source for source in re.findall(r"<<'PY'\n(.*?)\nPY(?:\n|$)", script, re.DOTALL)
                      if "def validate_bundle_info(" in source)
        app = root / "Products/Applications/PomoGem.app"
        widget = app / "PlugIns/PomoGemWidgets.appex"
        monitor = app / "PlugIns/PomoGemScreenTimeMonitor.appex"
        widget.mkdir(parents=True)
        monitor.mkdir(parents=True)
        identifiers = {"app": "example.app", "widget": "example.app.widget", "monitor": "example.app.monitor"}
        def info(role, executable, package):
            return {"CFBundleIdentifier": identifiers[role], "CFBundleDisplayName": "ポモジェム",
                    "CFBundleExecutable": executable, "CFBundlePackageType": package,
                    "CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "10",
                    "MinimumOSVersion": "17.0", "DTPlatformName": "iphoneos",
                    "CFBundleSupportedPlatforms": ["iPhoneOS"], "UIDeviceFamily": [1],
                    "DTXcode": "2660", "DTSDKName": "iphoneos26.5"}
        app_info = info("app", "PomoGem", "APPL") | {
            "LSRequiresIPhoneOS": True, "CFBundleURLTypes": [{"CFBundleURLName": identifiers["app"],
                "CFBundleURLSchemes": ["pomogem"]}], "POMOGEM_PRIVACY_POLICY_URL": "https://pomogem.hinoshiba.com/#privacy",
            "ITSAppUsesNonExemptEncryption": False, "NSSupportsLiveActivities": True,
        }
        widget_info = info("widget", "PomoGemWidgets", "XPC!") | {
            "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}}
        monitor_info = info("monitor", "PomoGemScreenTimeMonitor", "XPC!") | {
            "CFBundleDisplayName": "ポモジェム スクリーンタイム",
            "NSExtension": {"NSExtensionPointIdentifier": "com.apple.deviceactivity.monitor-extension",
                "NSExtensionPrincipalClass": "PomoGemScreenTimeMonitor.ScreenTimeMonitorExtension"}}
        privacy = {"NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [],
                   "NSPrivacyCollectedDataTypes": [], "NSPrivacyAccessedAPITypes": []}
        app_privacy = privacy | {"NSPrivacyAccessedAPITypes": [
            {"NSPrivacyAccessedAPIType": key, "NSPrivacyAccessedAPITypeReasons": [reason]}
            for key, reason in (("NSPrivacyAccessedAPICategoryFileTimestamp", "C617.1"),
                                ("NSPrivacyAccessedAPICategorySystemBootTime", "35F9.1"),
                                ("NSPrivacyAccessedAPICategoryUserDefaults", "CA92.1"))]}
        monitor_privacy = dict(privacy)
        del monitor_privacy["NSPrivacyTrackingDomains"]
        archive = {"ArchiveVersion": 2, "Name": "PomoGem", "SchemeName": "PomoGem",
                   "ApplicationProperties": {"ApplicationPath": "Applications/PomoGem.app", "Architectures": ["arm64"],
                       "CFBundleIdentifier": identifiers["app"], "CFBundleShortVersionString": "1.1.0",
                       "CFBundleVersion": "10", "Team": "fixture-team", "SigningIdentity": "fixture"}}
        values = {root / "Info.plist": archive, app / "Info.plist": app_info,
                  widget / "Info.plist": widget_info, monitor / "Info.plist": monitor_info,
                  app / "PrivacyInfo.xcprivacy": app_privacy, widget / "PrivacyInfo.xcprivacy": privacy,
                  monitor / "PrivacyInfo.xcprivacy": monitor_privacy}
        if mutation:
            mutation(values, app, monitor)
        for path, value in values.items():
            path.write_bytes(plistlib.dumps(value))
        environment = dict(os.environ, POMOGEM_AUDIT_APP_BUNDLE_ID=identifiers["app"],
            POMOGEM_AUDIT_WIDGET_BUNDLE_ID=identifiers["widget"], POMOGEM_AUDIT_MONITOR_BUNDLE_ID=identifiers["monitor"],
            POMOGEM_AUDIT_TEAM_ID="fixture-team", POMOGEM_AUDIT_MARKETING_VERSION="1.1.0",
            POMOGEM_AUDIT_BUILD_NUMBER="10", POMOGEM_AUDIT_MINIMUM_IOS="17.0")
        return subprocess.run([sys.executable, "-c", source, str(root), str(root / "Info.plist"),
            str(app / "Info.plist"), str(widget / "Info.plist"), str(app / "PrivacyInfo.xcprivacy"),
            str(widget / "PrivacyInfo.xcprivacy"), str(monitor / "Info.plist"),
            str(monitor / "PrivacyInfo.xcprivacy")], env=environment, capture_output=True, check=False)

    def test_current_three_bundle_metadata_passes_actual_archive_validator(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_archive_metadata(Path(directory))
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_wrong_monitor_version_entrypoint_or_privacy_is_rejected(self):
        mutations = [
            lambda values, app, monitor: values[monitor / "Info.plist"].update(CFBundleVersion="9"),
            lambda values, app, monitor: values[monitor / "Info.plist"]["NSExtension"].update(
                NSExtensionPointIdentifier="com.apple.widgetkit-extension"),
            lambda values, app, monitor: values[monitor / "PrivacyInfo.xcprivacy"].update(NSPrivacyTracking=True),
            lambda values, app, monitor: values[monitor / "PrivacyInfo.xcprivacy"].update(
                NSPrivacyCollectedDataTypes=[{"NSPrivacyCollectedDataType": "unexpected"}]),
            lambda values, app, monitor: (app / "PlugIns/Unexpected.appex").mkdir(),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                result = self.run_archive_metadata(Path(directory), mutation=mutation)
                self.assertEqual(result.returncode, 1)
                self.assertIn(b"error:", result.stderr)


class StoreShippingCapabilityTests(unittest.TestCase):
    def check_metadata(self, *, config_mutation=None, source_mutation=None):
        repository = Path(__file__).resolve().parents[1]
        source = (repository / "Scripts/validate-store-metadata.py").read_text()
        module = ast.parse(source)
        functions = [node for node in module.body if isinstance(node, ast.FunctionDef)
                     and node.name in {"yaml_block", "yaml_scalar", "yaml_list"}]
        block = source[source.index('project = (ROOT / "project.yml")'):source.index('\nreview_notes =')]
        config = """marketing_version: "1.1.0"
build_number: "10"
app_groups:
  shared_screen_time: group.com.hinoshiba.pomogem
target_capabilities:
  app:
    - icloud_cloudkit
    - push_notifications
    - in_app_purchase
    - family_controls
    - app_groups
    - time_sensitive_notifications
  widget: []
  screen_time_monitor:
    - family_controls
    - app_groups
"""
        if config_mutation:
            config = config_mutation(config)
        entries = [(len(line) - len(line.lstrip(" ")), line.strip())
                   for line in config.splitlines() if line.strip()]
        def fail(message):
            raise ValueError(message)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "project.yml").write_text('settings:\n  base:\n    MARKETING_VERSION: "1.1.0"\n    CURRENT_PROJECT_VERSION: "10"\n')
            for relative in ("PomoGem/PomoGem.entitlements", "PomoGemWidgets/PomoGemWidgets.entitlements",
                             "PomoGemScreenTimeMonitor/PomoGemScreenTimeMonitor.entitlements"):
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes((repository / relative).read_bytes())
            if source_mutation:
                source_mutation(root)
            namespace = {"ROOT": root, "read_release_version": read_release_version,
                         "configuration_entries": entries, "plistlib": plistlib, "fail": fail}
            exec(compile(ast.Module(body=functions, type_ignores=[]), "metadata-functions", "exec"), namespace)
            exec(compile(block, "shipping-metadata-block", "exec"), namespace)

    def test_current_topology_and_new_source_version_are_accepted(self):
        self.check_metadata()

    def test_mismatched_version_or_unreviewed_target_capabilities_are_rejected(self):
        mutations = [lambda text: text.replace('build_number: "10"', 'build_number: "9"'),
                     lambda text: text.replace("    - time_sensitive_notifications\n", ""),
                     lambda text: text.replace("  widget: []", "  widget:\n    - app_groups"),
                     lambda text: text.replace("  screen_time_monitor:", "  unknown_extension:"),
                     lambda text: text + "    - icloud_cloudkit\n",
                     lambda text: text.replace("group.com.hinoshiba.pomogem", "group.unreviewed")]
        for mutation in mutations:
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.check_metadata(config_mutation=mutation)

    def test_source_monitor_missing_family_controls_and_widget_group_are_rejected(self):
        def mutate(role, key, value):
            def change(root):
                path = root / role
                entitlements = plistlib.loads(path.read_bytes())
                entitlements[key] = value
                path.write_bytes(plistlib.dumps(entitlements))
            return change
        mutations = [mutate("PomoGemScreenTimeMonitor/PomoGemScreenTimeMonitor.entitlements",
                            "com.apple.developer.family-controls", value) for value in (False, 1)]
        mutations.append(mutate("PomoGemWidgets/PomoGemWidgets.entitlements",
                                "com.apple.security.application-groups", ["group.com.hinoshiba.pomogem"]))
        mutations.append(mutate("PomoGemWidgets/PomoGemWidgets.entitlements",
                                "com.apple.developer.usernotifications.time-sensitive", True))
        mutations.append(mutate("PomoGemScreenTimeMonitor/PomoGemScreenTimeMonitor.entitlements",
                                "com.apple.developer.usernotifications.time-sensitive", True))
        mutations += [mutate("PomoGem/PomoGem.entitlements",
                             "com.apple.developer.usernotifications.time-sensitive", value)
                      for value in (False, 1)]
        for mutation in mutations:
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.check_metadata(source_mutation=mutation)

if __name__ == "__main__":
    unittest.main()
