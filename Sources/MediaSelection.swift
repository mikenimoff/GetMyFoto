import Foundation

enum MediaSelection {
    static func range(ids: [String], from start: String, through end: String) -> Set<String> {
        guard let first = ids.firstIndex(of: start), let last = ids.firstIndex(of: end) else { return [] }
        return Set(ids[min(first, last)...max(first, last)])
    }

    static func batch(ids: [String], count: Int, startingAt start: Int) -> [String] {
        guard count > 0, start >= 0, start < ids.count else { return [] }
        let length = min(count, ids.count - start)
        return Array(ids[start..<(start + length)])
    }
}
