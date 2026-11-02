"""lldb summaries and synthetic children for Eider programs built with `-g`.

    (lldb) command script import <toolchain>/debug/eider_lldb.py

shows a `String` as its text and a `List[T]` and `Map[K, V]` with their elements (an enum's
variant is the name of its `tag`, which lldb prints from the debug information itself). The layouts are the ones eider_gdb.py describes.
"""

try:
    import lldb
except ImportError:  # imported by the tests, outside lldb
    lldb = None


def _u(v, name):
    return v.GetChildMemberWithName(name).GetValueAsUnsigned()


def string_summary(valobj, internal_dict):
    v = valobj.GetNonSyntheticValue()
    n = _u(v, "len")
    p = _u(v, "p")
    if n == 0 or p == 0:
        return '""'
    err = lldb.SBError()
    data = v.GetProcess().ReadMemory(p, n, err)
    if not err.Success():
        return "<unreadable>"
    return '"%s"' % data.decode("utf-8", "replace")


def list_summary(valobj, internal_dict):
    return "length = %d" % _u(valobj.GetNonSyntheticValue(), "len")


class ListChildren:
    def __init__(self, valobj, internal_dict):
        self.v = valobj

    def update(self):
        self.d = self.v.GetChildMemberWithName("d")
        self.n = _u(self.v, "len")
        return False

    def has_children(self):
        return self.n > 0

    def num_children(self):
        return self.n

    def get_child_at_index(self, i):
        if i < 0 or i >= self.n:
            return None
        return self.d.GetChildAtIndex(i, lldb.eNoDynamicValues, True)

    def get_child_index(self, name):
        try:
            return int(name.strip("[]"))
        except ValueError:
            return -1


class MapChildren:
    """Children are the entries' keys and values, alternating: [0] key, [1] value, ..."""

    def __init__(self, valobj, internal_dict):
        self.v = valobj

    def update(self):
        self.slots = []
        k = self.v.GetChildMemberWithName("k")
        val = self.v.GetChildMemberWithName("v")
        s = self.v.GetChildMemberWithName("s")
        cap = _u(self.v, "cap")
        for i in range(cap):
            if s.GetChildAtIndex(i, lldb.eNoDynamicValues, True).GetValueAsUnsigned() == 1:
                self.slots.append((k.GetChildAtIndex(i, lldb.eNoDynamicValues, True),
                                   val.GetChildAtIndex(i, lldb.eNoDynamicValues, True)))
        return False

    def has_children(self):
        return len(self.slots) > 0

    def num_children(self):
        return 2 * len(self.slots)

    def get_child_at_index(self, i):
        if i < 0 or i >= 2 * len(self.slots):
            return None
        pair = self.slots[i // 2]
        v = pair[i % 2]
        return v.Clone("[%d].%s" % (i // 2, "value" if i % 2 else "key"))

    def get_child_index(self, name):
        return -1


def __lldb_init_module(debugger, internal_dict):
    m = __name__
    debugger.HandleCommand('type summary add -x "^String$" -F %s.string_summary -w eider' % m)
    debugger.HandleCommand('type summary add -x "^List\\[" -e -F %s.list_summary -w eider' % m)
    debugger.HandleCommand('type synthetic add -x "^List\\[" -l %s.ListChildren -w eider' % m)
    debugger.HandleCommand('type summary add -x "^Map\\[" -e -F %s.list_summary -w eider' % m)
    debugger.HandleCommand('type synthetic add -x "^Map\\[" -l %s.MapChildren -w eider' % m)
    debugger.HandleCommand("type category enable eider")
