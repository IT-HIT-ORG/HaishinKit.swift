import CoreImage
import CoreMedia
import Foundation

protocol IOVideoMixerDelegate: AnyObject {
    func videoMixer(_ videoMixer: IOVideoMixer<Self>, track: UInt8, didInput sampleBuffer: CMSampleBuffer)
    func videoMixer(_ videoMixer: IOVideoMixer<Self>, didOutput sampleBuffer: CMSampleBuffer)
}

private let kIOVideoMixer_lockFlags = CVPixelBufferLockFlags(rawValue: .zero)

final class IOVideoMixer<T: IOVideoMixerDelegate> {
    weak var delegate: T?

    lazy var screen: Screen = {
        var screen = Screen()
        screen.observer = self
        videoTrackScreenObject.track = settings.mainTrack
        try? screen.addChild(videoTrackScreenObject)
        return screen
    }()

    var settings: IOVideoMixerSettings = .default {
        didSet {
            if settings.mainTrack != oldValue.mainTrack {
                videoTrackScreenObject.track = settings.mainTrack
            }
        }
    }

    // `inputFormats` is written from TWO queues and was guarded by neither.
    //
    //   append(_:sampleBuffer:)  ← AVCaptureVideoDataOutput's sample-buffer queue, EVERY FRAME
    //   reset(_:)                ← IOVideoUnit's lockQueue, on attach/detach
    //
    // and the window is STRUCTURAL rather than unlucky: IOVideoUnit.attachCamera does its work
    // inside `session.configuration { … }`, which batches the change and does NOT stop the running
    // session, so frames are still being delivered into append() while reset() mutates the same
    // dictionary. Swift's native Dictionary is not thread-safe; concurrent mutation corrupts its
    // storage. Observed in the field as a fatal, unhandled
    //
    //   -[__NSTaggedDate objectForKey:]: unrecognized selector sent to instance 0x8000000000000000
    //     Dictionary._Variant.removeValue  <-  IOVideoMixer.reset  <-  IOVideoUnit.attachCamera
    //
    // i.e. a read of a freed/garbage slot, on every camera toggle. A lock rather than a queue hop
    // because append() runs per frame and must not pay a dispatch; the critical section is one
    // dictionary write and never calls out (the delegate call below is deliberately outside it, or
    // a re-entrant delegate would deadlock).
    private let inputFormatsLock = NSLock()
    private var storedInputFormats: [UInt8: CMFormatDescription] = [:]
    var inputFormats: [UInt8: CMFormatDescription] {
        inputFormatsLock.lock()
        defer { inputFormatsLock.unlock() }
        return storedInputFormats
    }
    private var currentPixelBuffer: CVPixelBuffer?
    private var videoTrackScreenObject = VideoTrackScreenObject()

    func append(_ track: UInt8, sampleBuffer: CMSampleBuffer) {
        inputFormatsLock.lock()
        storedInputFormats[track] = sampleBuffer.formatDescription
        inputFormatsLock.unlock()
        delegate?.videoMixer(self, track: track, didInput: sampleBuffer)
        switch settings.mode {
        case .offscreen:
            let screens: [VideoTrackScreenObject] = screen.getScreenObjects()
            for screen in screens where screen.track == track {
                screen.enqueue(sampleBuffer)
            }
            if track == settings.mainTrack {
                let diff = ceil((screen.targetTimestamp.value - sampleBuffer.presentationTimeStamp.seconds) * 10000) / 10000
                screen.videoCaptureLatency.mutate { $0 = diff }
            }
        case .passthrough:
            if settings.mainTrack == track {
                outputSampleBuffer(sampleBuffer)
            }
        }
    }

    func registerEffect(_ effect: VideoEffect) -> Bool {
        return videoTrackScreenObject.registerVideoEffect(effect)
    }

    func unregisterEffect(_ effect: VideoEffect) -> Bool {
        return videoTrackScreenObject.unregisterVideoEffect(effect)
    }

    func reset(_ track: UInt8) {
        inputFormatsLock.lock()
        storedInputFormats[track] = nil
        inputFormatsLock.unlock()
        let screens: [VideoTrackScreenObject] = screen.getScreenObjects()
        for screen in screens where screen.track == track {
            screen.reset()
        }
    }

    @inline(__always)
    private func outputSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        defer {
            currentPixelBuffer = sampleBuffer.imageBuffer
        }
        guard settings.isMuted else {
            delegate?.videoMixer(self, didOutput: sampleBuffer)
            return
        }
        do {
            try sampleBuffer.imageBuffer?.mutate(kIOVideoMixer_lockFlags) { imageBuffer in
                try imageBuffer.copy(currentPixelBuffer)
            }
            delegate?.videoMixer(self, didOutput: sampleBuffer)
        } catch {
            logger.warn(error)
        }
    }
}

extension IOVideoMixer: ScreenObserver {
    func screen(_ screen: Screen, didOutput sampleBuffer: CMSampleBuffer) {
        guard settings.mode == .offscreen else {
            return
        }
        outputSampleBuffer(sampleBuffer)
    }
}
