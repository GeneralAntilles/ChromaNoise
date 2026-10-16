import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Real-input FFT with rfft semantics: N real samples → N/2+1 complex bins.
/// `VDSPRealFFT` is the fast path on Apple platforms; `PureSwiftFFT` is the
/// portable reference (Linux) and the ground truth the vDSP one is tested against.
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

/// The fastest correct `RealFFT` for this platform: vDSP on Apple platforms,
/// the portable implementation elsewhere (Linux CI).
public func makeRealFFT(size: Int) -> RealFFT {
    #if canImport(Accelerate)
    return VDSPRealFFT(size: size)
    #else
    return PureSwiftFFT(size: size)
    #endif
}

#if canImport(Accelerate)
/// vDSP-backed real FFT with the same rfft/irfft semantics as `PureSwiftFFT`.
/// vDSP's real DFT works on the signal packed as N/2 complex values (even
/// samples real, odd imaginary), returns 2× the mathematical DFT, and packs
/// the purely real Nyquist bin into the imaginary slot of bin 0. This class
/// hides all of that. No allocations after init.
public final class VDSPRealFFT: RealFFT {
    public let size: Int
    private let half: Int
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup
    private var packedRe: [Float]
    private var packedIm: [Float]
    private var resultRe: [Float]
    private var resultIm: [Float]

    public init(size: Int) {
        precondition(size >= 16 && (size & (size - 1)) == 0, "size must be a power of 2 ≥ 16")
        guard let forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD),
              let inverse = vDSP_DFT_zrop_CreateSetup(forward, vDSP_Length(size), .INVERSE)
        else { preconditionFailure("vDSP rejected DFT size \(size)") }
        self.size = size
        self.half = size / 2
        self.forwardSetup = forward
        self.inverseSetup = inverse
        self.packedRe = [Float](repeating: 0, count: size / 2)
        self.packedIm = [Float](repeating: 0, count: size / 2)
        self.resultRe = [Float](repeating: 0, count: size / 2)
        self.resultIm = [Float](repeating: 0, count: size / 2)
    }

    deinit {
        vDSP_DFT_DestroySetup(inverseSetup)
        vDSP_DFT_DestroySetup(forwardSetup)
    }

    public func forward(_ input: [Float], re: inout [Float], im: inout [Float]) {
        precondition(input.count == size)
        precondition(re.count == half + 1 && im.count == half + 1)
        let half = self.half
        input.withUnsafeBufferPointer { x in
            packedRe.withUnsafeMutableBufferPointer { pr in
                packedIm.withUnsafeMutableBufferPointer { pi in
                    for j in 0..<half {
                        pr[j] = x[2 * j]
                        pi[j] = x[2 * j + 1]
                    }
                }
            }
        }
        vDSP_DFT_Execute(forwardSetup, packedRe, packedIm, &resultRe, &resultIm)
        // Undo vDSP's 2× and unpack DC / Nyquist.
        resultRe.withUnsafeBufferPointer { rr in
            resultIm.withUnsafeBufferPointer { ri in
                re.withUnsafeMutableBufferPointer { r in
                    im.withUnsafeMutableBufferPointer { m in
                        r[0] = rr[0] * 0.5
                        m[0] = 0
                        r[half] = ri[0] * 0.5
                        m[half] = 0
                        for k in 1..<half {
                            r[k] = rr[k] * 0.5
                            m[k] = ri[k] * 0.5
                        }
                    }
                }
            }
        }
    }

    public func inverse(re: [Float], im: [Float], into output: inout [Float]) {
        precondition(re.count == half + 1 && im.count == half + 1)
        precondition(output.count == size)
        let half = self.half
        re.withUnsafeBufferPointer { r in
            im.withUnsafeBufferPointer { m in
                packedRe.withUnsafeMutableBufferPointer { pr in
                    packedIm.withUnsafeMutableBufferPointer { pi in
                        pr[0] = r[0]
                        pi[0] = r[half]
                        for k in 1..<half {
                            pr[k] = r[k]
                            pi[k] = m[k]
                        }
                    }
                }
            }
        }
        vDSP_DFT_Execute(inverseSetup, packedRe, packedIm, &resultRe, &resultIm)
        // vDSP's inverse is unnormalized (×N for a standard spectrum).
        let scale = 1 / Float(size)
        resultRe.withUnsafeBufferPointer { rr in
            resultIm.withUnsafeBufferPointer { ri in
                output.withUnsafeMutableBufferPointer { y in
                    for j in 0..<half {
                        y[2 * j] = rr[j] * scale
                        y[2 * j + 1] = ri[j] * scale
                    }
                }
            }
        }
    }
}
#endif
