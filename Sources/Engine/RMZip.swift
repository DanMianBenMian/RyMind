import Foundation
import zlib

/// 极简 ZIP 读写：只支持 store / deflate，不引第三方库，避免 SPM 把构建搞复杂。
enum RMZip {

    // MARK: - 解压

    /// 把 zip 解到 dest 下，返回解出来的相对路径列表
    static func extract(at src: URL, to dest: URL) throws -> [String] {
        let data = try Data(contentsOf: src)
        guard let eocd = eocdOffset(in: data) else {
            throw NSError(domain: "RMZip", code: 1, userInfo: [NSLocalizedDescriptionKey: "不是有效的 zip 文件"])
        }
        let fm = FileManager.default
        let count = Int(u16(data, eocd + 10))
        let cdStart = Int(u32(data, eocd + 16))
        var written: [String] = []

        for i in 0..<count {
            let cp = cdStart + i * 46
            guard cp + 46 <= data.count, u32(data, cp) == 0x02014b50 else { break }
            let method = Int(u16(data, cp + 10))
            let comp = Int(u32(data, cp + 20))
            let raw = Int(u32(data, cp + 24))
            let nameLen = Int(u16(data, cp + 28))
            let cmtLen = Int(u16(data, cp + 32))
            let loc = Int(u32(data, cp + 42))
            let ns = cp + 46
            guard ns + nameLen + cmtLen <= data.count else { break }
            let name = String(decoding: data[ns..<(ns + nameLen)], as: UTF8.self)

            let safe = sanitize(name)
            guard !safe.isEmpty else { continue }
            let target = dest.appendingPathComponent(safe)

            if safe.hasSuffix("/") {
                try? fm.createDirectory(atPath: target.path, withIntermediateDirectories: true)
                continue
            }
            try? fm.createDirectory(atPath: target.deletingLastPathComponent().path, withIntermediateDirectories: true)

            guard loc + 30 <= data.count else { continue }
            let lNameLen = Int(u16(data, loc + 26))
            let lExtraLen = Int(u16(data, loc + 28))
            let start = loc + 30 + lNameLen + lExtraLen
            guard start <= data.count else { continue }

            var bytes = Data()
            if method == 0 {
                let end = min(start + comp, data.count)
                bytes = data[start..<end]
            } else if method == 8 {
                let end = min(start + comp, data.count)
                bytes = (try? rawInflate(Array(data[start..<end]))) ?? Data()
            } else {
                continue
            }
            if bytes.isEmpty { continue }
            do { try bytes.write(to: target) } catch { continue }
            written.append(safe)
        }
        return written
    }

    // MARK: - 压缩（写 zip，store + deflate 都支持）

