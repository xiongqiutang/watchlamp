import AVFoundation

/// `Watchlamp play-sound <file> <volume>`: the alert player. Chime starts it as its own short-lived process, so the
/// audio machinery (devices, threads, several MB) never loads into the app itself.
/// The volume is a gain. Up to 1 it turns the sound down; past 1 a peak limiter raises its loudness without clipping,
/// so an alert can stand out over other apps at the same system volume.
enum Player {
    static func run(_ path: String, volume: Double) -> Int32 {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return 1 }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        engine.attach(player)
        engine.attach(limiter)
        engine.connect(player, to: limiter, format: file.processingFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: file.processingFormat)
        let gain = min(max(volume, 0.01), 4)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0,
                              Float(gain > 1 ? 20 * log10(gain) : 0), 0)
        engine.mainMixerNode.outputVolume = Float(min(gain, 1))

        let done = DispatchSemaphore(value: 0)
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in done.signal() }
        do { try engine.start() } catch { return 1 }
        player.play()
        _ = done.wait(timeout: .now() + 30)
        usleep(150_000)   // let the limiter's release ring out
        engine.stop()
        return 0
    }
}
