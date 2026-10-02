import CoreMedia
import Foundation

enum VideoStreamError: LocalizedError {
    case invalidData, unsupportedCodec, stalled, decoderBusy, cameraUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidData: "The camera sent an invalid video fragment."
        case .unsupportedCodec: "Native playback needs an H.264 or H.265 stream."
        case .stalled: "The camera stream stopped responding."
        case .decoderBusy: "The video decoder could not keep up."
        case .cameraUnavailable: "The camera is unavailable. Try another camera or reconnect."
        }
    }
}

/// A bounded ISO-BMFF reader for go2rtc's video-only MSE stream.
struct MP4Box {
    let type: String
    let start: Int
    let body: Range<Int>
    static func read(_ data: Data, range: Range<Int>? = nil) throws -> [MP4Box] {
        let range = range ?? 0..<data.count
        guard range.lowerBound >= 0, range.upperBound <= data.count else { throw VideoStreamError.invalidData }
        var offset = range.lowerBound
        var result: [MP4Box] = []
        while offset < range.upperBound {
            guard range.upperBound - offset >= 8 else { throw VideoStreamError.invalidData }
            let size = Int(try data.u32(offset))
            guard size >= 8, size <= range.upperBound - offset, result.count < 4096 else {
                throw VideoStreamError.invalidData
            }
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            result.append(MP4Box(type: type, start: offset, body: (offset + 8)..<(offset + size)))
            offset += size
        }
        return result
    }
}

extension Data {
    func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, count - offset >= 4 else { throw VideoStreamError.invalidData }
        return (0..<4).reduce(0) { ($0 << 8) | UInt32(self[offset + $1]) }
    }
    func u64(_ offset: Int) throws -> UInt64 {
        (UInt64(try u32(offset)) << 32) | UInt64(try u32(offset + 4))
    }
    func u16(_ offset: Int) throws -> UInt16 {
        guard offset >= 0, count - offset >= 2 else { throw VideoStreamError.invalidData }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }
}

struct VideoPacket: Sendable {
    let bytes: Data
    let decodeTime: Int64
    let presentationTime: Int64
    let duration: UInt32
    let sync: Bool
}

struct FragmentedVideo {
    private(set) var format: CMVideoFormatDescription?
    private(set) var timescale: Int32 = 0
    private(set) var trackID: UInt32 = 0
    private var defaultDuration: UInt32 = 0
    private var defaultSize: UInt32 = 0
    private var defaultFlags: UInt32 = 0
    static let maximumMessageSize = 8 * 1024 * 1024

    mutating func receive(_ data: Data) throws -> [VideoPacket] {
        guard data.count <= Self.maximumMessageSize else { throw VideoStreamError.invalidData }
        let boxes = try MP4Box.read(data)
        if let moov = boxes.first(where: { $0.type == "moov" }) {
            try initialize(data, moov: moov)
            return []
        }
        guard format != nil else { throw VideoStreamError.invalidData }
        var packets: [VideoPacket] = []
        var payloadSize = 0
        for moof in boxes where moof.type == "moof" {
            guard let mdat = boxes.first(where: { $0.type == "mdat" && $0.start > moof.start }) else {
                throw VideoStreamError.invalidData
            }
            for traf in try MP4Box.read(data, range: moof.body) where traf.type == "traf" {
                let next = try fragment(data, moof: moof, traf: traf, mdat: mdat)
                payloadSize += next.reduce(0) { $0 + $1.bytes.count }
                guard packets.count + next.count <= 4096, payloadSize <= Self.maximumMessageSize else {
                    throw VideoStreamError.invalidData
                }
                packets += next
            }
        }
        return packets
    }

