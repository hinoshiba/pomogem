"""Minimal Swift lexer used by Scripts/l10n/l10n.py.

It is deliberately small: it only needs to find string literals, blank out
comments and literal contents, and keep interpolation code visible, so that
the localization lint can look at the call around each literal without being
fooled by brackets or keywords inside strings and comments.

`lex(source)` returns `(literals, masked)`:

* `literals` is a list of dicts with `start`, `end` (source offsets of the
  whole literal, including quotes and raw-string hashes), `content_start`,
  `text` (the literal with `\\(...)` interpolations kept for display),
  `plain` (only the literal pieces, interpolations removed), `multiline`,
  `raw_hashes`, `interpolated`, `interp_count` and `depth` (> 0 for a literal
  nested inside another literal's interpolation).
* `masked` is the source with comments and literal contents replaced by
  spaces. Quotes, newlines and interpolation code are kept, so offsets and
  line numbers stay identical to the original source.
"""


class Lexer:
    def __init__(self, source):
        self.s = source
        self.n = len(source)
        self.masked = list(source)
        self.literals = []

    def blank(self, start, end):
        for index in range(start, end):
            if self.masked[index] != "\n":
                self.masked[index] = " "

    def run(self):
        self.code(0, depth=0, stop_on_close_paren=False)
        return self

    def code(self, i, depth, stop_on_close_paren):
        """Scan code from `i`.

        With `stop_on_close_paren`, stop at the unmatched `)` that closes an
        interpolation and return its index.
        """
        s, n = self.s, self.n
        paren = 0
        while i < n:
            c = s[i]
            if c == "/" and i + 1 < n and s[i + 1] == "/":
                j = s.find("\n", i)
                j = n if j == -1 else j
                self.blank(i, j)
                i = j
                continue
            if c == "/" and i + 1 < n and s[i + 1] == "*":
                j = self.block_comment(i)
                self.blank(i, j)
                i = j
                continue
            if c == "#" or c == '"':
                k = i
                hashes = 0
                while k < n and s[k] == "#":
                    hashes += 1
                    k += 1
                if k < n and s[k] == '"':
                    i = self.string(i, k, hashes, depth)
                    continue
                i += 1
                continue
            if c == "(":
                paren += 1
            elif c == ")":
                if paren == 0 and stop_on_close_paren:
                    return i
                paren -= 1
            i += 1
        return i

    def block_comment(self, i):
        s, n = self.s, self.n
        level = 0
        while i < n:
            if s.startswith("/*", i):
                level += 1
                i += 2
                continue
            if s.startswith("*/", i):
                level -= 1
                i += 2
                if level == 0:
                    return i
                continue
            i += 1
        return n

    def string(self, start, quote, hashes, depth):
        """Lex one literal; `start` is its first `#` or quote, `quote` its first quote."""
        s, n = self.s, self.n
        multiline = s.startswith('"""', quote)
        if multiline:
            content_start = quote + 3
            closing = '"""' + "#" * hashes
        else:
            content_start = quote + 1
            closing = '"' + "#" * hashes
        escape = "\\" + "#" * hashes
        i = content_start
        pieces = []
        interpolations = []
        segment_start = i
        end = n
        while i < n:
            if s.startswith(escape, i):
                j = i + len(escape)
                if j < n and s[j] == "(":
                    pieces.append((segment_start, i))
                    close = self.code(j + 1, depth + 1, stop_on_close_paren=True)
                    interpolations.append((j + 1, close))
                    i = close + 1
                    segment_start = i
                    continue
                i = j + 1
                continue
            if s.startswith(closing, i):
                pieces.append((segment_start, i))
                end = i + len(closing)
                break
            if not multiline and s[i] == "\n":
                pieces.append((segment_start, i))
                end = i
                break
            i += 1
        else:
            pieces.append((segment_start, n))
        for piece_start, piece_end in pieces:
            self.blank(piece_start, piece_end)
        text = []
        for index, (piece_start, piece_end) in enumerate(pieces):
            text.append(s[piece_start:piece_end])
            if index < len(interpolations):
                code_start, code_end = interpolations[index]
                text.append("\\(" + s[code_start:code_end] + ")")
        self.literals.append({
            "start": start,
            "end": end,
            "content_start": content_start,
            "text": "".join(text),
            "plain": "".join(s[a:b] for a, b in pieces),
            "multiline": multiline,
            "raw_hashes": hashes,
            "interpolated": bool(interpolations),
            "interp_count": len(interpolations),
            "depth": depth,
        })
        return end


def lex(source):
    lexer = Lexer(source).run()
    return lexer.literals, "".join(lexer.masked)
