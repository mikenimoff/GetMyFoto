import AppKit
import SwiftUI

private struct MediaRowFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newer in newer })
    }
}

/// Native macOS selection supplies Shift-click, Command-click and keyboard
/// navigation. The drag gesture adds an explicit contiguous mouse range and
/// scrolls when the pointer is held at the edge of the viewport.
struct SelectableMediaList<Item: Identifiable, Row: View>: View where Item.ID == String {
    let items: [Item]
    @Binding var selection: Set<String>
    @Binding var anchor: String?
    let enabled: Bool
    @ViewBuilder let row: (Item) -> Row

    @State private var frames: [String: CGRect] = [:]
    @State private var drag: DragSelection?
    @State private var pointerY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    private let scrollClock = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    private struct DragSelection {
        let ids: [String]
        let start: String
        let base: Set<String>
        var end: String
    }

    private var ids: [String] { items.map(\.id) }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                List(items, selection: nativeSelection) { item in
                    row(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .tag(item.id)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: MediaRowFrames.self,
                                value: [item.id: geometry.frame(in: .named("media-selection-list"))])
                        })
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .coordinateSpace(name: "media-selection-list")
                .onPreferenceChange(MediaRowFrames.self) { frames = $0 }
                .simultaneousGesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("media-selection-list"))
                    .onChanged { value in
                        guard enabled else { return }
                        pointerY = value.location.y
                        viewportHeight = viewport.size.height
                        if drag == nil {
                            guard let start = rowID(at: value.startLocation.y) else { return }
                            drag = DragSelection(ids: ids, start: start,
                                base: NSEvent.modifierFlags.contains(.command) ? selection : [], end: start)
                            anchor = start
                        }
                        if let end = rowID(at: value.location.y) { extendDrag(to: end) }
                    }
                    .onEnded { _ in
                        let finalSelection = selection
                        // Ignore the native list's last mouse-up selection update.
                        DispatchQueue.main.async {
                            drag = nil
                            if enabled { selection = finalSelection }
                        }
                    })
                .onReceive(scrollClock) { _ in
                    guard enabled, let drag else { return }
                    let direction = pointerY < 26 ? -1 : pointerY > viewportHeight - 26 ? 1 : 0
                    guard direction != 0 else { return }
                    let visible = drag.ids.enumerated().compactMap { index, id -> Int? in
                        guard let frame = frames[id], frame.maxY > 0, frame.minY < viewportHeight else { return nil }
                        return index
                    }
                    guard let edge = direction < 0 ? visible.min() : visible.max() else { return }
                    let next = max(0, min(drag.ids.count - 1, edge + direction))
                    guard next != edge else { return }
                    extendDrag(to: drag.ids[next])
                    proxy.scrollTo(drag.ids[next], anchor: direction < 0 ? .top : .bottom)
                }
                .onCommand(#selector(NSText.selectAll(_:))) {
                    guard enabled else { return }
                    selection = Set(ids)
                }
                .onExitCommand { if enabled { selection.removeAll() } }
                .onChange(of: enabled) { if !$0 { drag = nil } }
                .onChange(of: ids) { _ in drag = nil; frames = [:] }
            }
        }
    }

    private var nativeSelection: Binding<Set<String>> {
        Binding(get: { selection }, set: { value in
            guard enabled, drag == nil else { return }
            let added = value.subtracting(selection)
            if added.count == 1 && !NSEvent.modifierFlags.contains(.shift) { anchor = added.first }
            selection = value
        })
    }

    private func rowID(at y: CGFloat) -> String? {
        let visible = frames.filter { $0.value.maxY > 0 && $0.value.minY < viewportHeight }
        return visible.min { abs($0.value.midY - y) < abs($1.value.midY - y) }?.key
    }

    private func extendDrag(to end: String) {
        guard var current = drag else { return }
        current.end = end; drag = current
        selection = current.base.union(MediaSelection.range(ids: current.ids, from: current.start, through: end))
    }
}
