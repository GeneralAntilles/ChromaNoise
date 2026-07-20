import Atomics
import Foundation

/// Single-producer single-consumer lock-free ring of stereo Float frames.
/// Producer: the worker thread (`write`). Consumer: the audio render thread
/// (`read`) — which must never allocate, lock, or retain, so the storage is
/// raw pointers allocated once at init and the indices are atomics.
public final class RenderRingBuffer {
    private let capacity: Int          // power of two, in frames
    private let mask: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let head = ManagedAtomic<Int>(0)   // written frames (producer)
    private let tail = ManagedAtomic<Int>(0)   // consumed frames (consumer)

    public init(capacityFrames: Int) {
        var cap = 1
        while cap < capacityFrames { cap <<= 1 }
        self.capacity = cap
        self.mask = cap - 1
        self.left = .allocate(capacity: cap)
        self.right = .allocate(capacity: cap)
        left.initialize(repeating: 0, count: cap)
        right.initialize(repeating: 0, count: cap)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    public var availableToRead: Int {
        head.load(ordering: .acquiring) - tail.load(ordering: .relaxed)
    }

    public var availableToWrite: Int {
        capacity - (head.load(ordering: .relaxed) - tail.load(ordering: .acquiring))
    }

    /// Producer side. Returns frames actually written (0 if full).
    @discardableResult
    public func write(left srcL: [Float], right srcR: [Float], count: Int) -> Int {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let toWrite = min(count, capacity - (h - t))
        guard toWrite > 0 else { return 0 }
        for i in 0..<toWrite {
            let idx = (h + i) & mask
            left[idx] = srcL[i]
            right[idx] = srcR[i]
        }
        head.store(h + toWrite, ordering: .releasing)
        return toWrite
    }

    /// Consumer side (render thread). Fills any shortfall with silence and
    /// returns the number of real frames delivered.
    @discardableResult
    public func read(
        into dstL: UnsafeMutablePointer<Float>,
        _ dstR: UnsafeMutablePointer<Float>,
        count: Int
    ) -> Int {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let toRead = min(count, h - t)
        for i in 0..<toRead {
            let idx = (t + i) & mask
            dstL[i] = left[idx]
            dstR[i] = right[idx]
        }
        if toRead < count {
            for i in toRead..<count {
                dstL[i] = 0
                dstR[i] = 0
            }
        }
        tail.store(t + toRead, ordering: .releasing)
        return toRead
    }
}
