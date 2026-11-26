import AppKit
import SwiftUI
import ImageCaptureCore

/// Main-thread coordinator. Only visible rows enqueue work; decoded images stay
/// in memory and are never written beside the user's imports or uploaded.
final class ThumbnailStore: ObservableObject {
    static let shared = ThumbnailStore()
    @Published private(set) var revision = 0
    private let cache = NSCache<NSString, NSImage>()
    private struct Request {
        let file: ICCameraFile
        var listeners: [UUID: (NSImage?) -> Void]
    }
    private var requests: [String: Request] = [:]
    private var waiting: [String] = []
    private var active = Set<String>()
    private var unavailable: [String: Date] = [:]
    private var generation = UUID()

    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    func request(_ item: MediaItem, token: UUID, completion: @escaping (NSImage?) -> Void) {
        if let image = cached(item.id) { completion(image); return }
        guard item.kind != "Другое" else { completion(nil); return }
        if let failedAt = unavailable[item.id], Date().timeIntervalSince(failedAt) < 10 { completion(nil); return }
        if var request = requests[item.id] {
            request.listeners[token] = completion
            requests[item.id] = request
        } else {
            requests[item.id] = Request(file: item.file, listeners: [token: completion])
            waiting.append(item.id)
        }
        pump()
    }

    func cancel(_ key: String, token: UUID) {
        guard var request = requests[key] else { return }
        request.listeners.removeValue(forKey: token)
        requests[key] = request
        if request.listeners.isEmpty && !active.contains(key) {
            requests.removeValue(forKey: key)
            waiting.removeAll { $0 == key }
        }
    }

    func resetConnection() {
        generation = UUID()
        let callbacks = requests.values.flatMap { Array($0.listeners.values) }
        requests.removeAll(); waiting.removeAll(); active.removeAll(); unavailable.removeAll()
        for callback in callbacks { callback(nil) }
        revision += 1
    }

    private func pump() {
        while active.count < 3 && !waiting.isEmpty {
            let key = waiting.removeFirst()
            guard let request = requests[key], !request.listeners.isEmpty else {
                requests.removeValue(forKey: key)
                continue
            }
            active.insert(key)
            let session = generation
            request.file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: 160]) { [weak self] data, error in
                DispatchQueue.main.async {
                    guard let self, self.generation == session, self.active.contains(key) else { return }
                    let image = error == nil ? data.flatMap { NSImage(data: $0) } : nil
                    if let image {
                        self.finish(key, image: image)
                    } else if let thumbnail = request.file.thumbnail {
                        self.finish(key, image: NSImage(cgImage: thumbnail, size: .zero))
                        request.file.flushThumbnailCache()
                    } else {
                        // Some iOS drivers only provide the embedded thumbnail via
                        // the delegate API, rather than custom-size thumbnail data.
                        request.file.requestThumbnail()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                            guard let self, self.generation == session else { return }
                            self.finish(key, image: nil)
                        }
                    }
                }
            }
        }
    }

    func receive(_ thumbnail: CGImage?, for item: ICCameraItem) {
        guard let entry = requests.first(where: { $0.value.file === item }), active.contains(entry.key) else { return }
        finish(entry.key, image: thumbnail.map { NSImage(cgImage: $0, size: .zero) })
        item.flushThumbnailCache()
    }

    private func finish(_ key: String, image: NSImage?) {
        guard active.remove(key) != nil else { return }
        if let image {
            let representation = image.representations.first
            let cost = max(1, representation?.pixelsWide ?? 160) * max(1, representation?.pixelsHigh ?? 160) * 4
            cache.setObject(image, forKey: key as NSString, cost: cost)
            unavailable.removeValue(forKey: key)
        } else { unavailable[key] = Date() }
        let callbacks = requests.removeValue(forKey: key)?.listeners.values
        if let callbacks { for callback in callbacks { callback(image) } }
        pump()
    }
}

struct MediaThumbnail: View {
    let item: MediaItem
    let enabled: Bool
    @State private var image: NSImage?
    @State private var requestToken: UUID?
    @State private var loading = false
    @ObservedObject private var store = ThumbnailStore.shared
    private let size: CGFloat = 58

    var body: some View {
        ZStack {
            Color(nsColor: .quaternaryLabelColor).opacity(0.16)
            if let image {
                Image(nsImage: image).resizable().scaledToFill().frame(width: size, height: size).clipped()
            } else {
                Image(systemName: item.symbol).font(.system(size: 21)).foregroundStyle(.secondary)
            }
            if item.kind == "Видео" && image != nil {
                VStack { Spacer(); HStack { Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(.white).padding(5).background(.black.opacity(0.6), in: Circle()); Spacer() } }.padding(3)
            }
            if loading { VStack { Spacer(); HStack { Spacer(); ProgressView().controlSize(.mini).padding(4) } } }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(image == nil ? item.kind : "Миниатюра: \(item.name)")
        .onAppear { load() }
        .onDisappear { cancel() }
        .onChange(of: enabled) { _ in load() }
        .onChange(of: ObjectIdentifier(item.file)) { _ in load() }
        .onChange(of: store.revision) { _ in load() }
    }

    private func load() {
        cancel()
        if let cached = ThumbnailStore.shared.cached(item.id) { image = cached; return }
        guard enabled, item.kind != "Другое" else { return }
        let token = UUID()
        requestToken = token; loading = true
        ThumbnailStore.shared.request(item, token: token) { result in
            guard requestToken == token else { return }
            image = result; loading = false
        }
    }

    private func cancel() {
        if let token = requestToken { ThumbnailStore.shared.cancel(item.id, token: token) }
        requestToken = nil; loading = false
    }
}
