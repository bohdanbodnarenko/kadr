import Foundation

/// A minimal ZIP reader and writer, store-only.
///
/// `.kadr` is a zip of `base.png` plus `commands.json` (docs/04 §6), and Foundation has
/// no zip API. Rather than take a dependency for two files, this writes the store-only
/// subset of the format: local headers, a central directory and an end record.
///
/// Store-only is the right trade here — a PNG is already compressed, and the JSON is a
/// few kilobytes. The files it produces open in the Finder, `unzip` and every other tool,
/// which is the point of using a zip at all.
enum ZipArchive {
    struct Entry: Hashable {
        let name: String
        let data: Data
        /// The entry's CRC-32, when the caller already knows it.
        ///
        /// The base image of an editing session never changes, yet autosave rewrites it
        /// every few seconds; checksumming the same 20 MB each time is pure waste, so the
        /// owner computes it once and hands it back (docs/10 R2.6).
        let crc: UInt32?

        init(name: String, data: Data, crc: UInt32? = nil) {
            self.name = name
            self.data = data
            self.crc = crc
        }
    }

    enum ArchiveError: Error, Equatable {
        case notAZipArchive
        case unsupportedCompression
        case corrupted(String)
    }

    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let endOfDirectorySignature: UInt32 = 0x0605_4B50

    // MARK: - Writing

