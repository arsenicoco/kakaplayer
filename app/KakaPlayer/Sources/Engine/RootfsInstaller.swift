import Foundation
import Compression

/// Installs the bundled guest root filesystem (rootfs.img.xz) into
/// Application Support as a sparse ext4 image, and locates the kernel.
enum RootfsInstaller {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KakaPlayer", isDirectory: true)
    }

    static var diskImageURL: URL { supportDirectory.appendingPathComponent("rootfs.img") }
    static var versionStampURL: URL { supportDirectory.appendingPathComponent("rootfs.version") }

    static var bundledKernelURL: URL? { Bundle.main.url(forResource: "vmlinux-arm64", withExtension: nil) }
    static var bundledRootfsURL: URL? { Bundle.main.url(forResource: "rootfs.img", withExtension: "xz") }
    static var bundledVersion: String {
        if let u = Bundle.main.url(forResource: "rootfs", withExtension: "version"),
           let s = try? String(contentsOf: u, encoding: .utf8) {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "unversioned"
    }

    static var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: diskImageURL.path) else { return false }
        let stamp = (try? String(contentsOf: versionStampURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return stamp == bundledVersion
    }

    static func removeInstalled() throws {
        let fm = FileManager.default
        for u in [diskImageURL, versionStampURL] where fm.fileExists(atPath: u.path) {
            try fm.removeItem(at: u)
        }
    }

    /// Decompresses the xz image into a sparse file. `progress` receives bytes written so far.
    static func install(progress: @escaping (Int64) -> Void) throws {
        guard let src = bundledRootfsURL else {
            throw NSError(domain: "KakaPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "rootfs.img.xz is missing from the app bundle."])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let tmp = supportDirectory.appendingPathComponent("rootfs.img.partial")
        try? fm.removeItem(at: tmp)
        try XZSparseDecompressor.decompress(from: src, to: tmp, progress: progress)
        try? fm.removeItem(at: diskImageURL)
        try fm.moveItem(at: tmp, to: diskImageURL)
        try bundledVersion.write(to: versionStampURL, atomically: true, encoding: .utf8)
    }
}

/// Streams an .xz file through Apple's Compression framework, writing the output
/// sparsely (all-zero 1 MiB blocks become holes) so a 4 GiB image costs only its
/// actual content on disk.
enum XZSparseDecompressor {
    static func decompress(from src: URL, to dst: URL, progress: @escaping (Int64) -> Void) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        let outFD = open(dst.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard outFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(outFD) }

        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>.allocate(capacity: 1), dst_size: 0, src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
            throw NSError(domain: "KakaPlayer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot initialize xz decoder."])
        }
        defer { compression_stream_destroy(&stream) }

        let blockSize = 1 << 20
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: blockSize)
        defer { outBuf.deallocate() }
        var block = Data(capacity: blockSize)
        var written: Int64 = 0
        var lastReport: Int64 = 0

        func flushBlock(final: Bool) throws {
            guard !block.isEmpty else { return }
            let isZero = block.allSatisfy { $0 == 0 }
            if isZero {
                written += Int64(block.count)
                if final { if ftruncate(outFD, off_t(written)) != 0 { throw POSIXError(.EIO) } }
            } else {
                try block.withUnsafeBytes { raw in
                    var off = 0
                    while off < raw.count {
                        let w = pwrite(outFD, raw.baseAddress! + off, raw.count - off, off_t(written) + off_t(off))
                        if w < 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                        off += w
                    }
                }
                written += Int64(block.count)
            }
            block.removeAll(keepingCapacity: true)
            if written - lastReport >= (16 << 20) || final {
                lastReport = written
                progress(written)
            }
        }

        var srcData = Data()
        var finished = false
        var inputEOF = false
        while !finished {
            if srcData.isEmpty && !inputEOF {
                srcData = input.readData(ofLength: 1 << 20)
                if srcData.isEmpty { inputEOF = true }
            }
            let flags = inputEOF ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status: compression_status = try srcData.withUnsafeBytes { raw -> compression_status in
                stream.src_ptr = raw.count > 0 ? raw.bindMemory(to: UInt8.self).baseAddress! : UnsafePointer<UInt8>(bitPattern: 1)!
                stream.src_size = raw.count
                stream.dst_ptr = outBuf
                stream.dst_size = blockSize
                let st = compression_stream_process(&stream, flags)
                let produced = blockSize - stream.dst_size
                if produced > 0 {
                    var off = 0
                    while off < produced {
                        let take = min(blockSize - block.count, produced - off)
                        block.append(outBuf + off, count: take)
                        off += take
                        if block.count == blockSize { try flushBlock(final: false) }
                    }
                }
                let consumed = raw.count - stream.src_size
                srcData = consumed == raw.count ? Data() : Data(raw[consumed...])
                return st
            }
            switch status {
            case COMPRESSION_STATUS_OK: continue
            case COMPRESSION_STATUS_END: finished = true
            default:
                throw NSError(domain: "KakaPlayer", code: 3, userInfo: [NSLocalizedDescriptionKey: "xz decode error (corrupt rootfs.img.xz?)"])
            }
        }
        try flushBlock(final: true)
        if ftruncate(outFD, off_t(written)) != 0 { throw POSIXError(.EIO) }
        fsync(outFD)
        progress(written)
    }
}
