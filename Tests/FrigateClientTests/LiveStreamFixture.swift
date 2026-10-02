import CryptoKit
import Foundation
import Network
@testable import FrigateClient

final class LiveStreamFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LiveStreamFixture")
    private let initialize: Data
    private let packets: [VideoPacket]
    private let timescale: UInt32
    private var connections: [NWConnection] = []
    private var streamsOpened = 0
    private var available = true
    private var stall = false
    private let closeFirst: Bool
    private let config: String
    private let skipInitialKeyframe: Bool
    private var selectedStreams: [String] = []

    init(closeFirst: Bool = false, stall: Bool = false, videoData: Data? = nil, skipInitialKeyframe: Bool = false,
         config: String = #"{"cameras":{"example":{"enabled":true,"live":{"streams":{"Main":"example"}}}}}"#) throws {
        self.closeFirst = closeFirst
        self.stall = stall
        self.config = config
        self.skipInitialKeyframe = skipInitialKeyframe
        let (initialize, fragments) = try videoData.map { try fragmentedFixture($0) } ?? videoFixture()
        self.initialize = initialize
        var parser = FragmentedVideo()
        _ = try parser.receive(initialize)
        timescale = UInt32(parser.timescale)
        packets = try fragments.flatMap { try parser.receive($0) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    var port: UInt16? {
        guard let port = listener.port?.rawValue, port > 0 else { return nil }
        return port
    }
    var opened: Int { queue.sync { streamsOpened } }
    var requestedStreams: [String] { queue.sync { selectedStreams } }
    func setUnavailable() { queue.sync { available = false; connections.forEach { $0.cancel() } } }
    func stop() { queue.sync { connections.forEach { $0.cancel() }; connections.removeAll(); listener.cancel() } }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { connection.cancel(); return }
            let request = buffer + data
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                self.receive(connection, buffer: request); return
            }
            guard self.available else { self.respond(connection, code: 503, body: "Unavailable"); return }
            if text.contains("Upgrade: websocket") || text.lowercased().contains("upgrade: websocket") {
                let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                if let src = URLComponents(string: "http://fixture" + path)?.queryItems?.first(where: { $0.name == "src" })?.value {
                    self.selectedStreams.append(src)
                }
                let key = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
                    .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
                let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                let handshake = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                self.streamsOpened += 1
                let number = self.streamsOpened
                connection.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self] error in
                    guard error == nil, let self else { connection.cancel(); return }
                    self.sendFrame(connection, data: self.initialize)
                    self.sendVideo(connection, index: self.skipInitialKeyframe ? 1 : 0, time: 0, connectionNumber: number)
                })
            } else if text.hasPrefix("GET /api/config ") {
                self.respond(connection, code: 200, body: self.config)
            } else { self.respond(connection, code: 200, body: "test-version") }
        }
    }

    private func respond(_ connection: NWConnection, code: Int, body: String) {
        let text = "HTTP/1.1 \(code) OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendFrame(_ connection: NWConnection, data: Data) {
        var frame = Data([0x82])
        if data.count < 126 { frame.append(UInt8(data.count)) }
        else if data.count <= 65535 {
            frame.append(126); frame.append(UInt8(data.count >> 8)); frame.append(UInt8(data.count & 255))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(data.count) >> shift) & 255)) }
        }
        frame.append(data)
        connection.send(content: frame, completion: .contentProcessed { if $0 != nil { connection.cancel() } })
    }

    private func sendVideo(_ connection: NWConnection, index: Int, time: UInt64, connectionNumber: Int) {
        guard available, connection.state == .ready else { return }
        if index == 10, closeFirst, connectionNumber == 1 { connection.cancel(); return }
        if index > 0, stall { return }
        let packet = packets[index % packets.count]
        let tfhd = box("tfhd", word(0x20038) + word(1) + word(packet.duration) + word(UInt32(packet.bytes.count)) + word(packet.sync ? 0 : 0x10000))
        let tfdt = box("tfdt", word(0x01000000) + word(UInt32(time >> 32)) + word(UInt32(time & 0xFFFFFFFF)))
        func fragment(offset: UInt32) -> Data {
            box("moof", box("mfhd", word(0) + word(UInt32(index + 1))) + box("traf", tfhd + tfdt + box("trun", word(1) + word(1) + word(offset))))
        }
        let moof = fragment(offset: UInt32(fragment(offset: 0).count + 8))
        sendFrame(connection, data: moof + box("mdat", packet.bytes))
        let duration = max(0.02, Double(packet.duration) / Double(timescale))
        queue.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.sendVideo(connection, index: index + 1, time: time + UInt64(packet.duration), connectionNumber: connectionNumber)
        }
    }
}

private func word(_ value: UInt32) -> Data {
    Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
}
private func box(_ name: String, _ payload: Data) -> Data { word(UInt32(payload.count + 8)) + Data(name.utf8) + payload }
