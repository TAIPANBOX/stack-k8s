"""A small YAML reader for the shape this repository's manifests are written in.

The gates run on a Mac's stock python3 and on a CI runner with nothing installed, so PyYAML is not
there to import. This reads what the manifests use: block mappings and sequences by indentation,
flow mappings and sequences (`{ a: b, c: [1, 2] }`) on one line or over several, block scalars
(`|`, `|-`, `>`), single- and double-quoted scalars, comments, and documents split by `---`.
Anchors, tags, multi-line plain scalars and complex keys are NOT read, and a document that uses one
raises ValueError rather than being misread. Integers become int; true/false become bool.
"""
import re


class _Flow:
    def __init__(self, text):
        self.s = text
        self.i = 0

    def ws(self):
        while self.i < len(self.s) and self.s[self.i] in " \t\n":
            self.i += 1

    def value(self):
        self.ws()
        c = self.s[self.i]
        if c == "{":
            return self.mapping()
        if c == "[":
            return self.sequence()
        return self.scalar(",]}")

    def mapping(self):
        out = {}
        self.i += 1
        while True:
            self.ws()
            if self.s[self.i] == "}":
                self.i += 1
                return out
            key = self.scalar(":,}")
            self.ws()
            if self.s[self.i] != ":":
                raise ValueError("flow mapping key without a value: " + str(key))
            self.i += 1
            out[key] = self.value()
            self.ws()
            if self.s[self.i] == ",":
                self.i += 1

    def sequence(self):
        out = []
        self.i += 1
        while True:
            self.ws()
            if self.s[self.i] == "]":
                self.i += 1
                return out
            out.append(self.value())
            self.ws()
            if self.s[self.i] == ",":
                self.i += 1

    def scalar(self, stops):
        self.ws()
        c = self.s[self.i]
        if c in "\"'":
            j = self.i + 1
            buf = []
            while True:
                if self.s[j] == "\\" and c == '"':
                    buf.append(self.s[j:j + 2])
                    j += 2
                    continue
                if self.s[j] == c:
                    if c == "'" and j + 1 < len(self.s) and self.s[j + 1] == "'":
                        buf.append("'")
                        j += 2
                        continue
                    break
                buf.append(self.s[j])
                j += 1
            self.i = j + 1
            raw = "".join(buf)
            return _unescape(raw) if c == '"' else raw
        j = self.i
        while j < len(self.s) and self.s[j] not in stops:
            if self.s[j] == ":" and ":" in stops and (j + 1 >= len(self.s) or self.s[j + 1] in " \t\n"):
                break
            j += 1
        tok = self.s[self.i:j].strip()
        self.i = j
        return _plain(tok)


def _unescape(raw):
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "/": "/"}.get(m.group(1), "\\" + m.group(1)), raw)


def _plain(tok):
    if tok == "" or tok in ("null", "~"):
        return None
    if tok in ("true", "True"):
        return True
    if tok in ("false", "False"):
        return False
    if re.fullmatch(r"0[0-7]+", tok):
        return int(tok, 8)
    if re.fullmatch(r"-?\d+", tok):
        return int(tok)
    if tok[:1] in "&*!" or tok.startswith("<<"):
        raise ValueError("anchors, aliases and tags are not read: " + tok)
    return tok


def _strip_comment(line):
    q = None
    for i, ch in enumerate(line):
        if q:
            if ch == q:
                q = None
        elif ch in "\"'" and (i == 0 or line[i - 1] in " \t[{,:-"):
            q = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i].rstrip()
    return line.rstrip()


def _indent(line):
    return len(line) - len(line.lstrip(" "))


