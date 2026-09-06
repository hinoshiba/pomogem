#!/usr/bin/env python3
"""Scan text and binary content for personal mailboxes not approved for publication."""

from __future__ import annotations

import argparse
import bisect
import mmap
import os
import re
import sys
from pathlib import Path


# The repository owner explicitly approved this complete address for public
# authorship. This does not approve other addresses at the same provider.
APPROVED_PERSONAL_EMAILS = frozenset({"kai.openclaw01@gmail.com"})
PRIVATE_DOMAIN = re.compile(
    rb"@(?:gmail\.com|googlemail\.com|icloud\.com|me\.com|mac\.com|"
    rb"outlook\.com|hotmail\.com|live\.com|yahoo\.[a-z.]+|proton(?:mail)?\.com)",
    re.IGNORECASE,
)
LOCAL_BYTES = frozenset(b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+/=?^_`{|}~-")
DOMAIN_BYTES = frozenset(b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._%+-")


def wide_private_domains(encoding: str) -> re.Pattern[bytes]:
    domains = ("gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com",
               "outlook.com", "hotmail.com", "live.com", "proton.com", "protonmail.com")
    patterns = [re.escape(("@" + domain).encode(encoding)) for domain in domains]
    yahoo_suffix = rb"(?:[a-z.]\x00)+" if encoding == "utf-16-le" else rb"(?:\x00[a-z.])+"
    patterns.append(re.escape("@yahoo.".encode(encoding)) + yahoo_suffix)
    return re.compile(b"|".join(patterns), re.IGNORECASE)


MAILBOX_ENCODINGS = (
    (PRIVATE_DOMAIN, 1, "little", "ascii"),
    (wide_private_domains("utf-16-le"), 2, "little", "utf-16-le"),
    (wide_private_domains("utf-16-be"), 2, "big", "utf-16-be"),
)
BOM = re.compile(rb"\xff\xfe|\xfe\xff")
BATCH_HEADER = re.compile(rb"(?:[0-9a-f]{40}|[0-9a-f]{64}) (?:blob|tree|commit|tag) ([0-9]+)\Z")


def has_unapproved_personal_mailbox(content: bytes | mmap.mmap | memoryview) -> bool:
    # Keep rg's former UTF-16 coverage, including encoded blobs embedded inside
    # a raw Git batch stream, without decoding or copying the entire history.
    markers = [(match.start(), match.group()) for match in BOM.finditer(content)]
    positions = [position for position, _ in markers]
    return any(_has_unapproved_mailbox(content, *encoding, markers, positions) for encoding in MAILBOX_ENCODINGS)


def _has_unapproved_mailbox(
    content: bytes | mmap.mmap | memoryview, pattern: re.Pattern[bytes], width: int,
    byteorder: str, encoding: str, markers: list[tuple[int, bytes]], positions: list[int],
) -> bool:
    def character(index: int) -> int:
        return content[index] if width == 1 else int.from_bytes(content[index:index + width], byteorder)

    approved_addresses = {address.encode(encoding) for address in APPROVED_PERSONAL_EMAILS}
    # Find domains first, then inspect the complete surrounding mailbox. This
    # avoids both substring allowlisting and a backtracking scan of large
    # binary objects containing long runs of characters without an @ sign.
    for match in pattern.finditer(content):
        if width == 2:
            marker_index = bisect.bisect_right(positions, match.start()) - 1
            if marker_index < 0:
                continue
            offset, marker = markers[marker_index]
            expected_marker = b"\xff\xfe" if byteorder == "little" else b"\xfe\xff"
            if marker != expected_marker or (match.start() - offset) % 2:
                continue
        start = match.start()
        while start >= width:
            previous = character(start - width)
            if previous not in LOCAL_BYTES and not (previous >= 128 and previous != 0xFEFF):
                break
            start -= width
        if width == 1 and content[start:start + 3] == b"\xef\xbb\xbf":
            start += 3
        if start == match.start():
            continue  # A provider name without a local part is not a mailbox.
        end = match.end()
        while end + width <= len(content):
            following = character(end)
            if following not in DOMAIN_BYTES and not (following >= 128 and following != 0xFEFF):
                break
            end += width
        # A sentence's final full stop is punctuation, not a domain suffix.
        mailbox_end = end
        while mailbox_end > match.end() and character(mailbox_end - width) == ord("."):
            mailbox_end -= width
        if (start >= width and character(start - width) == ord("@")) or (end + width <= len(content) and character(end) == ord("@")):
            return True
        length = mailbox_end - start
        if not any(len(address) == length for address in approved_addresses):
            return True
        if bytes(content[start:mailbox_end]).lower() not in approved_addresses:
            return True
    return False


def scan_git_batch(content: mmap.mmap) -> bool:
    # cat-file separates binary payloads using their declared byte count, not
    # newlines. Respect that boundary before decoding an encoded mailbox; the
    # following object's ASCII header is not part of a UTF-16 document.
    offset = 0
    while offset < len(content):
        newline = content.find(b"\n", offset)
        if newline < 0:
            raise ValueError("unterminated Git batch header")
        header = content[offset:newline]
        match = BATCH_HEADER.fullmatch(header)
        if match is None:
            # The shell appends public ref names after the raw batch.
            if not header.startswith(b"refs/"):
                raise ValueError("malformed Git batch header")
            refs = content[offset:]
            if any(not ref.startswith(b"refs/") for ref in refs.splitlines()):
                raise ValueError("malformed Git ref inventory after batch")
            return has_unapproved_personal_mailbox(refs)
        start = newline + 1
        end = start + int(match.group(1))
        if end >= len(content) or content[end] != ord("\n"):
            raise ValueError("truncated or malformed Git batch object")
        with memoryview(content)[start:end] as payload:
            if has_unapproved_personal_mailbox(payload):
                return True
        offset = end + 1
    return False


def scan_file(path: Path, *, git_batch: bool = False) -> bool:
    with path.open("rb") as handle:
        if os.fstat(handle.fileno()).st_size == 0:
            return False
        with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as content:
            return scan_git_batch(content) if git_batch else has_unapproved_personal_mailbox(content)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--file", type=Path)
    source.add_argument("--git-batch", type=Path)
    source.add_argument("--files0-from", type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.file is not None or arguments.git_batch is not None:
            paths = [arguments.file or arguments.git_batch]
        else:
            inventory = arguments.files0_from.read_bytes()
            if not inventory:
                raise ValueError("file inventory is empty")
            if not inventory.endswith(b"\0"):
                raise ValueError("file inventory must end with a NUL separator")
            raw_paths = inventory[:-1].split(b"\0")
            if not all(raw_paths):
                raise ValueError("file inventory contains an empty path")
            paths = [Path(os.fsdecode(raw)) for raw in raw_paths]
        found = False
        for path in paths:
            if scan_file(path, git_batch=arguments.git_batch is not None):
                print(f"error: unapproved personal mailbox in {os.fspath(path)!r}", file=sys.stderr)
                found = True
        if found:
            raise SystemExit(1)
    except (OSError, ValueError) as error:
        raise SystemExit(f"error: personal mailbox audit could not complete: {error}") from error


if __name__ == "__main__":
    main()
