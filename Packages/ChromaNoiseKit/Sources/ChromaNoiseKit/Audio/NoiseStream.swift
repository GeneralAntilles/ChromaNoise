import Foundation

/// Single-channel streaming spectrum-shaped noise: white noise → windowed STFT →
/// per-bin gain multiply → ISTFT → overlap-add. Produces `hop` samples per call.
///
/// Spectral changes need no explicit ramp: with 75% overlap every output sample
/// blends 4 windowed frames, so a gain step inherently crossfades over ~4 hops
/// (~85 ms @ 48 kHz).
public final class NoiseStream {
    private let n = DSPConstants.fftSize
    private let hop = DSPConstants.hop
    private let fft: RealFFT
    private let window: [Float]
    private var noise: WhiteNoise
    private var input: [Float]        // sliding N-sample noise window
    private var ola: [Float]          // overlap-add accumulator, N samples
    private var frame: [Float]
    private var re: [Float]
    private var im: [Float]
    private var synth: [Float]

    /// Active per-bin gain (n/2+1 entries). Swapped atomically-enough by the
    /// worker thread between hops; never touched by the render thread.
    public var gain: [Float]

    public init(seed: UInt64, fft: RealFFT? = nil) {
        self.fft = fft ?? makeRealFFT(size: DSPConstants.fftSize)
        precondition(self.fft.size == n)
        self.window = Windows.periodicHann(n)
        self.noise = WhiteNoise(seed: seed)
        self.input = [Float](repeating: 0, count: n)
        self.ola = [Float](repeating: 0, count: n)
        self.frame = [Float](repeating: 0, count: n)
        self.re = [Float](repeating: 0, count: n / 2 + 1)
        self.im = [Float](repeating: 0, count: n / 2 + 1)
        self.synth = [Float](repeating: 0, count: n)
        self.gain = [Float](repeating: 0, count: n / 2 + 1)
        // Prime the sliding window so the first hops see a full noise frame.
        noise.fill(&input, count: n)
    }

    /// Generate the next `hop` samples into `out[0..<hop]`.
    ///
    /// The element-wise loops run over raw buffer pointers: with Array
    /// subscripts, bounds checks block auto-vectorization and these loops
    /// cost more than the FFT itself. Arithmetic is unchanged.
    public func processHop(into out: inout [Float]) {
        let n = self.n, hop = self.hop
        precondition(out.count >= hop)
        // `gain` is public and indexes re/im unchecked below.
        precondition(gain.count == n / 2 + 1, "gain must have n/2+1 bins")

        // Slide input left by hop, append fresh noise.
        input.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            p.update(from: p + hop, count: n - hop)
        }
        noise.fill(&input, count: hop, at: n - hop)

        // Analysis window → FFT → shape → IFFT → synthesis window.
        Self.multiply(input, window, into: &frame)
        fft.forward(frame, re: &re, im: &im)
        gain.withUnsafeBufferPointer { g in
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { m in
                    for k in 0..<r.count {
                        r[k] *= g[k]
                        m[k] *= g[k]
                    }
                }
            }
        }
        fft.inverse(re: re, im: im, into: &synth)

        // Synthesis window + overlap-add; emit the completed first hop, then
        // shift the accumulator.
        let norm = 1.0 / DSPConstants.colaSum
        synth.withUnsafeMutableBufferPointer { s in
            window.withUnsafeBufferPointer { w in
                ola.withUnsafeMutableBufferPointer { o in
                    for i in 0..<n {
                        s[i] *= w[i]
                        o[i] += s[i]
                    }
                    out.withUnsafeMutableBufferPointer { dst in
                        for i in 0..<hop { dst[i] = o[i] * norm }
                    }
                    let p = o.baseAddress!
                    p.update(from: p + hop, count: n - hop)
                    (p + (n - hop)).update(repeating: 0, count: hop)
                }
            }
        }
    }

    private static func multiply(_ a: [Float], _ b: [Float], into dst: inout [Float]) {
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                dst.withUnsafeMutableBufferPointer { d in
                    for i in 0..<d.count { d[i] = a[i] * b[i] }
                }
            }
        }
    }
}
