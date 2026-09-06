#!/usr/bin/env python3
"""Regression tests for the public identity and binary mailbox audits."""

from __future__ import annotations

import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
from public_mailbox_policy import APPROVED_PERSONAL_EMAILS, has_unapproved_personal_mailbox

SCRIPTS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("public_git_metadata", SCRIPTS / "check-git-public-metadata.py")
assert SPEC is not None and SPEC.loader is not None
METADATA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METADATA)
APPROVED = next(iter(APPROVED_PERSONAL_EMAILS)).encode("ascii")
OTHER = b"unapproved-person" + b"@" + b"gmail.com"
OID = b"1" * 40


def run_command(arguments: list[str], *, cwd: Path, data: bytes = b"") -> tuple[int, bytes, bytes]:
    environment = os.environ.copy()
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, PYTHONDONTWRITEBYTECODE="1")
    with tempfile.TemporaryFile() as source, tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        source.write(data)
        source.seek(0)
        result = subprocess.run(arguments, cwd=cwd, env=environment, stdin=source,
                                stdout=output, stderr=errors, timeout=30, check=False)
        output.seek(0)
        errors.seek(0)
        return result.returncode, output.read(), errors.read()


class MailboxPolicyTests(unittest.TestCase):
    def test_exact_address_case_and_prose_punctuation(self) -> None:
        for content in (APPROVED, APPROVED.upper(), b"<" + APPROVED + b">",
                        b"Contact " + APPROVED + b". Next sentence.",
                        b"mailto:" + APPROVED + b"?subject=Help"):
            with self.subTest(content=content):
                self.assertFalse(has_unapproved_personal_mailbox(content))

    def test_aliases_prefixes_suffixes_and_embedded_addresses_are_not_approved(self) -> None:
        local, domain = APPROVED.split(b"@")
        for content in (b"other." + APPROVED, local + b"+tag@" + domain,
                        APPROVED + b".example.org", APPROVED + b"_other",
                        b"other@" + APPROVED, APPROVED + b"@example.org",
                        b"other/" + APPROVED, b"!" + APPROVED,
                        "別人".encode() + APPROVED):
            with self.subTest(content=content):
                self.assertTrue(has_unapproved_personal_mailbox(content))

    def test_an_approved_address_does_not_hide_another_on_the_same_line(self) -> None:
        for content in (APPROVED + b" " + OTHER, OTHER + b"; " + APPROVED,
                        b"\0\xff" + APPROVED + b"\0binary\0" + OTHER.upper() + b"\0"):
            self.assertTrue(has_unapproved_personal_mailbox(content))

    def test_all_previously_blocked_provider_families_remain_blocked(self) -> None:
        for domain in (b"gmail.com", b"googlemail.com", b"icloud.com", b"me.com", b"mac.com",
                       b"outlook.com", b"hotmail.com", b"live.com", b"yahoo.com",
                       b"yahoo.co.jp", b"proton.com", b"protonmail.com"):
            self.assertTrue(has_unapproved_personal_mailbox(b"person" + b"@" + domain))

    def test_binary_safe_and_large_nonmatching_content(self) -> None:
        self.assertFalse(has_unapproved_personal_mailbox(b"\0\xff\0" + APPROVED + b"\0\xfe"))
        self.assertFalse(has_unapproved_personal_mailbox(b"a" * 2_000_000))
        self.assertTrue(has_unapproved_personal_mailbox(b"a" * 2_000_000 + APPROVED))

    def test_utf16_mailboxes_are_checked_even_inside_a_binary_history_batch(self) -> None:
        for encoding, bom in (("utf-16-le", b"\xff\xfe"), ("utf-16-be", b"\xfe\xff")):
            approved = bom + (APPROVED.decode() + "\n").encode(encoding)
            rejected = bom + (OTHER.decode() + "\n").encode(encoding)
            for prefix in (b"", b"0123456789 blob 100\n"):
                self.assertFalse(has_unapproved_personal_mailbox(prefix + approved))
                self.assertTrue(has_unapproved_personal_mailbox(prefix + rejected))
            for text in ("other." + APPROVED.decode(), APPROVED.decode() + ".example.org",
                         APPROVED.decode() + " " + OTHER.decode()):
                self.assertTrue(has_unapproved_personal_mailbox(bom + text.encode(encoding)))


