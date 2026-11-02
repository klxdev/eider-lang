"""gdb pretty-printers for Eider programs built with `-g` (docs/site/tooling/compiler.md,
"Debugging").

    (gdb) source <toolchain>/debug/eider_gdb.py

prints a `String` as its text, a `List[T]` as an array, a `Map[K, V]` as a map and an enum as
its variant with the fields of that variant:

    (gdb) print names_list
    $1 = List[String] of length 1 = {"a"}
    (gdb) print shape_arg
    $2 = Circle = {centre = {px = 4, py = 5}, radius = 2}

How the values are laid out in the debug information (llvm.ei, di_type):
  String  { p: char*, len, cap }                 the bytes are p[0..len), UTF-8
  List    { d: T*, len, cap }                    the elements are d[0..len)
  Map     { k: K*, v: V*, s: u8*, len, cap, used }   slot i is an entry when s[i] == 1
  enum    { tag: <enumeration of the variants>, <Variant>: { fields } ... }
"""

try:
    import gdb
    import gdb.printing
except ImportError:  # imported by the tests, outside gdb
    gdb = None


def _tag(t):
    t = t.strip_typedefs()
    return t.tag or t.name or ""


def _field_names(t):
    return [f.name for f in t.strip_typedefs().fields()]


class StringPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        n = int(self.val["len"])
        if n == 0 or int(self.val["p"]) == 0:
            return ""
        return self.val["p"].string(length=n, errors="replace")

    def display_hint(self):
        return "string"


class ListPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        return "%s of length %d" % (_tag(self.val.type), int(self.val["len"]))

    def children(self):
        n = int(self.val["len"])
        d = self.val["d"]
        for i in range(n):
            yield "[%d]" % i, d[i]

    def display_hint(self):
        return "array"


class MapPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        return "%s of length %d" % (_tag(self.val.type), int(self.val["len"]))

    def children(self):
        cap = int(self.val["cap"])
        s, k, v = self.val["s"], self.val["k"], self.val["v"]
        n = 0
        for i in range(cap):
            if int(s[i]) == 1:
                yield "[%d]" % n, k[i]
                yield "[%d]" % n, v[i]
                n += 1

    def display_hint(self):
        return "map"


class EnumPrinter:
    """`Circle = {..}` for a variant with fields, `Dot` for one without."""

    def __init__(self, val):
        self.val = val
        self.variant = str(val["tag"])

    def to_string(self):
        return self.variant

    def children(self):
        t = self.val.type.strip_typedefs()
        if self.variant in _field_names(t):
            payload = self.val[self.variant]
            for f in payload.type.strip_typedefs().fields():
                yield f.name, payload[f.name]


def _is_enum(t):
    names = _field_names(t)
    if not names or names[0] != "tag":
        return False
    tagt = t.strip_typedefs().fields()[0].type.strip_typedefs()
    return tagt.code == gdb.TYPE_CODE_ENUM


def lookup(val):
    t = val.type.strip_typedefs()
    if t.code != gdb.TYPE_CODE_STRUCT:
        return None
    tag = _tag(t)
    names = _field_names(t)
    if tag == "String" and names == ["p", "len", "cap"]:
        return StringPrinter(val)
    if tag.startswith("List[") and names == ["d", "len", "cap"]:
        return ListPrinter(val)
    if tag.startswith("Map[") and names == ["k", "v", "s", "len", "cap", "used"]:
        return MapPrinter(val)
    if _is_enum(t):
        return EnumPrinter(val)
    return None


def register(objfile=None):
    gdb.pretty_printers.append(lookup)


if gdb is not None:
    register()
