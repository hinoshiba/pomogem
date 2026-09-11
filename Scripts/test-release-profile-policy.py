#!/usr/bin/env python3
"""Regressions for CloudKit authorization in the actual archive verifier."""

from __future__ import annotations

import ast
import re
import sys
import unittest
from pathlib import Path
from typing import Optional

sys.dont_write_bytecode = True
from release_profile_policy import validate_profile_cloud_environment


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


if __name__ == "__main__":
    unittest.main()
