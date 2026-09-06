import Foundation

/// Peak envelope of the extracted audio, stored as one byte per bucket.
///
/// At 20 buckets/second a 4-hour VOD is ~300 KB, which is small enough to keep
/// resident and re-bucket on the fly while drawing.
struct WaveformData: Equatable {
    var peaks: [UInt8]
    var peaksPerSecond: Double

    var duration: Double { peaksPerSecond > 0 ? Double(peaks.count) / peaksPerSecond : 0 }

    /// Aggregates the peaks covering `range` down to `buckets` values for
    /// drawing at whatever width the view happens to be.
    func envelope(from start: Double, to end: Double, buckets: Int) -> [Float] {
        guard buckets > 0, peaksPerSecond > 0, end > start, !peaks.isEmpty else { return [] }
        let firstIndex = max(0, Int(start * peaksPerSecond))
        let lastIndex = min(peaks.count, Int(end * peaksPerSecond))
        guard lastIndex > firstIndex else { return [] }

        let span = lastIndex - firstIndex
        var output = [Float](repeating: 0, count: buckets)
        for bucket in 0..<buckets {
            let lower = firstIndex + span * bucket / buckets
            let upper = max(lower + 1, firstIndex + span * (bucket + 1) / buckets)
            var peak: UInt8 = 0
            for index in lower..<min(upper, lastIndex) where peaks[index] > peak {
                peak = peaks[index]
            }
            output[bucket] = Float(peak) / 255
        }
        return output
    }
}

enum WaveformError: LocalizedError {
    case notAWavFile
    case noDataChunk

    var errorDescription: String? {
        switch self {
        case .notAWavFile: return "Extracted audio is not a readable WAV file."
        case .noDataChunk: return "Extracted audio has no PCM data chunk."
        }
    }
}

enum WaveformService {
    /// Streams the 16-bit mono WAV in blocks and writes one peak byte per
    /// bucket. Memory stays flat regardless of source length.
    static func generate(from wav: URL, to destination: URL,
                         sampleRate: Double = 16000,
                         peaksPerSecond: Double = 20,
                         onProgress: @escaping (Double) -> Void) throws -> WaveformData {
        let handle = try FileHandle(forReadingFrom: wav)
        defer { try? handle.close() }

        let (dataOffset, dataLength) = try locatePCMData(in: handle)
        try handle.seek(toOffset: dataOffset)

        let samplesPerPeak = max(1, Int(sampleRate / peaksPerSecond))
        var peaks: [UInt8] = []
        peaks.reserveCapacity(Int(Double(dataLength) / 2 / Double(samplesPerPeak)) + 1)

        var currentPeak: Int32 = 0
        var samplesInBucket = 0
        var bytesRead: UInt64 = 0
        var carry: UInt8?
        let blockSize = 4 * 1024 * 1024
        var lastReported = 0.0

        while bytesRead < dataLength {
            let wanted = Int(min(UInt64(blockSize), dataLength - bytesRead))
            guard let block = try handle.read(upToCount: wanted), !block.isEmpty else { break }
            bytesRead += UInt64(block.count)

            block.withUnsafeBytes { raw in
                var index = 0
                let bytes = raw.bindMemory(to: UInt8.self)

                // A 16-bit sample can straddle a block boundary.
                if let low = carry, bytes.count > 0 {
                    let sample = Int16(bitPattern: UInt16(low) | (UInt16(bytes[0]) << 8))
                    accumulate(sample, &currentPeak, &samplesInBucket, samplesPerPeak, &peaks)
                    index = 1
                    carry = nil
                }

                while index + 1 < bytes.count {
                    let sample = Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
                    accumulate(sample, &currentPeak, &samplesInBucket, samplesPerPeak, &peaks)
                    index += 2
                }
                if index < bytes.count { carry = bytes[index] }
            }

            let progress = Double(bytesRead) / Double(dataLength)
            if progress - lastReported > 0.02 {
                lastReported = progress
                onProgress(progress)
            }
        }

        if samplesInBucket > 0 {
            peaks.append(UInt8(min(255, currentPeak)))
        }

        try Data(peaks).write(to: destination, options: .atomic)
        onProgress(1)
        return WaveformData(peaks: peaks, peaksPerSecond: peaksPerSecond)
    }

    private static func accumulate(_ sample: Int16, _ currentPeak: inout Int32,
                                   _ samplesInBucket: inout Int, _ samplesPerPeak: Int,
                                   _ peaks: inout [UInt8]) {
        let magnitude = Int32(sample == Int16.min ? Int16.max : abs(sample))
        if magnitude > currentPeak { currentPeak = magnitude }
        samplesInBucket += 1
        if samplesInBucket >= samplesPerPeak {
            peaks.append(UInt8(min(255, currentPeak * 255 / 32767)))
            currentPeak = 0
            samplesInBucket = 0
        }
    }

    static func load(from url: URL, peaksPerSecond: Double) throws -> WaveformData {
        let data = try Data(contentsOf: url)
        return WaveformData(peaks: [UInt8](data), peaksPerSecond: peaksPerSecond)
    }

    /// Walks the RIFF chunk list to find the PCM payload.
    static func locatePCMData(in handle: FileHandle) throws -> (offset: UInt64, length: UInt64) {
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: 12), header.count == 12,
              header.prefix(4).elementsEqual("RIFF".utf8),
              header.suffix(4).elementsEqual("WAVE".utf8) else {
            throw WaveformError.notAWavFile
        }

        var cursor: UInt64 = 12
        while true {
            try handle.seek(toOffset: cursor)
            guard let chunkHeader = try handle.read(upToCount: 8), chunkHeader.count == 8 else {
                throw WaveformError.noDataChunk
            }
            let identifier = String(decoding: chunkHeader.prefix(4), as: UTF8.self)
            let size = chunkHeader.dropFirst(4).withUnsafeBytes { raw -> UInt32 in
                let bytes = raw.bindMemory(to: UInt8.self)
                return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            }
            if identifier == "data" {
                return (cursor + 8, UInt64(size))
            }
            cursor += 8 + UInt64(size) + UInt64(size % 2)
        }
    }
}