    private mutating func initialize(_ data: Data, moov: MP4Box) throws {
        let children = try MP4Box.read(data, range: moov.body)
        for trak in children where trak.type == "trak" {
            let track = try MP4Box.read(data, range: trak.body)
            guard let tkhd = track.first(where: { $0.type == "tkhd" }), tkhd.body.count >= 24,
                  let mdia = track.first(where: { $0.type == "mdia" }) else { continue }
            let media = try MP4Box.read(data, range: mdia.body)
            guard let hdlr = media.first(where: { $0.type == "hdlr" }), hdlr.body.count >= 12,
                  String(decoding: data[(hdlr.body.lowerBound + 8)..<(hdlr.body.lowerBound + 12)], as: UTF8.self) == "vide",
                  let mdhd = media.first(where: { $0.type == "mdhd" }), mdhd.body.count >= 24,
                  let minf = media.first(where: { $0.type == "minf" }),
                  let stbl = try MP4Box.read(data, range: minf.body).first(where: { $0.type == "stbl" }),
                  let stsd = try MP4Box.read(data, range: stbl.body).first(where: { $0.type == "stsd" }) else { continue }
            guard hdlr.body.count >= 12, stsd.body.count >= 8 else { throw VideoStreamError.invalidData }
            let entries = try MP4Box.read(data, range: (stsd.body.lowerBound + 8)..<stsd.body.upperBound)
            guard let entry = entries.first, entry.body.count >= 78,
                  ["avc1", "avc3", "hvc1", "hev1"].contains(entry.type) else { throw VideoStreamError.unsupportedCodec }
            let codec: CMVideoCodecType = entry.type.hasPrefix("avc") ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
            let name = codec == kCMVideoCodecType_H264 ? "avcC" : "hvcC"
            guard let config = try MP4Box.read(data, range: (entry.body.lowerBound + 78)..<entry.body.upperBound)
                .first(where: { $0.type == name }) else { throw VideoStreamError.invalidData }
            let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String:
                                [name: Data(data[config.body])]] as CFDictionary
            let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec,
                width: Int32(try data.u16(entry.body.lowerBound + 24)),
                height: Int32(try data.u16(entry.body.lowerBound + 26)), extensions: extensions,
                formatDescriptionOut: &format)
            guard status == noErr else { throw VideoStreamError.unsupportedCodec }
            trackID = try data.u32(tkhd.body.lowerBound + (data[tkhd.body.lowerBound] == 1 ? 20 : 12))
            let scale = try data.u32(mdhd.body.lowerBound + (data[mdhd.body.lowerBound] == 1 ? 20 : 12))
            guard scale > 0, scale <= Int32.max else { throw VideoStreamError.invalidData }
            timescale = Int32(scale)
            if let mvex = children.first(where: { $0.type == "mvex" }) {
                for trex in try MP4Box.read(data, range: mvex.body) where trex.type == "trex" {
                    guard trex.body.count >= 24 else { throw VideoStreamError.invalidData }
                    if try data.u32(trex.body.lowerBound + 4) == trackID {
                        defaultDuration = try data.u32(trex.body.lowerBound + 12)
                        defaultSize = try data.u32(trex.body.lowerBound + 16)
                        defaultFlags = try data.u32(trex.body.lowerBound + 20)
                    }
                }
            }
            return
        }
        throw VideoStreamError.unsupportedCodec
    }

    private func fragment(_ data: Data, moof: MP4Box, traf: MP4Box, mdat: MP4Box) throws -> [VideoPacket] {
        let children = try MP4Box.read(data, range: traf.body)
        guard let tfhd = children.first(where: { $0.type == "tfhd" }), tfhd.body.count >= 8,
              try data.u32(tfhd.body.lowerBound + 4) == trackID else { return [] }
        var p = tfhd.body.lowerBound + 8
        let flags = try data.u32(tfhd.body.lowerBound) & 0xFFFFFF
        var base = moof.start
        if flags & 1 != 0 {
            let value = try data.u64(p); p += 8
            guard value <= UInt64(data.count) else { throw VideoStreamError.invalidData }
            base = Int(value)
        }
        if flags & 2 != 0 { p += 4 }
        var duration = defaultDuration, size = defaultSize, sampleFlags = defaultFlags
        if flags & 8 != 0 { duration = try data.u32(p); p += 4 }
        if flags & 16 != 0 { size = try data.u32(p); p += 4 }
        if flags & 32 != 0 { sampleFlags = try data.u32(p); p += 4 }
        guard p <= tfhd.body.upperBound, let tfdt = children.first(where: { $0.type == "tfdt" }), tfdt.body.count >= 8 else {
            throw VideoStreamError.invalidData
        }
        let longTime = data[tfdt.body.lowerBound] == 1
        guard !longTime || tfdt.body.count >= 12 else { throw VideoStreamError.invalidData }
        let rawTime = longTime ? try data.u64(tfdt.body.lowerBound + 4) : UInt64(try data.u32(tfdt.body.lowerBound + 4))
        guard rawTime <= UInt64(Int64.max) else { throw VideoStreamError.invalidData }
        var time = Int64(rawTime), offset = mdat.body.lowerBound
        var result: [VideoPacket] = []
        var payloadSize = 0
        for run in children where run.type == "trun" {
            guard run.body.count >= 8 else { throw VideoStreamError.invalidData }
            let runFlags = try data.u32(run.body.lowerBound) & 0xFFFFFF
            let count = try data.u32(run.body.lowerBound + 4)
            guard count <= 4096, result.count + Int(count) <= 4096 else { throw VideoStreamError.invalidData }
            p = run.body.lowerBound + 8
            if runFlags & 1 != 0 { offset = base + Int(Int32(bitPattern: try data.u32(p))); p += 4 }
            var firstFlags: UInt32?
            if runFlags & 4 != 0 { firstFlags = try data.u32(p); p += 4 }
            for index in 0..<count {
                var d = duration, s = size, f = index == 0 ? firstFlags ?? sampleFlags : sampleFlags
                if runFlags & 0x100 != 0 { d = try data.u32(p); p += 4 }
                if runFlags & 0x200 != 0 { s = try data.u32(p); p += 4 }
                if runFlags & 0x400 != 0 { f = try data.u32(p); p += 4 }
                var cts: Int64 = 0
                if runFlags & 0x800 != 0 {
                    let raw = try data.u32(p); p += 4
                    cts = data[run.body.lowerBound] == 1 ? Int64(Int32(bitPattern: raw)) : Int64(raw)
                }
                guard p <= run.body.upperBound, s > 0, offset >= mdat.body.lowerBound,
                      Int(s) <= mdat.body.upperBound - offset, Int64(d) <= Int64.max - time,
                      Int(s) <= Self.maximumMessageSize - payloadSize,
                      cts <= 0 || time <= Int64.max - cts else { throw VideoStreamError.invalidData }
                result.append(VideoPacket(bytes: Data(data[offset..<(offset + Int(s))]), decodeTime: time,
                    presentationTime: time + cts, duration: d, sync: f & 0x10000 == 0))
                offset += Int(s); time += Int64(d)
                payloadSize += Int(s)
            }
        }
        return result
    }

    func sampleBuffer(_ packet: VideoPacket) throws -> sending CMSampleBuffer {
        guard let format, timescale > 0, !packet.bytes.isEmpty else { throw VideoStreamError.invalidData }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: packet.bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: packet.bytes.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { throw VideoStreamError.invalidData }
        let copied = packet.bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: packet.bytes.count)
        }
        guard copied == noErr else { throw VideoStreamError.invalidData }
        var timing = CMSampleTimingInfo(duration: CMTime(value: Int64(packet.duration), timescale: timescale),
            presentationTimeStamp: CMTime(value: packet.presentationTime, timescale: timescale),
            decodeTimeStamp: CMTime(value: packet.decodeTime, timescale: timescale))
        var sample: CMSampleBuffer?, size = packet.bytes.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { throw VideoStreamError.invalidData }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
            first[kCMSampleAttachmentKey_NotSync] = !packet.sync
        }
        return sample
    }
}
