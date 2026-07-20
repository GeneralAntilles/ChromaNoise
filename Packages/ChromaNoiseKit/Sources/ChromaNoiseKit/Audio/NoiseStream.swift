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
        self.fft = fft ?? PureSwiftFFT(size: DSPConstants.fftSize)
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
    public func processHop(into out: inout [Float]) {
        // Slide input left by hop, append fresh noise.
        for i in 0..<(n - hop) { input[i] = input[i + hop] }
        noise.fill(&input, count: hop, at: n - hop)

        // Analysis window → FFT → shape → IFFT → synthesis window.
        for i in 0..<n { frame[i] = input[i] * window[i] }
        fft.forward(frame, re: &re, im: &im)
        for k in 0...(n / 2) {
            re[k] *= gain[k]
            im[k] *= gain[k]
        }
        fft.inverse(re: re, im: im, into: &synth)
        for i in 0..<n { synth[i] *= window[i] }

        // Overlap-add; emit the completed first hop, then shift the accumulator.
        for i in 0..<n { ola[i] += synth[i] }
        let norm = 1.0 / DSPConstants.colaSum
        for i in 0..<hop { out[i] = ola[i] * norm }
        for i in 0..<(n - hop) { ola[i] = ola[i + hop] }
        for i in (n - hop)..<n { ola[i] = 0 }
    }
}
