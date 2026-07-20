import Foundation

/// Real-input FFT with rfft semantics: N real samples → N/2+1 complex bins.
/// Seam for swapping in a vDSP-backed implementation on Apple platforms once
/// profiling justifies it; PureSwiftFFT is correct everywhere and fast enough
/// (a 4096-point transform is well under the 21 ms hop budget on any target).
public protocol RealFFT: AnyObject {
    var size: Int { get }
    func forward(_ input: [Float], re: inout [Float], im: inout [Float])
    func inverse(re: [Float], im: [Float], into output: inout [Float])
}

/// Iterative radix-2 Cooley-Tukey, Double internally for accuracy, no
/// allocations after init.
public final class PureSwiftFFT: RealFFT {
    public let size: Int
    private let levels: Int
    private let cosTable: [Double]
    private let sinTable: [Double]
    private var reBuf: [Double]
    private var imBuf: [Double]

    public init(size: Int) {
        precondition(size > 0 && (size & (size - 1)) == 0, "size must be a power of 2")
        self.size = size
        self.levels = Int(log2(Double(size)))
        self.cosTable = (0..<size / 2).map { cos(2.0 * Double.pi * Double($0) / Double(size)) }
        self.sinTable = (0..<size / 2).map { sin(2.0 * Double.pi * Double($0) / Double(size)) }
        self.reBuf = [Double](repeating: 0, count: size)
        self.imBuf = [Double](repeating: 0, count: size)
    }

    public func forward(_ input: [Float], re: inout [Float], im: inout [Float]) {
        precondition(input.count == size)
        precondition(re.count == size / 2 + 1 && im.count == size / 2 + 1)
        for i in 0..<size {
            reBuf[i] = Double(input[i])
            imBuf[i] = 0
        }
        transform(inverse: false)
        for k in 0...(size / 2) {
            re[k] = Float(reBuf[k])
            im[k] = Float(imBuf[k])
        }
    }

    public func inverse(re: [Float], im: [Float], into output: inout [Float]) {
        precondition(re.count == size / 2 + 1 && im.count == size / 2 + 1)
        precondition(output.count == size)
        // Rebuild the full Hermitian-symmetric spectrum of a real signal.
        for k in 0...(size / 2) {
            reBuf[k] = Double(re[k])
            imBuf[k] = Double(im[k])
        }
        for k in 1..<(size / 2) {
            reBuf[size - k] = Double(re[k])
            imBuf[size - k] = -Double(im[k])
        }
        transform(inverse: true)
        let scale = 1.0 / Double(size)
        for i in 0..<size {
            output[i] = Float(reBuf[i] * scale)
        }
    }

    private func transform(inverse: Bool) {
        // Bit-reversal permutation.
        var j = 0
        for i in 0..<size {
            if i < j {
                reBuf.swapAt(i, j)
                imBuf.swapAt(i, j)
            }
            var mask = size >> 1
            while mask >= 1 && (j & mask) != 0 {
                j &= ~mask
                mask >>= 1
            }
            j |= mask
        }
        // Butterflies.
        var span = 1
        while span < size {
            let step = size / (span * 2)
            for start in stride(from: 0, to: size, by: span * 2) {
                var twiddleIdx = 0
                for pos in start..<(start + span) {
                    let wr = cosTable[twiddleIdx]
                    let wi = inverse ? sinTable[twiddleIdx] : -sinTable[twiddleIdx]
                    let tr = reBuf[pos + span] * wr - imBuf[pos + span] * wi
                    let ti = reBuf[pos + span] * wi + imBuf[pos + span] * wr
                    reBuf[pos + span] = reBuf[pos] - tr
                    imBuf[pos + span] = imBuf[pos] - ti
                    reBuf[pos] += tr
                    imBuf[pos] += ti
                    twiddleIdx += step
                }
            }
            span *= 2
        }
    }
}
