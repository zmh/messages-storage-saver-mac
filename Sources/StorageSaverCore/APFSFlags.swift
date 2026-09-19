import Foundation
import Darwin

/// Reads APFS extended flags through the public `getattrlist` API.
/// `EF_IS_PURGEABLE` is what the OS sets on files it may reclaim under
/// storage pressure; Messages' centralized cache-delete model relies on it.
public enum APFSFlags {
    // From xnu bsd/sys/attr.h (not all are exported in the SDK headers).
    public static let mayShareBlocks: UInt64 = 0x1
    public static let noXattrs: UInt64 = 0x2
    public static let isSyncRoot: UInt64 = 0x4
    public static let isPurgeable: UInt64 = 0x8
    public static let isSparse: UInt64 = 0x10

    private static let attrCmnExtExtFlags: UInt32 = 0x0000_0200   // ATTR_CMNEXT_EXT_FLAGS
    private static let fsoptAttrCmnExtended: UInt32 = 0x0000_0020 // FSOPT_ATTR_CMN_EXTENDED

    /// Extended flags for `path`, or nil if the call fails.
    public static func extendedFlags(path: String) -> UInt64? {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrgroup_t(attrCmnExtExtFlags)
        var buffer = [UInt8](repeating: 0, count: 32)
        let rc = buffer.withUnsafeMutableBytes { raw -> Int32 in
            getattrlist(path, &list, raw.baseAddress, raw.count, UInt32(fsoptAttrCmnExtended))
        }
        guard rc == 0 else { return nil }
        // Layout: u_int32 length, then u_int64 ext_flags.
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
    }

    public static func isPurgeable(path: String) -> Bool? {
        extendedFlags(path: path).map { $0 & isPurgeable != 0 }
    }
}
