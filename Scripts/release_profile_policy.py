"""Pure provisioning-profile checks shared by the archive audit and its tests."""

from __future__ import annotations


def validate_profile_cloud_environment(value: object, expected: str) -> None:
    """Require the signed environment in the profile's known-value allowlist.

    Profile entitlements authorize claims; they need not equal the app's
    narrower signed entitlement. See Apple's TN3125, "The how":
    https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
    """
    known_environments = {"Development", "Production"}
    if isinstance(value, str):
        environments = {value}
    elif isinstance(value, list) and value and all(isinstance(item, str) for item in value):
        environments = set(value)
    else:
        raise ValueError("profile CloudKit environment authorization is malformed")

    if expected not in environments or not environments.issubset(known_environments):
        raise ValueError("profile CloudKit environment does not authorize the required environment")


def read_release_version(project_source: str) -> tuple[str, str]:
    """Read literal global XcodeGen versions, refusing overrides or interpolation."""
    import re

    values = []
    for key, pattern in (("MARKETING_VERSION", r"[0-9]+\.[0-9]+(?:\.[0-9]+)?"),
                         ("CURRENT_PROJECT_VERSION", r"[1-9][0-9]*")):
        declarations = re.findall(rf"^[ \t]*{key}:.*$", project_source, re.MULTILINE)
        if len(declarations) != 1:
            raise ValueError("release version must have one global literal declaration per field")
        match = re.fullmatch(rf'    {key}: "({pattern})"\s*', declarations[0])
        if match is None:
            raise ValueError("release version must use the reviewed global numeric format")
        values.append(match.group(1))
    return values[0], values[1]


def validate_bundle_capability_allowlist(
    entitlements: dict,
    *,
    role: str,
    team_id: str,
    bundle_id: str,
    app_group: str,
    is_profile: bool,
) -> None:
    """Keep Family Controls and the shared ledger exclusive to app + monitor.

    Time Sensitive notifications are exclusive to, and required by, the app:
    only its timer-end alerts use that interruption level, and without the
    entitlement iOS silently downgrades them under Focus/Do Not Disturb.
    CloudKit/APNs values are additionally checked by the archive verifier;
    profile authorizations may be broader than signed CloudKit claims.
    """
    if role not in {"app", "widget", "monitor"}:
        raise ValueError("unknown release bundle role")
    common = {
        "application-identifier", "com.apple.developer.team-identifier",
        "get-task-allow", "keychain-access-groups", "beta-reports-active",
    }
    screen_time = {"com.apple.developer.family-controls", "com.apple.security.application-groups"}
    cloud = {
        "aps-environment", "com.apple.developer.icloud-container-identifiers",
        "com.apple.developer.icloud-container-development-container-identifiers",
        "com.apple.developer.icloud-services", "com.apple.developer.icloud-container-environment",
    }
    time_sensitive = "com.apple.developer.usernotifications.time-sensitive"
    allowed = set(common)
    if role in {"app", "monitor"}:
        allowed |= screen_time
        if entitlements.get("com.apple.developer.family-controls") is not True:
            raise ValueError("Family Controls authorization is missing or malformed")
        if entitlements.get("com.apple.security.application-groups") != [app_group]:
            raise ValueError("App Group differs from the reviewed shared ledger")
    if role == "app":
        allowed |= cloud | {time_sensitive}
        if entitlements.get(time_sensitive) is not True:
            raise ValueError("Time Sensitive notification authorization is missing or malformed")
        if is_profile:
            allowed |= {"com.apple.developer.ubiquity-container-identifiers",
                        "com.apple.developer.ubiquity-kvstore-identifier"}
    if set(entitlements) - allowed:
        raise ValueError("entitlement keys differ from the reviewed bundle capability allowlist")
    if "keychain-access-groups" in entitlements:
        expected = [[f"{team_id}.{bundle_id}"]]
        if is_profile:
            expected.append([f"{team_id}.*"])
        if entitlements["keychain-access-groups"] not in expected:
            raise ValueError("keychain access differs from the reviewed bundle authorization")
    if "beta-reports-active" in entitlements and entitlements["beta-reports-active"] is not True:
        raise ValueError("beta reporting authorization is malformed")


def validate_archive_signing_classes(
    bundles: dict[str, tuple[str, bool, str | None]], *, distribution: bool
) -> None:
    """Every embedded product must use the same approved provisioning class."""
    if set(bundles) != {"app", "widget", "monitor"}:
        raise ValueError("archive must validate app, Widget, and Screen Time monitor signing")
    app_kind, app_task_allow, app_cloud = bundles["app"]
    for role in ("widget", "monitor"):
        kind, task_allow, cloud = bundles[role]
        if (kind, task_allow) != (app_kind, app_task_allow):
            raise ValueError("app and extension signing/profile environments differ")
        if cloud is not None:
            raise ValueError("extension unexpectedly selected a CloudKit environment")
    if distribution and (app_kind != "app-store-connect" or app_task_allow is not False
                         or app_cloud != "Production"):
        raise ValueError("distribution requires App Store profiles and production CloudKit")