    static func archive(roots: [URL], to dest: URL) throws {
        var body = Data()
        var central = Data()
        var offset: UInt32 = 0

        for root in roots {
            let base = root.lastPathComponent
            guard let en = FileManager.default.enumerator(at: root,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { continue }
            var rels = [""]   // "" 代表 root 本身
            while let f = en.nextObject() as? URL {
                rels.append(f.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
            for rel in rels {
                let full = rel.isEmpty ? root : root.appendingPathComponent(rel)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full.path, isDirectory: &isDir) else { continue }
                let nameData = Data((rel.isEmpty ? base : base + "/" + rel).utf8)

                let attrs = (try? FileManager.default.attributesOfItem(atPath: full.path)) ?? [:]
                let size: UInt32 = isDir.boolValue ? 0 : UInt32((attrs[.size] as? Int) ?? 0)
                let blob = (try? Data(contentsOf: full)) ?? Data()
                let crc: UInt32 = isDir.boolValue ? 0 : crc32(byteArray: [UInt8](blob))
                var method: UInt16 = 0
                var load = Data()

                if !isDir.boolValue, size > 0 {
                    let comp = deflateBlob(blob)
                    if comp.count < blob.count {
                        method = 8
                        load = comp
                    } else {
                        load = blob
                    }
                }

                var loc = Data()
                putU32(&loc, 0x04034b50); putU16(&loc, 20)
                putU16(&loc, 0); putU16(&loc, method)
                putU16(&loc, 0); putU16(&loc, 0)
                putU32(&loc, crc); putU32(&loc, UInt32(load.count)); putU32(&loc, size)
                putU16(&loc, UInt16(nameData.count)); putU16(&loc, 0)
                loc.append(nameData); loc.append(load)
                body.append(loc)

                var cen = Data()
                putU32(&cen, 0x02014b50); putU16(&cen, 20); putU16(&cen, 20)
                putU16(&cen, 0); putU16(&cen, method)
                putU16(&cen, 0); putU16(&cen, 0)
                putU32(&cen, crc); putU32(&cen, UInt32(load.count)); putU32(&cen, size)
                putU16(&cen, UInt16(nameData.count))
                putU16(&cen, 0); putU16(&cen, 0); putU16(&cen, 0); putU16(&cen, 0)
                putU32(&cen, 0); putU32(&cen, offset)
                cen.append(nameData)
                central.append(cen)

                offset += UInt32(loc.count)
            }
        }

        var tail = Data()
        putU32(&tail, 0x06054b50)
        putU16(&tail, 0); putU16(&tail, 0)
        putU16(&tail, UInt16(countDirs(roots))); putU16(&tail, UInt16(countDirs(roots)))
        putU32(&tail, UInt32(central.count)); putU32(&tail, UInt32(body.count))
        putU16(&tail, 0)

        var out = Data()
        out.append(body); out.append(central); out.append(tail)
        try out.write(to: dest)
    }

    private static func countDirs(_ roots: [URL]) -> Int {
        var n = 0
        for r in roots {
            if let e = FileManager.default.enumerator(at: r, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) { n += 1; while e.nextObject() != nil { n += 1 } }
        }
        return max(n, 1)
    }

    // MARK: - zlib 辅助

    private static func deflateBlob(_ blob: Data) -> Data {
        var out = Data(repeating: 0, count: max(blob.count + 256, 1024))
        var filled = 0
        _ = blob.withUnsafeBytes { sb -> Int32 in
            out.withUnsafeMutableBytes { db -> Int32 in

                var st = z_stream()
                st.next_in = UnsafeMutableRawPointer(mutating: sb.baseAddress!).bindMemory(to: Bytef.self, capacity: sb.count)
                st.avail_in = uInt(blob.count)
                st.next_out = db.baseAddress!.bindMemory(to: Bytef.self, capacity: db.count)
                st.avail_out = uInt(out.count)
                deflateInit2_(&st, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                let r = deflate(&st, Z_FINISH)
                filled = Int(st.total_out)
                deflateEnd(&st)
                return r
            }
        }
        return Data(out.prefix(filled))
    }

    private static func rawInflate(_ src: [UInt8]) throws -> Data {
        var out = [UInt8](repeating: 0, count: max(src.count * 4 + 1024, 4096))
        var filled = 0
        let rc = out.withUnsafeMutableBytes { db -> Int32 in
            src.withUnsafeBytes { sb -> Int32 in
                var st = z_stream()
                st.next_in = UnsafeMutableRawPointer(mutating: sb.baseAddress!).bindMemory(to: Bytef.self, capacity: sb.count)
                st.avail_in = uInt(src.count)
                st.next_out = db.baseAddress!.bindMemory(to: Bytef.self, capacity: db.count)
                st.avail_out = uInt(out.count)
                inflateInit2_(&st, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                let r = inflate(&st, Z_FINISH)
                filled = Int(st.total_out)
                inflateEnd(&st)
                return r
            }
        }
        guard rc == Z_STREAM_END, filled > 0 else {
            throw NSError(domain: "RMZip", code: 2, userInfo: [NSLocalizedDescriptionKey: "解压失败（可能不是标准 zip）"])
        }
        return Data(out.prefix(filled))
    }

    private static func crc32(byteArray: [UInt8]) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            table[n] = c
        }
        var crc: UInt32 = 0xFFFFFFFF
        for b in byteArray { crc = table[Int(crc ^ UInt32(b)) & 0xFF] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - 字节读取

    private static func sanitize(_ s: String) -> String {
        var out = ""
        for seg in s.split(separator: "/") {
            let p = String(seg)
            if p.isEmpty || p == "." || p == ".." || p == "~" { continue }
            out += (out.isEmpty ? "" : "/") + p
        }
        return out
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[o]) | (UInt16(d[o + 1]) << 8) }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
    }

    private static func eocdOffset(in d: Data) -> Int? {
        let maxBack = min(d.count - 22, 66000)
        guard maxBack > 0 else { return nil }
        let start = d.count - 22 - maxBack
        var i = start
        while i < start + maxBack {
            if u32(d, i) == 0x06054b50 { return i }
            i += 1
        }
        return nil
    }

    private static func putU16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(truncatingIfNeeded: v)); d.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    private static func putU32(_ d: inout Data, _ v: UInt32) {
        for i in 0..<4 { d.append(UInt8(truncatingIfNeeded: v >> (8 * i))) }
    }
}
