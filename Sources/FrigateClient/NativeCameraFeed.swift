import Foundation
import Observation
import WebKit

/// Stable camera identity keeps each decoder and its recovery independent of other tiles.
@MainActor @Observable
final class NativeCameraFeed: Identifiable {
    private(set) var camera: LiveCamera
    var stream: String
    let player: NativeLivePlayer
    nonisolated let id: String

    init(camera: LiveCamera, stream: String, store: WKHTTPCookieStore) {
        id = camera.name
        self.camera = camera
        self.stream = stream
        player = NativeLivePlayer(store: store)
    }

    func update(camera: LiveCamera, stream: String) {
        self.camera = camera
        self.stream = stream
    }
}

enum NativeCameraSelection: Hashable {
    case all
    case camera(String)
}
