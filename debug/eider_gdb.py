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
  Map     { k: K*, v: V*, s: u8*, len, cap, used, key0, key1 }   slot i is an entry when s[i] == 1
  enum    { tag: <enumeration of the variants>, <Variant>: { fields } ... }

`bt` leaves out the runtime's frames (ei_main_body, main_run, thread_main, ...);
`set eider-hide-runtime off` shows them (`bt -no-filters` too).
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
    if tag.startswith("Map[") and names in (["k", "v", "s", "len", "cap", "used"], ["k", "v", "s", "len", "cap", "used", "key0", "key1"]):
        return MapPrinter(val)
    if _is_enum(t):
        return EnumPrinter(val)
    return None


# ---- backtraces without the runtime's frames

RUNTIME_FUNCTIONS = ("ei_main_body", "main_run", "thread_main", "start_thread", "__clone3", "clone3", "clone")


def _is_runtime_frame(decorator):
    name = decorator.function()
    fname = decorator.filename() or ""
    if isinstance(name, str) and (name in RUNTIME_FUNCTIONS or name.startswith("ei_")):
        return True
    return fname.endswith(("eider_rt.c", "eider_core.c", "eider_prof.c"))


if gdb is not None:
    import gdb.frames
    from gdb.FrameDecorator import FrameDecorator

    class HideRuntimeParameter(gdb.Parameter):
        """Whether `bt` leaves out the Eider runtime's frames (ei_main_body, main_run, ...)."""

        set_doc = "Set whether backtraces hide the Eider runtime's frames."
        show_doc = "Show whether backtraces hide the Eider runtime's frames."

        def __init__(self):
            super(HideRuntimeParameter, self).__init__("eider-hide-runtime", gdb.COMMAND_STACK, gdb.PARAM_BOOLEAN)
            self.value = True

        def get_set_string(self):
            return ""

        def get_show_string(self, svalue):
            return "Backtraces hide the Eider runtime's frames: " + svalue

    class RuntimeFrameFilter:
        def __init__(self):
            self.name = "eider-runtime"
            self.priority = 100
            self.enabled = True
            gdb.frame_filters[self.name] = self

        def filter(self, frame_iter):
            if not hide.value:
                return frame_iter
            return (f for f in frame_iter if not _is_runtime_frame(f))

    hide = HideRuntimeParameter()


def register(objfile=None):
    gdb.pretty_printers.append(lookup)
    RuntimeFrameFilter()


if gdb is not None:
    register()
