#!/usr/bin/env python3
"""Check raw Git identities for malformed or unapproved personal mailboxes."""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
from public_mailbox_policy import has_unapproved_personal_mailbox


# Contributors keep their own public identity. Personal-provider addresses use
# the same exact approval policy as file contents; GitHub noreply is an option
# for contributors who do not want to publish a personal mailbox.
EMAIL_ATOM = rb"[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+"
DOMAIN_LABEL = rb"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
PUBLIC_EMAIL = re.compile(
    EMAIL_ATOM + rb"(?:\." + EMAIL_ATOM + rb")*@"
    + DOMAIN_LABEL + rb"(?:\." + DOMAIN_LABEL + rb")+\Z"
)
GITHUB_BOT_EMAIL = re.compile(
    rb"(?:[0-9]+\+)?[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?"
    rb"\[bot\]@users\.noreply\.github\.com\Z", re.IGNORECASE,
)
OBJECT_ID = re.compile(rb"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
IDENTITY = re.compile(
    rb"(author|committer|tagger) ([^<>\x00-\x1f\x7f]+) <([^<>\x00-\x1f\x7f]+)> "
    rb"([0-9]+) ([+-])([0-9]{2})([0-9]{2})\Z"
)


def git(*arguments: str, input_bytes: bytes | None = None) -> bytes:
    try:
        # A batch inventory can exceed pipe capacity. Regular temporary files
        # also keep the audit usable on hosts with exhausted pipe resources.
        with tempfile.TemporaryFile() as source, tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            if input_bytes is not None:
                source.write(input_bytes)
                source.seek(0)
            result = subprocess.run(
                ["git", "--no-replace-objects", *arguments],
                stdin=source,
                stdout=output,
                stderr=errors,
                check=False,
                timeout=120,
            )
            output.seek(0)
            errors.seek(0)
            stdout = output.read()
            stderr = errors.read()
    except subprocess.TimeoutExpired as error:
        raise SystemExit("error: Git metadata audit command timed out") from error
    except OSError as error:
        raise SystemExit(f"error: cannot execute Git metadata audit: {error}") from error
    if result.returncode != 0:
        detail = stderr.decode("utf-8", "backslashreplace").strip()
        raise SystemExit(f"error: Git metadata audit command failed: {detail!r}")
    return stdout


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
        if object_type not in (b"commit", b"tag", b"tree", b"blob"):
            raise SystemExit("error: Git object inspection returned an unknown object type")
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
    if (len(email_bytes) > 254 or len(email_bytes.split(b"@", 1)[0]) > 64
            or not (PUBLIC_EMAIL.fullmatch(email_bytes) or GITHUB_BOT_EMAIL.fullmatch(email_bytes))):
        return f"{oid} {kind.decode('ascii')} email is malformed"
    if has_unapproved_personal_mailbox(email_bytes):
        return (f"{oid} {kind.decode('ascii')} personal email is not approved; "
                "use a GitHub noreply address or obtain publication approval")
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
    for line in headers.split(b"\n"):
        kind = re.split(rb"\s+", line, maxsplit=1)[0]
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
