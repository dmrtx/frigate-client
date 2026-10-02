import SwiftUI

struct NativeLiveView: View {
    let connection: ConnectionController

    private var selection: NativeCameraSelection {
        connection.showsAllCameras ? .all : .camera(connection.selectedCamera)
    }

    var body: some View {
        VStack(spacing: 6) {
            if connection.state == .connected, !connection.nativeFeeds.isEmpty {
                HStack {
                    Picker("Cameras", selection: Binding(get: { selection }, set: { selected in
                        switch selected {
                        case .all: connection.showAllCameras()
                        case .camera(let name): connection.selectCamera(name)
                        }
                    })) {
                        Text("All cameras").tag(NativeCameraSelection.all)
                        ForEach(connection.nativeFeeds) { feed in
                            Text(feed.camera.name).tag(NativeCameraSelection.camera(feed.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }
            if connection.showsAllCameras, connection.nativeFeeds.count > 1 {
                GeometryReader { geometry in
                    let widthColumns = max(1, Int(geometry.size.width / 320))
                    let countColumns = max(1, Int(ceil(sqrt(Double(connection.nativeFeeds.count)))))
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6),
                                                 count: min(widthColumns, countColumns)), spacing: 6) {
                            ForEach(connection.nativeFeeds) { feed in
                                NativeCameraTile(feed: feed, connection: connection, showsName: true)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
            } else if let feed = connection.activeFeed ?? connection.nativeFeeds.first {
                NativeCameraTile(feed: feed, connection: connection, showsName: false)
                    .id(feed.id)
            } else {
                Text("No enabled cameras were found.")
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.black)
    }
}

private struct NativeCameraTile: View {
    let feed: NativeCameraFeed
    let connection: ConnectionController
    let showsName: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            NativeVideoSurface(renderer: feed.player.renderer, visibilityChanged: { visible in
                connection.setCameraVisible(feed.id, visible)
            })
            if !feed.player.isPlaying {
                VStack(spacing: 8) {
                    Text(feed.player.message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                    if feed.player.recoveryPaused {
                        Button("Reconnect") { connection.reconnectCamera(feed.id) }
                    }
                }
                .padding(12)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 6) {
                if showsName {
                    Text(feed.camera.name).font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                }
                if feed.camera.streamOptions.count > 1 {
                    Picker("Stream for \(feed.camera.name)", selection: Binding(get: { feed.stream }, set: {
                        connection.selectStream($0, for: feed.id)
                    })) {
                        ForEach(feed.camera.streamOptions) { stream in Text(stream.label).tag(stream.name) }
                    }
                    .labelsHidden().fixedSize().controlSize(.small)
                }
                Spacer()
            }
            .padding(6)
        }
        .background(.black)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera \(feed.camera.name)")
        .onDisappear { connection.setCameraVisible(feed.id, false) }
    }
}
