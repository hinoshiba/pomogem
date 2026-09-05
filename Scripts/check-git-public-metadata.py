#!/usr/bin/env python3
"""Fail when reachable raw Git identity metadata uses an unapproved email."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


# Keep this narrow and explicit. The support mailbox is approved for public
# disclosure, but maintainers should normally author commits with the GitHub
# noreply identity so repository history represents the actual GitHub account.
ALLOWED_EMAILS = frozenset(
    {
        "29009074+hinoshiba@users.noreply.github.com",
        "support@hinoshiba.com",
    }
)
OBJECT_ID = re.compile(rb"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
IDENTITY = re.compile(
    rb"(author|committer|tagger) ([^<>\x00\r\n]+) <([^<>\x00\r\n]+)> "
    rb"([0-9]+) ([+-])([0-9]{2})([0-9]{2})\Z"
)


def git(*arguments: str, input_bytes: bytes | None = None) -> bytes:
    try:
        result = subprocess.run(
            ["git", "--no-replace-objects", *arguments],
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        raise SystemExit(f"error: cannot execute Git metadata audit: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "backslashreplace").strip()
        raise SystemExit(f"error: Git metadata audit command failed: {detail!r}")
    return result.stdout


def load_object_ids(path: Path) -> list[bytes]:
    try:
        lines = path.read_bytes().splitlines()
    except OSError as error:
        raise SystemExit(f"error: cannot read Git object inventory: {error}") from error
    if not lines:
        raise SystemExit("error: Git object inventory is empty")
    invalid = next((line for line in lines if OBJECT_ID.fullmatch(line) is None), None)
    if invalid is not None:
        rendered = invalid.decode("ascii", "backslashreplace")
        raise SystemExit(f"error: malformed object ID in Git inventory: {rendered!r}")
    return lines


def object_types(object_ids: list[bytes]) -> dict[bytes, bytes]:
    output = git(
        "cat-file",
        "--batch-check=%(objectname) %(objecttype)",
        input_bytes=b"\n".join(object_ids) + b"\n",
    )
    result: dict[bytes, bytes] = {}
    for line in output.splitlines():
        fields = line.split(b" ", 1)
        if len(fields) != 2 or OBJECT_ID.fullmatch(fields[0]) is None:
            rendered = line.decode("ascii", "backslashreplace")
            raise SystemExit(f"error: malformed Git object inspection output: {rendered!r}")
        object_id, object_type = fields
        if object_type == b"missing":
            raise SystemExit(
                f"error: reachable Git object is missing: {object_id.decode('ascii')}"
            )
        result[object_id] = object_type
    if set(result) != set(object_ids):
        raise SystemExit("error: Git object inspection returned an incomplete inventory")
    return result


def validate_identity(object_id: bytes, object_type: bytes, line: bytes) -> str:
    match = IDENTITY.fullmatch(line)
    oid = object_id.decode("ascii")
    if match is None:
        rendered = line.decode("utf-8", "backslashreplace")
        return f"{oid} has malformed {object_type.decode('ascii')} identity: {rendered!r}"

    kind, name, email_bytes, _timestamp, _sign, hours, minutes = match.groups()
    if not name.strip() or int(hours) > 23 or int(minutes) > 59:
        rendered = line.decode("utf-8", "backslashreplace")
        return f"{oid} has malformed {object_type.decode('ascii')} identity: {rendered!r}"
    try:
        email = email_bytes.decode("ascii")
    except UnicodeDecodeError:
        return f"{oid} {kind.decode('ascii')} email is not ASCII"
    if email.casefold() not in ALLOWED_EMAILS:
        return f"{oid} {kind.decode('ascii')} email is not approved: {email!r}"
    return ""


def validate_object(object_id: bytes, object_type: bytes) -> list[str]:
    raw = git("cat-file", object_type.decode("ascii"), object_id.decode("ascii"))
    headers, separator, _message = raw.partition(b"\n\n")
    oid = object_id.decode("ascii")
    if not separator:
        return [f"{oid} has malformed {object_type.decode('ascii')} headers"]

    expected = {b"author": 1, b"committer": 1} if object_type == b"commit" else {b"tagger": 0}
    counts = dict.fromkeys(expected, 0)
    errors: list[str] = []
    for line in headers.splitlines():
        kind = line.split(b" ", 1)[0]
        if kind not in expected:
            continue
        counts[kind] += 1
        error = validate_identity(object_id, object_type, line)
        if error:
            errors.append(error)

    if object_type == b"commit":
        for kind, count in counts.items():
            if count != 1:
                errors.append(
                    f"{oid} commit must contain exactly one {kind.decode('ascii')} identity; found {count}"
                )
    elif counts[b"tagger"] > 1:
        errors.append(f"{oid} tag contains duplicate tagger identities")
    # A tagger header is optional in Git's tag-object format. When present, it
    # must be well formed and approved; lightweight tags have no tag object.
    return errors


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"error: usage: {sys.argv[0]} OBJECT_ID_FILE")
    object_ids = load_object_ids(Path(sys.argv[1]))
    types = object_types(object_ids)
    errors: list[str] = []
    for object_id in object_ids:
        object_type = types[object_id]
        if object_type in (b"commit", b"tag"):
            errors.extend(validate_object(object_id, object_type))
            if len(errors) >= 40:
                break
    if errors:
        print(
            "error: unapproved or malformed email exists in reachable raw Git commit/tag metadata",
            file=sys.stderr,
        )
        for error in errors[:40]:
            print(error, file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