class _Block:
    def __init__(self, text):
        self.raw = text.split("\n")
        self.i = 0

    def skip(self):
        while self.i < len(self.raw):
            s = _strip_comment(self.raw[self.i])
            if s.strip():
                return
            self.i += 1

    def node(self, ind):
        self.skip()
        if self.i >= len(self.raw):
            return None
        line = _strip_comment(self.raw[self.i])
        if _indent(line) < ind:
            return None
        if line.lstrip().startswith("- ") or line.strip() == "-":
            return self.seq(_indent(line))
        return self.map(_indent(line))

    def rest_value(self, rest, ind):
        """The value after `key:` or `- `: inline scalar or flow, a block scalar, or a nested block."""
        rest = rest.strip()
        if rest in ("|", "|-", "|+", ">", ">-", ">+"):
            return self.block_scalar(ind, rest)
        if rest.startswith(("{", "[")):
            text = rest
            depth = _depth(text)
            while depth > 0:
                self.i += 1
                if self.i >= len(self.raw):
                    raise ValueError("unclosed flow collection")
                more = _strip_comment(self.raw[self.i])
                text += "\n" + more
                depth = _depth(text)
            self.i += 1
            return _Flow(text).value()
        if rest == "":
            self.i += 1
            self.skip()
            if self.i < len(self.raw):
                nxt = _strip_comment(self.raw[self.i])
                if _indent(nxt) > ind or (_indent(nxt) == ind and nxt.lstrip().startswith("- ")):
                    return self.node(_indent(nxt))
            return None
        self.i += 1
        return _Flow(rest).scalar("")

    def block_scalar(self, ind, style):
        self.i += 1
        lines = []
        body_ind = None
        while self.i < len(self.raw):
            ln = self.raw[self.i]
            if ln.strip() == "":
                lines.append("")
                self.i += 1
                continue
            if body_ind is None:
                body_ind = _indent(ln)
                if body_ind <= ind:
                    break
            if _indent(ln) < body_ind:
                break
            lines.append(ln[body_ind:])
            self.i += 1
        while lines and lines[-1] == "":
            lines.pop()
        sep = "\n" if style.startswith("|") else " "
        return sep.join(lines) + ("" if style.endswith("-") else "\n")

    def map(self, ind):
        out = {}
        while True:
            self.skip()
            if self.i >= len(self.raw):
                return out
            line = _strip_comment(self.raw[self.i])
            if _indent(line) != ind or line.lstrip().startswith("- "):
                return out
            m = re.match(r"^\s*(\"[^\"]*\"|'[^']*'|[^:{}\[\],]+?)\s*:(\s+(.*)|)$", line)
            if not m:
                raise ValueError("cannot read line %d: %s" % (self.i + 1, line))
            key = _Flow(m.group(1)).scalar("")
            out[key] = self.rest_value(m.group(3) or "", ind)

    def seq(self, ind):
        out = []
        while True:
            self.skip()
            if self.i >= len(self.raw):
                return out
            line = _strip_comment(self.raw[self.i])
            if _indent(line) != ind or not (line.lstrip().startswith("- ") or line.strip() == "-"):
                return out
            body = line.lstrip()[2:] if line.strip() != "-" else ""
            if re.match(r"^(\"[^\"]*\"|'[^']*'|[^:{}\[\],\"']+?)\s*:(\s|$)", body) and not body.startswith(("{", "[")):
                # a mapping that starts on the dash line: re-read it as a mapping at the item's indent
                item_ind = ind + 2
                self.raw[self.i] = " " * item_ind + body
                out.append(self.map(item_ind))
            else:
                out.append(self.rest_value(body, ind))


def _depth(text):
    d = 0
    q = None
    for ch in text:
        if q:
            if ch == q:
                q = None
        elif ch in "\"'":
            q = ch
        elif ch in "{[":
            d += 1
        elif ch in "}]":
            d -= 1
    return d


def load_all(text):
    """Every document in text, in order; empty documents are dropped."""
    docs = []
    for part in re.split(r"(?m)^---[ \t]*$", text):
        if not any(_strip_comment(l).strip() for l in part.split("\n")):
            continue
        b = _Block(part)
        d = b.node(0)
        b.skip()
        if b.i < len(b.raw):
            raise ValueError("unread text at line %d: %s" % (b.i + 1, b.raw[b.i]))
        if d is not None:
            docs.append(d)
    return docs
