#!/usr/bin/env python3
"""Research probe used on 2026-09-17 (read-only; not part of the shipped tool).

1. Asks the system CacheDelete service how much the Messages daemon reports as
   purgeable at each urgency.
2. Checks whether given files carry the APFS purgeable flag (public getattrlist).

Usage: python3 experiments/probe.py [file ...]
"""
import ctypes
import sys

cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
cd = ctypes.CDLL("/System/Library/PrivateFrameworks/CacheDelete.framework/CacheDelete")
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)

cf.CFStringCreateWithCString.restype = ctypes.c_void_p
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
cf.CFNumberCreate.restype = ctypes.c_void_p
cf.CFNumberCreate.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p]
cf.CFDictionaryCreate.restype = ctypes.c_void_p
cf.CFDictionaryCreate.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]
cf.CFCopyDescription.restype = ctypes.c_void_p
cf.CFCopyDescription.argtypes = [ctypes.c_void_p]
cf.CFStringGetCString.restype = ctypes.c_bool
cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
KCB = ctypes.addressof(ctypes.c_char.in_dll(cf, "kCFTypeDictionaryKeyCallBacks"))
VCB = ctypes.addressof(ctypes.c_char.in_dll(cf, "kCFTypeDictionaryValueCallBacks"))
UTF8 = 0x08000100


def S(s):
    return cf.CFStringCreateWithCString(None, s.encode(), UTF8)


def N(i):
    v = ctypes.c_longlong(i)
    return cf.CFNumberCreate(None, 4, ctypes.byref(v))  # kCFNumberSInt64Type


def D(d):
    keys = (ctypes.c_void_p * len(d))(*[S(k) for k in d])
    vals = (ctypes.c_void_p * len(d))(*list(d.values()))
    return cf.CFDictionaryCreate(None, keys, vals, len(d), KCB, VCB)


def describe(p):
    if not p:
        return "<NULL>"
    buf = ctypes.create_string_buffer(65536)
    cf.CFStringGetCString(cf.CFCopyDescription(p), buf, 65536, UTF8)
    return buf.value.decode(errors="replace")


cd.CacheDeleteCopyPurgeableSpaceWithInfo.restype = ctypes.c_void_p
cd.CacheDeleteCopyPurgeableSpaceWithInfo.argtypes = [ctypes.c_void_p]
for urgency in range(5):
    info = D({"CACHE_DELETE_URGENCY": N(urgency), "CACHE_DELETE_VOLUME": S("/"), "CACHE_DELETE_ID": S("com.apple.imagent.cache-delete")})
    print(f"urgency {urgency}:", describe(cd.CacheDeleteCopyPurgeableSpaceWithInfo(info)).replace("\n", " "))


class attrlist(ctypes.Structure):
    _fields_ = [("bitmapcount", ctypes.c_ushort), ("reserved", ctypes.c_uint16), ("commonattr", ctypes.c_uint32),
                ("volattr", ctypes.c_uint32), ("dirattr", ctypes.c_uint32), ("fileattr", ctypes.c_uint32), ("forkattr", ctypes.c_uint32)]


libc.getattrlist.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong]
for path in sys.argv[1:]:
    al = attrlist(5, 0, 0, 0, 0, 0, 0x200)  # ATTR_CMNEXT_EXT_FLAGS
    buf = ctypes.create_string_buffer(64)
    if libc.getattrlist(path.encode(), ctypes.byref(al), buf, 64, 0x20) == 0:  # FSOPT_ATTR_CMN_EXTENDED
        flags = ctypes.c_uint64.from_buffer_copy(buf.raw[4:12]).value
        print(f"{path}: ext_flags=0x{flags:x} purgeable={bool(flags & 0x8)}")
    else:
        print(f"{path}: getattrlist failed")