    static func archive(_ entries: [Entry]) -> Data {
        var output = Data()
        var directory = Data()

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let crc = entry.crc ?? crc32(entry.data)
            let offset = UInt32(output.count)

            output.append(uint32: localHeaderSignature)
            output.append(uint16: 20) // version needed
            output.append(uint16: 0) // flags
            output.append(uint16: 0) // stored
            output.append(uint16: 0) // modification time
            output.append(uint16: 0) // modification date
            output.append(uint32: crc)
            output.append(uint32: UInt32(entry.data.count))
            output.append(uint32: UInt32(entry.data.count))
            output.append(uint16: UInt16(nameBytes.count))
            output.append(uint16: 0) // extra field length
            output.append(nameBytes)
            output.append(entry.data)

            directory.append(uint32: centralHeaderSignature)
            directory.append(uint16: 20) // version made by
            directory.append(uint16: 20) // version needed
            directory.append(uint16: 0)
            directory.append(uint16: 0) // stored
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint32: crc)
            directory.append(uint32: UInt32(entry.data.count))
            directory.append(uint32: UInt32(entry.data.count))
            directory.append(uint16: UInt16(nameBytes.count))
            directory.append(uint16: 0) // extra
            directory.append(uint16: 0) // comment
            directory.append(uint16: 0) // disk number
            directory.append(uint16: 0) // internal attributes
            directory.append(uint32: 0) // external attributes
            directory.append(uint32: offset)
            directory.append(nameBytes)
        }

        let directoryOffset = UInt32(output.count)
        output.append(directory)
        output.append(uint32: endOfDirectorySignature)
        output.append(uint16: 0) // disk number
        output.append(uint16: 0) // directory start disk
        output.append(uint16: UInt16(entries.count))
        output.append(uint16: UInt16(entries.count))
        output.append(uint32: UInt32(directory.count))
        output.append(uint32: directoryOffset)
        output.append(uint16: 0) // comment length
        return output
    }

    // MARK: - Reading

    /// Reads entries by walking the local headers, which is enough for archives this
    /// writes and for anything else store-only.
    static func entries(in data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ArchiveError.notAZipArchive }
        guard data.readUInt32(at: 0) == localHeaderSignature || data.contains(signature: endOfDirectorySignature)
        else {
            throw ArchiveError.notAZipArchive
        }

        var entries: [Entry] = []
        var cursor = 0

        while cursor + 30 <= data.count, data.readUInt32(at: cursor) == localHeaderSignature {
            let compression = data.readUInt16(at: cursor + 8)
            guard compression == 0 else { throw ArchiveError.unsupportedCompression }

            let size = Int(data.readUInt32(at: cursor + 18))
            let nameLength = Int(data.readUInt16(at: cursor + 26))
            let extraLength = Int(data.readUInt16(at: cursor + 28))
            let nameStart = cursor + 30
            let contentStart = nameStart + nameLength + extraLength

            guard contentStart + size <= data.count else {
                throw ArchiveError.corrupted("entry runs past the end of the archive")
            }
            guard let name = String(data: data.slice(nameStart, nameLength), encoding: .utf8) else {
                throw ArchiveError.corrupted("entry name is not UTF-8")
            }

            entries.append(Entry(name: name, data: data.slice(contentStart, size)))
            cursor = contentStart + size
        }

        guard !entries.isEmpty else { throw ArchiveError.corrupted("no entries found") }
        return entries
    }

    // MARK: - CRC32

    /// IEEE CRC-32 slicing-by-8 tables, built once.
    ///
    /// A 256-entry table is one lookup per byte; slicing-by-8 folds eight bytes per step
    /// through eight tables, which is roughly four times faster on a 5K PNG — and this runs
    /// on every autosave and project save (docs/10 R2.6). `tables[0]` is the classic table.
    private static let tables: [[UInt32]] = {
        var tables = [[UInt32]](repeating: [UInt32](repeating: 0, count: 256), count: 8)
        for index in 0 ..< 256 {
            var crc = UInt32(index)
            for _ in 0 ..< 8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
            tables[0][index] = crc
        }
        for index in 0 ..< 256 {
            var crc = tables[0][index]
            for slice in 1 ..< 8 {
                crc = tables[0][Int(crc & 0xFF)] ^ (crc >> 8)
                tables[slice][index] = crc
            }
        }
        return tables
    }()

    /// The flattened tables, `tables[slice][byte]` at `slice * 256 + byte`, so the hot loop
    /// indexes one contiguous buffer rather than an array of arrays.
    private static let flatTable: [UInt32] = tables.flatMap(\.self)

    /// The standard CRC-32 zip files carry, so other tools accept what this writes.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            crc = update(crc, buffer)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Folds `buffer` into a running (pre-inverted) CRC.
    private static func update(_ start: UInt32, _ buffer: UnsafeRawBufferPointer) -> UInt32 {
        var crc = start
        let count = buffer.count
        guard count > 0, let base = buffer.baseAddress else { return crc }
        flatTable.withUnsafeBufferPointer { table in
            var offset = 0
            while offset + 8 <= count {
                let low = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) ^ crc
                let high = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                crc = table[7 * 256 + Int(low & 0xFF)]
                    ^ table[6 * 256 + Int((low >> 8) & 0xFF)]
                    ^ table[5 * 256 + Int((low >> 16) & 0xFF)]
                    ^ table[4 * 256 + Int(low >> 24)]
                    ^ table[3 * 256 + Int(high & 0xFF)]
                    ^ table[2 * 256 + Int((high >> 8) & 0xFF)]
                    ^ table[1 * 256 + Int((high >> 16) & 0xFF)]
                    ^ table[Int(high >> 24)]
                offset += 8
            }
            while offset < count {
                let byte = base.load(fromByteOffset: offset, as: UInt8.self)
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                offset += 1
            }
        }
        return crc
    }

    /// The reference one-table implementation, kept so tests can check the fast path
    /// against something obviously right on arbitrary input.
    static func crc32Bytewise(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                crc = tables[0][Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    mutating func append(uint32 value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[startIndex + offset])
            | (UInt32(self[startIndex + offset + 1]) << 8)
            | (UInt32(self[startIndex + offset + 2]) << 16)
            | (UInt32(self[startIndex + offset + 3]) << 24)
    }

    func slice(_ offset: Int, _ length: Int) -> Data {
        Data(self[(startIndex + offset) ..< (startIndex + offset + length)])
    }

    func contains(signature: UInt32) -> Bool {
        guard count >= 4 else { return false }
        for offset in 0 ... (count - 4) where readUInt32(at: offset) == signature {
            return true
        }
        return false
    }
}