class GitIdentityTests(unittest.TestCase):
    def identity(self, email: bytes = APPROVED, kind: bytes = b"author") -> bytes:
        return kind + b" Maintainer <" + email + b"> 1788000000 +0900"

    def test_only_complete_approved_metadata_identities_pass(self) -> None:
        for email in METADATA.ALLOWED_EMAILS:
            self.assertEqual(METADATA.validate_identity(OID, b"commit", self.identity(email.encode())), "")
        self.assertEqual(METADATA.validate_identity(OID, b"commit", self.identity(APPROVED.upper())), "")
        for email in (OTHER, b"other." + APPROVED, APPROVED + b".invalid", b" " + APPROVED,
                      b"someone" + b"@" + b"example.org"):
            self.assertTrue(METADATA.validate_identity(OID, b"commit", self.identity(email)))

    def test_malformed_identity_fields_are_rejected(self) -> None:
        valid = self.identity()
        for line in (valid.replace(b"Maintainer", b" "), valid.replace(b"Maintainer", b"Bad\x0bName"),
                     valid.replace(b"+0900", b"+2460"), valid.replace(b"1788000000", b"not-a-date"),
                     valid.replace(b"author ", b"author\t"), valid.replace(b">", b""),
                     self.identity(APPROVED + b"\0")):
            self.assertTrue(METADATA.validate_identity(OID, b"commit", line))

    def test_raw_commit_and_tag_headers_require_valid_identities(self) -> None:
        author = self.identity()
        committer = self.identity(kind=b"committer")
        for object_type, raw in (
            (b"commit", author + b"\n\nmissing committer"),
            (b"commit", author + b"\n" + author + b"\n" + committer + b"\n\nduplicate"),
            (b"tag", self.identity(kind=b"tagger").replace(b"tagger ", b"tagger\t") + b"\n\nmalformed"),
            (b"tag", self.identity(kind=b"tagger") + b"\n" + self.identity(kind=b"tagger") + b"\n\nduplicate"),
        ):
            with mock.patch.object(METADATA, "git", return_value=raw):
                self.assertTrue(METADATA.validate_object(OID, object_type))

    def test_incomplete_missing_and_unknown_object_inventories_fail_closed(self) -> None:
        for output in (b"", OID + b" missing\n", OID + b" mystery\n", b"not-an-id commit\n"):
            with mock.patch.object(METADATA, "git", return_value=output), self.assertRaises(SystemExit):
                METADATA.object_types([OID])


class ScannerIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="public-metadata-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def command(self, *arguments: str, data: bytes = b"") -> tuple[int, bytes, bytes]:
        return run_command(list(arguments), cwd=self.directory, data=data)

    def git(self, *arguments: str, data: bytes = b"") -> bytes:
        status, output, errors = self.command("git", *arguments, data=data)
        self.assertEqual(status, 0, errors.decode(errors="replace"))
        return output if arguments[:2] == ("cat-file", "--batch") else output.strip()

    def test_file_inventory_scans_binary_files_and_fails_on_unreadable_paths(self) -> None:
        file = self.directory / "candidate.bin"
        inventory = self.directory / "inventory"
        inventory.write_bytes(os.fsencode(file) + b"\0")
        file.write_bytes(b"\0" + APPROVED + b"\0")
        command = (sys.executable, str(SCRIPTS / "public_mailbox_policy.py"), "--files0-from", str(inventory))
        self.assertEqual(self.command(*command)[0], 0)
        file.write_bytes(file.read_bytes() + OTHER)
        self.assertNotEqual(self.command(*command)[0], 0)
        file.unlink()
        self.assertNotEqual(self.command(*command)[0], 0)
        for malformed in (b"", b"\0", b"missing-final-NUL"):
            inventory.write_bytes(malformed)
            self.assertNotEqual(self.command(*command)[0], 0)

    def test_raw_git_batch_covers_commit_tag_and_binary_blob_contents(self) -> None:
        self.git("init", "--quiet")
        tree = self.git("mktree")
        identity = b" Maintainer <" + APPROVED + b"> 1788000000 +0900"
        commit = self.git("hash-object", "-w", "-t", "commit", "--stdin", data=
                          b"tree " + tree + b"\nauthor" + identity + b"\ncommitter" + identity + b"\n\napproved\n")
        tag = self.git("hash-object", "-w", "-t", "tag", "--stdin", data=
                       b"object " + commit + b"\ntype commit\ntag release\ntagger" + identity + b"\n\n" + APPROVED + b"\n")
        good_blob = self.git("hash-object", "-w", "--stdin", data=b"\0binary\0" + APPROVED + b"\0")
        inventory = self.directory / "objects"
        inventory.write_bytes(b"\n".join((commit, tag, good_blob)) + b"\n")
        check = (sys.executable, str(SCRIPTS / "check-git-public-metadata.py"), str(inventory))
        self.assertEqual(self.command(*check)[0], 0)
        batch = self.directory / "batch"
        batch.write_bytes(self.git("cat-file", "--batch", data=inventory.read_bytes()))
        scan = (sys.executable, str(SCRIPTS / "public_mailbox_policy.py"), "--git-batch", str(batch))
        self.assertEqual(self.command(*scan)[0], 0)
        for encoding, bom in (("utf-16-le", b"\xff\xfe"), ("utf-16-be", b"\xfe\xff")):
            encoded_blob = self.git("hash-object", "-w", "--stdin", data=bom + APPROVED.decode().encode(encoding))
            inventory.write_bytes(inventory.read_bytes() + encoded_blob + b"\n")
        batch.write_bytes(self.git("cat-file", "--batch", data=inventory.read_bytes()) + b"refs/heads/main\n")
        self.assertEqual(self.command(*scan)[0], 0)
        approved_inventory = inventory.read_bytes()
        bad_objects = [
            self.git("hash-object", "-w", "--stdin", data=b"\0" + APPROVED + b"\0" + OTHER + b"\0"),
            self.git("hash-object", "-w", "-t", "commit", "--stdin", data=
                     b"tree " + tree + b"\nauthor" + identity + b"\ncommitter" + identity + b"\n\n" + OTHER + b"\n"),
            self.git("hash-object", "-w", "-t", "tag", "--stdin", data=
                     b"object " + commit + b"\ntype commit\ntag private-message\ntagger" + identity + b"\n\n" + OTHER + b"\n"),
        ]
        for encoding, bom in (("utf-16-le", b"\xff\xfe"), ("utf-16-be", b"\xfe\xff")):
            bad_objects.append(self.git("hash-object", "-w", "--stdin", data=bom + OTHER.decode().encode(encoding)))
        for bad_object in bad_objects:
            inventory.write_bytes(approved_inventory + bad_object + b"\n")
            batch.write_bytes(self.git("cat-file", "--batch", data=inventory.read_bytes()))
            self.assertNotEqual(self.command(*scan)[0], 0)
        batch.write_bytes(self.git("cat-file", "--batch", data=approved_inventory) + b"refs/heads/" + OTHER + b"\n")
        self.assertNotEqual(self.command(*scan)[0], 0)
        for malformed in (b"invalid\n", OID + b" blob 100\nshort\n", b"refs/heads/main\nnot-a-ref\n"):
            batch.write_bytes(malformed)
            self.assertNotEqual(self.command(*scan)[0], 0)
        malformed_tag = self.git("hash-object", "--literally", "-w", "-t", "tag", "--stdin", data=
                                 b"object " + commit + b"\ntype commit\ntag invalid\ntagger\tBad <" + APPROVED + b"> 1 +0000\n\ninvalid\n")
        inventory.write_bytes(malformed_tag + b"\n")
        self.assertNotEqual(self.command(*check)[0], 0)

    def test_approved_email_does_not_exempt_credentials_from_existing_regex(self) -> None:
        shell = (SCRIPTS / "check-oss-readiness.sh").read_text()
        match = re.search(r"^credential_value_pattern='([^']+)'$", shell, re.MULTILINE)
        self.assertIsNotNone(match)
        assert match is not None
        file = self.directory / "candidate"
        file.write_bytes(APPROVED + b" " + b"ghp_" + b"A" * 30)
        status, _, _ = self.command("rg", "-a", "-q", "--", match.group(1), str(file))
        self.assertEqual(status, 0)
        file.write_bytes(APPROVED + b" " + b"PRIVATE " + b"KEY-----")
        status, _, _ = self.command("rg", "-a", "-q", "-F", "--", "PRIVATE " + "KEY-----", str(file))
        self.assertEqual(status, 0)


if __name__ == "__main__":
    unittest.main()
