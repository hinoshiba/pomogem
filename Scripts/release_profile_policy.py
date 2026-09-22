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
