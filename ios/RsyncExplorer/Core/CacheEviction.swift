import Foundation

/// Pure LRU eviction policy for the on-disk file cache. Kept separate from
/// `FileCache` (which does the I/O) so the decision logic is unit-testable.
enum CacheEviction {
    struct Item: Equatable {
        let url: URL
        let size: Int64
        let lastUsed: Date
    }

    /// Returns the files to delete so the cache drops to `target` bytes, evicting
    /// least-recently-used first. Returns nothing while total size is within
    /// `maxBytes` (eviction only kicks in once the cap is exceeded).
    static func targets(_ items: [Item], maxBytes: Int64, target: Int64) -> [URL] {
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        guard total > maxBytes else { return [] }

        var running = total
        var victims: [URL] = []
        for item in items.sorted(by: { $0.lastUsed < $1.lastUsed }) {   // oldest first
            if running <= target { break }
            victims.append(item.url)
            running -= item.size
        }
        return victims
    }
}
