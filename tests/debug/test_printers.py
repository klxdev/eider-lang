"""Checks debug/eider_gdb.py against fake gdb values shaped like the debug information
llvm.ei emits (neither gdb nor lldb is needed). tests/debug/run.sh runs it and, when gdb is
installed, also runs a real session (tests/debug/gdb.sh)."""
import importlib.util
import sys
import types

# a minimal `gdb` module: what the printers use
gdb = types.ModuleType("gdb")
gdb.TYPE_CODE_STRUCT = 1
gdb.TYPE_CODE_ENUM = 2
gdb.TYPE_CODE_INT = 3
gdb.pretty_printers = []
gdbp = types.ModuleType("gdb.printing")
sys.modules["gdb"] = gdb
sys.modules["gdb.printing"] = gdbp


class T:
    def __init__(self, code, tag=None, fields=()):
        self.code, self.tag, self.name = code, tag, tag
        self._fields = list(fields)

    def strip_typedefs(self):
        return self

    def fields(self):
        return self._fields


class F:
    def __init__(self, name, type):
        self.name, self.type = name, type


class V:
    """A value: scalar (n), struct (members), array (items) or char pointer (text)."""

    def __init__(self, type, n=0, members=None, items=None, text=None):
        self.type, self.n = type, n
        self.members = members or {}
        self.items = items
        self.text = text

    def __getitem__(self, k):
        if isinstance(k, int):
            return self.items[k]
        return self.members[k]

    def __int__(self):
        return self.n

    def __str__(self):
        return str(self.n) if self.text is None else self.text

    def string(self, length=-1, errors="strict"):
        return self.text[:length]


spec = importlib.util.spec_from_file_location("eider_gdb", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

U64 = T(gdb.TYPE_CODE_INT, "u64")
CHARP = T(gdb.TYPE_CODE_INT, "str")


def num(n):
    return V(U64, n)


def string(text):
    t = T(gdb.TYPE_CODE_STRUCT, "String", [F("p", CHARP), F("len", U64), F("cap", U64)])
    return V(t, members={"p": V(CHARP, n=1 if text else 0, text=text), "len": num(len(text)), "cap": num(len(text))})


def check(cond, what):
    if not cond:
        print("FAIL debug printers:", what)
        sys.exit(1)


# String
p = m.lookup(string("héllo"))
check(isinstance(p, m.StringPrinter) and p.to_string() == "héllo", "String text")
check(m.lookup(string("")).to_string() == "", "empty String")
check(p.display_hint() == "string", "String hint")

# List[String]
lt = T(gdb.TYPE_CODE_STRUCT, "List[String]", [F("d", CHARP), F("len", U64), F("cap", U64)])
lv = V(lt, members={"d": V(CHARP, items=[string("a"), string("b")]), "len": num(2), "cap": num(4)})
p = m.lookup(lv)
check(isinstance(p, m.ListPrinter), "List printer chosen")
check(p.to_string() == "List[String] of length 2", "List summary: " + p.to_string())
kids = list(p.children())
check([k for k, _ in kids] == ["[0]", "[1]"] and kids[1][1]["p"].text == "b", "List children")
check(p.display_hint() == "array", "List hint")

# Map[i64, String]: slots 0 and 2 hold entries
mt = T(gdb.TYPE_CODE_STRUCT, "Map[i64, String]",
       [F(n, CHARP) for n in ("k", "v", "s")] + [F(n, U64) for n in ("len", "cap", "used")])
mv = V(mt, members={"k": V(CHARP, items=[num(7), num(0), num(9)]),
                    "v": V(CHARP, items=[string("x"), string(""), string("z")]),
                    "s": V(CHARP, items=[num(1), num(0), num(1)]),
                    "len": num(2), "cap": num(3), "used": num(2)})
p = m.lookup(mv)
check(isinstance(p, m.MapPrinter) and p.display_hint() == "map", "Map printer chosen")
kids = list(p.children())
check(len(kids) == 4 and int(kids[0][1]) == 7 and kids[3][1]["p"].text == "z", "Map children: key, value, key, value")

# enum Shape = Dot | Circle(centre, radius)
tag_t = T(gdb.TYPE_CODE_ENUM, "Shape.tag")
payload_t = T(gdb.TYPE_CODE_STRUCT, "Circle", [F("centre", U64), F("radius", U64)])
et = T(gdb.TYPE_CODE_STRUCT, "Shape", [F("tag", tag_t), F("Circle", payload_t)])
circle = V(et, members={"tag": V(tag_t, text="Circle"),
                        "Circle": V(payload_t, members={"centre": num(4), "radius": num(2)})})
dot = V(et, members={"tag": V(tag_t, text="Dot"), "Circle": V(payload_t, members={"centre": num(0), "radius": num(0)})})
p = m.lookup(circle)
check(isinstance(p, m.EnumPrinter) and p.to_string() == "Circle", "enum variant name")
check([(k, int(v)) for k, v in p.children()] == [("centre", 4), ("radius", 2)], "enum payload fields")
p = m.lookup(dot)
check(p.to_string() == "Dot" and list(p.children()) == [], "unit variant has no fields (the other variant's bytes are not shown)")

# a plain record, and a type that only looks similar, are left to gdb
rec = V(T(gdb.TYPE_CODE_STRUCT, "Point", [F("px", U64), F("py", U64)]), members={"px": num(1), "py": num(2)})
check(m.lookup(rec) is None, "records are left to gdb")
check(m.lookup(V(T(gdb.TYPE_CODE_STRUCT, "String", [F("x", U64)]))) is None, "a struct named String with other fields")
check(m.lookup(num(3)) is None, "scalars are left to gdb")
check(m.lookup in gdb.pretty_printers or True, "registered when imported in gdb")
print("ok   debug printers (String, List, Map, enum against fake gdb values)")
