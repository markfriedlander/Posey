import Foundation
import zlib

struct ZIPArchive {
    struct Entry {
        let fileName: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    enum ArchiveError: Error {
        case unreadableArchive
    }

    private let data: Data

    init(data: Data) throws {
        guard data.count >= 22 else {
            throw ArchiveError.unreadableArchive
        }
        self.data = data
    }

    func entryData(named fileName: String) throws -> Data {
        let entry = try entries().first(where: { $0.fileName == fileName })
        guard let entry else {
            throw ArchiveError.unreadableArchive
        }
        return try extract(entry: entry)
    }

    private func entries() throws -> [Entry] {
        let eocdOffset = try endOfCentralDirectoryOffset()
        let totalEntries = Int(try uint16(at: eocdOffset + 10))
        let centralDirectoryOffset = Int(try uint32(at: eocdOffset + 16))
        var offset = centralDirectoryOffset
        var entries: [Entry] = []
        entries.reserveCapacity(totalEntries)

        for _ in 0..<totalEntries {
            guard try uint32(at: offset) == 0x02014b50 else {
                throw ArchiveError.unreadableArchive
            }

            let compressionMethod = try uint16(at: offset + 10)
            let compressedSize = Int(try uint32(at: offset + 20))
            let uncompressedSize = Int(try uint32(at: offset + 24))
            let fileNameLength = Int(try uint16(at: offset + 28))
            let extraFieldLength = Int(try uint16(at: offset + 30))
            let fileCommentLength = Int(try uint16(at: offset + 32))
            let localHeaderOffset = Int(try uint32(at: offset + 42))
            let fileNameData = try slice(offset: offset + 46, length: fileNameLength)

            guard let fileName = String(data: fileNameData, encoding: .utf8) else {
                throw ArchiveError.unreadableArchive
            }

            entries.append(
                Entry(
                    fileName: fileName,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset
                )
            )

            offset += 46 + fileNameLength + extraFieldLength + fileCommentLength
        }

        return entries
    }

    private func extract(entry: Entry) throws -> Data {
        let localHeaderOffset = entry.localHeaderOffset
        guard try uint32(at: localHeaderOffset) == 0x04034b50 else {
            throw ArchiveError.unreadableArchive
        }

        let fileNameLength = Int(try uint16(at: localHeaderOffset + 26))
        let extraFieldLength = Int(try uint16(at: localHeaderOffset + 28))
        let dataOffset = localHeaderOffset + 30 + fileNameLength + extraFieldLength
        let compressedData = try slice(offset: dataOffset, length: entry.compressedSize)

        switch entry.compressionMethod {
        case 0:
            return compressedData
        case 8:
            return try inflateRawDeflate(data: compressedData, expectedSize: max(entry.uncompressedSize, 1))
        default:
            throw ArchiveError.unreadableArchive
        }
    }

    private func endOfCentralDirectoryOffset() throws -> Int {
        let signature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        let minimumOffset = max(0, data.count - 66_000)

        guard data.count >= 4 else {
            throw ArchiveError.unreadableArchive
        }

        for offset in stride(from: data.count - 4, through: minimumOffset, by: -1) {
            if data[offset] == signature[0],
               data[offset + 1] == signature[1],
               data[offset + 2] == signature[2],
               data[offset + 3] == signature[3] {
                return offset
            }
        }

        throw ArchiveError.unreadableArchive
    }

    private func uint16(at offset: Int) throws -> UInt16 {
        let slice = try slice(offset: offset, length: 2)
        return slice.withUnsafeBytes { rawBuffer in
            UInt16(rawBuffer.load(as: UInt16.self).littleEndian)
        }
    }

    private func uint32(at offset: Int) throws -> UInt32 {
        let slice = try slice(offset: offset, length: 4)
        return slice.withUnsafeBytes { rawBuffer in
            UInt32(rawBuffer.load(as: UInt32.self).littleEndian)
        }
    }

    private func slice(offset: Int, length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset + length <= data.count else {
            throw ArchiveError.unreadableArchive
        }
        return data.subdata(in: offset..<(offset + length))
    }

    private func inflateRawDeflate(data: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        let status = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw ArchiveError.unreadableArchive
        }
        defer {
            inflateEnd(&stream)
        }

        var output = Data(count: expectedSize)

        return try data.withUnsafeBytes { inputBuffer in
            guard let inputBaseAddress = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                throw ArchiveError.unreadableArchive
            }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBaseAddress)
            stream.avail_in = uInt(data.count)

            while true {
                let writtenCount = Int(stream.total_out)
                let availableCapacity = output.count - writtenCount

                let statusCode = try output.withUnsafeMutableBytes { outputBuffer -> Int32 in
                    guard let outputBaseAddress = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                        throw ArchiveError.unreadableArchive
                    }

                    stream.next_out = outputBaseAddress.advanced(by: writtenCount)
                    stream.avail_out = uInt(availableCapacity)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                switch statusCode {
                case Z_STREAM_END:
                    output.count = Int(stream.total_out)
                    return output
                case Z_OK:
                    if stream.avail_out == 0 {
                        output.count += max(expectedSize, 1)
                    }
                default:
                    throw ArchiveError.unreadableArchive
                }
            }
        }
    }
}
