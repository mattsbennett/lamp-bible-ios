//
//  AudioPlayer.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-19.
//

import Foundation
import AVFoundation
import Combine
import MediaPlayer
import Observation

/// Observable audio player for devotional audio blocks
class AudioPlayer: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var error: Error?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadedURL: URL?

    override init() {
        super.init()
    }

    deinit {
        stopTimer()
        player?.stop()
    }

    // MARK: - Loading

    /// Load audio from a URL
    func load(url: URL) {
        // Don't reload if already loaded
        if loadedURL == url && player != nil {
            return
        }

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.prepareToPlay()
            duration = player?.duration ?? 0
            loadedURL = url
            error = nil

            // Reset state
            currentTime = 0
            progress = 0
            isPlaying = false
        } catch {
            self.error = error
            print("[AudioPlayer] Load error: \(error.localizedDescription)")
        }
    }

    /// Check if a URL is currently loaded
    func isLoaded(url: URL) -> Bool {
        return loadedURL == url && player != nil
    }

    // MARK: - Playback Control

    /// Toggle between play and pause
    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Start or resume playback
    func play() {
        guard let player = player else { return }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AudioPlayer] Audio session error: \(error.localizedDescription)")
        }

        player.play()
        isPlaying = true
        startTimer()
    }

    /// Pause playback
    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    /// Stop playback and reset to beginning
    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        stopTimer()
        currentTime = 0
        progress = 0
    }

    // MARK: - Seeking

    /// Seek to a specific progress (0-1)
    func seek(to progress: Double) {
        guard let player = player else { return }
        let clampedProgress = max(0, min(1, progress))
        let time = duration * clampedProgress
        player.currentTime = time
        updateProgress()
    }

    /// Seek to a specific time in seconds
    func seek(toTime time: TimeInterval) {
        guard let player = player else { return }
        let clampedTime = max(0, min(duration, time))
        player.currentTime = clampedTime
        updateProgress()
    }

    /// Skip forward by a number of seconds
    func skipForward(seconds: TimeInterval = 15) {
        seek(toTime: currentTime + seconds)
    }

    /// Skip backward by a number of seconds
    func skipBackward(seconds: TimeInterval = 15) {
        seek(toTime: currentTime - seconds)
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateProgress()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateProgress() {
        guard let player = player else { return }
        currentTime = player.currentTime
        progress = duration > 0 ? currentTime / duration : 0
    }
}

enum TextSpeechPlaybackState: Equatable {
    case idle
    case speaking
    case paused
}

/// One speakable run of text, tagged with the verse it came from when it has one.
/// The tag is what lets the reader follow along with what's being spoken.
struct TextSpeechSegment: Equatable {
    let text: String
    let verseId: Int?

    init(text: String, verseId: Int? = nil) {
        self.text = text
        self.verseId = verseId
    }
}

/// What to read aloud. Carries the display strings so the transport bar and the
/// Lock Screen name the passage rather than showing a generic label.
struct TextSpeechRequest: Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let segments: [TextSpeechSegment]
    let languageCode: String?
    /// Speaking pace, taken from the user's reading-rate setting so audio matches
    /// the plan time estimates the app shows for the same passage.
    let wordsPerMinute: Double

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        segments: [TextSpeechSegment],
        languageCode: String? = nil,
        wordsPerMinute: Double
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.segments = segments
        self.languageCode = languageCode
        self.wordsPerMinute = wordsPerMinute
    }

    /// Whether the text is divided into verses. Position controls — scrubbing and
    /// verse skip — have nothing to move between without them, so callers hide
    /// those rather than offer controls that do nothing.
    var hasVerseStructure: Bool {
        segments.contains { $0.verseId != nil }
    }

    /// For text with no verse structure, such as a quiz question.
    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        text: String,
        languageCode: String? = nil,
        wordsPerMinute: Double
    ) {
        self.init(
            id: id,
            title: title,
            subtitle: subtitle,
            segments: [TextSpeechSegment(text: text)],
            languageCode: languageCode,
            wordsPerMinute: wordsPerMinute
        )
    }

    var isEmpty: Bool {
        segments.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Which installed voice reads a given language, and whether one exists at all.
///
/// Without this, `AVSpeechUtterance` falls back to the device-locale voice when no
/// voice matches, which reads Greek or Hebrew scripture with English phonetics and
/// no indication anything is wrong.
enum SpeechVoiceCatalog {
    private static let preferenceKeyPrefix = "readAloudVoice."

    /// Installed voices for an ISO 639-1 code, higher-quality ones first.
    ///
    /// Novelty voices ("Bad News", "Bells", "Bubbles") and Personal Voice are
    /// excluded: the former are useless for scripture and sort to the front on
    /// name, and the latter needs an authorization prompt we don't ask for.
    static func voices(for languageCode: String?) -> [AVSpeechSynthesisVoice] {
        guard let base = normalized(languageCode) else { return [] }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                let language = voice.language.lowercased()
                guard language == base || language.hasPrefix("\(base)-") else { return false }
                return !voice.voiceTraits.contains(.isNoveltyVoice)
                    && !voice.voiceTraits.contains(.isPersonalVoice)
            }
            .sorted { lhs, rhs in
                if lhs.quality.rawValue != rhs.quality.rawValue {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name < rhs.name
            }
    }

    static func hasVoice(for languageCode: String?) -> Bool {
        !voices(for: languageCode).isEmpty
    }

    /// The user's pick for this language, else the voice the system itself would
    /// use, else the best remaining one. `nil` means nothing is installed — callers
    /// must not fall through to the device-locale voice.
    static func preferredVoice(for languageCode: String?) -> AVSpeechSynthesisVoice? {
        let available = voices(for: languageCode)
        guard let base = normalized(languageCode) else { return nil }

        if let identifier = UserDefaults.standard.string(forKey: preferenceKeyPrefix + base),
           let chosen = available.first(where: { $0.identifier == identifier }) {
            return chosen
        }

        // Prefer whatever the system considers this language's voice — Samantha for
        // English, not whichever name happens to sort first.
        if let systemDefault = AVSpeechSynthesisVoice(language: base),
           let match = available.first(where: { $0.identifier == systemDefault.identifier }) {
            return match
        }

        return available.first
    }

    /// Pass `nil` to go back to the best available voice.
    static func setPreferredVoiceIdentifier(_ identifier: String?, for languageCode: String?) {
        guard let base = normalized(languageCode) else { return }
        let key = preferenceKeyPrefix + base
        if let identifier {
            UserDefaults.standard.set(identifier, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func preferredVoiceIdentifier(for languageCode: String?) -> String? {
        guard let base = normalized(languageCode) else { return nil }
        return UserDefaults.standard.string(forKey: preferenceKeyPrefix + base)
    }

    /// "Language Name — Voice Name", e.g. "English (US) — Samantha".
    static func displayName(for voice: AVSpeechSynthesisVoice) -> String {
        let locale = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        return "\(voice.name) — \(locale)"
    }

    /// `nil` when the language is unknown, so callers can word themselves around
    /// the gap instead of splicing a placeholder into a sentence.
    static func languageName(for languageCode: String?) -> String? {
        guard let base = normalized(languageCode) else { return nil }
        return Locale.current.localizedString(forLanguageCode: base) ?? base
    }

    private static func normalized(_ languageCode: String?) -> String? {
        guard let languageCode, !languageCode.isEmpty else { return nil }
        let lowered = languageCode.lowercased()
        return lowered.split(separator: "-").first.map(String.init) ?? lowered
    }
}

/// Observable text-to-speech controller backed by AVSpeechSynthesizer.
/// `@Observable` rather than `ObservableObject` on purpose. `spokenFraction`
/// advances once per spoken word, and `ObservableObject` invalidates every
/// observer of the object whenever any `@Published` changes — which would drag
/// the reader's body, and its text layout, through a rebuild several times a
/// second. Per-property observation confines that cost to the small views that
/// actually read progress.
@Observable
final class TextSpeechController: NSObject {
    /// Words per minute Apple's default voice speaks at
    /// `AVSpeechUtteranceDefaultSpeechRate`. Everything about pacing is derived
    /// from this reference point.
    private static let referenceWordsPerMinute = 175.0
    /// Characters per second at the reference rate. AVSpeechSynthesizer exposes no
    /// real duration and Now Playing needs one for its scrubber to move, so the
    /// character count is converted into an estimate.
    private static let referenceCharactersPerSecond = 14.5

    private(set) var playbackState: TextSpeechPlaybackState = .idle
    private(set) var currentSpeechId: String?
    private(set) var title: String = ""
    private(set) var subtitle: String?
    /// Verse being spoken, for callers that want to follow along. Changes roughly
    /// once a verse rather than once a word.
    private(set) var currentVerseId: Int?

    /// Fraction of the queued text spoken so far. Advances once per word — read it
    /// only from small, isolated views.
    private(set) var spokenFraction: Double = 0

    /// Estimated total run time of the queued text, for progress readouts.
    var estimatedDuration: TimeInterval {
        let charactersPerSecond = Self.referenceCharactersPerSecond
            * (activeWordsPerMinute / Self.referenceWordsPerMinute)
        return Double(totalCharacterCount) / max(charactersPerSecond, 1)
    }

    private var synthesizer = AVSpeechSynthesizer()
    /// Retained so a scrub can re-queue from an arbitrary segment. The synthesizer
    /// has no seek API, so "seeking" means discarding the queue and speaking again
    /// from the target segment.
    private var queuedSegments: [TextSpeechSegment] = []
    private var activeVoice: AVSpeechSynthesisVoice?
    private var queuedUtteranceCount = 0
    private var completedUtteranceCount = 0
    /// UTF-16 offset of each queued segment within the whole text, so a
    /// per-word callback resolves to overall progress without re-measuring.
    private var segmentStartOffsets: [Int] = []
    /// Verse behind each queued utterance, parallel to `segmentStartOffsets`.
    private var segmentVerseIds: [Int?] = []
    private var totalCharacterCount = 0
    private var activeWordsPerMinute = TextSpeechController.referenceWordsPerMinute
    private var interruptionObserver: NSObjectProtocol?
    private var hasRemoteCommands = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    deinit {
        synthesizer.stopSpeaking(at: .immediate)
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if hasRemoteCommands {
            for command in Self.handledRemoteCommands {
                command.removeTarget(nil)
                command.isEnabled = false
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    func isActive(for id: String) -> Bool {
        currentSpeechId == id && playbackState != .idle
    }

    func isPlaying(for id: String) -> Bool {
        currentSpeechId == id && playbackState == .speaking
    }

    /// Speaking, whatever the passage — for controls that only appear while
    /// something is already playing and so don't need to identify it.
    var isPlayingAnything: Bool {
        playbackState == .speaking
    }

    func toggle(_ request: TextSpeechRequest) {
        guard !request.isEmpty else { return }

        if currentSpeechId == request.id {
            switch playbackState {
            case .speaking:
                pause()
            case .paused:
                resume()
            case .idle:
                speak(request)
            }
        } else {
            speak(request)
        }
    }

    func speak(_ request: TextSpeechRequest) {
        let segments = Self.chunked(request.segments)
        guard !segments.isEmpty else { return }
        // Refuse rather than let AVSpeechUtterance fall back to the device-locale
        // voice, which would read the passage with the wrong phonetics.
        guard let voice = SpeechVoiceCatalog.preferredVoice(for: request.languageCode) else { return }

        replaceSynthesizer()
        configureAudioSession()
        observeInterruptions()
        registerRemoteCommands()

        currentSpeechId = request.id
        title = request.title
        subtitle = request.subtitle
        queuedSegments = segments
        activeVoice = voice
        queuedUtteranceCount = segments.count
        completedUtteranceCount = 0
        activeWordsPerMinute = request.wordsPerMinute
        spokenFraction = 0

        var offsets: [Int] = []
        var runningTotal = 0
        for segment in segments {
            offsets.append(runningTotal)
            runningTotal += segment.text.utf16.count
        }
        segmentStartOffsets = offsets
        segmentVerseIds = segments.map(\.verseId)
        totalCharacterCount = max(runningTotal, 1)

        playbackState = .speaking
        currentVerseId = segments.first?.verseId

        enqueue(from: 0)
        updateNowPlaying()
    }

    private func enqueue(from index: Int) {
        guard let activeVoice, queuedSegments.indices.contains(index) else { return }
        let rate = Self.rate(forWordsPerMinute: activeWordsPerMinute)
        for segment in queuedSegments[index...] {
            let utterance = AVSpeechUtterance(string: segment.text)
            utterance.voice = activeVoice
            utterance.rate = rate
            utterance.postUtteranceDelay = 0.08
            synthesizer.speak(utterance)
        }
    }

    // MARK: - Seeking

    /// Segment index whose spoken range covers `fraction` of the whole text.
    func segmentIndex(atFraction fraction: Double) -> Int {
        guard !segmentStartOffsets.isEmpty else { return 0 }
        let target = Double(totalCharacterCount) * min(max(fraction, 0), 1)
        // Last segment starting at or before the target.
        let index = segmentStartOffsets.lastIndex { Double($0) <= target } ?? 0
        return index
    }

    /// Verse a scrub to `fraction` would land on, for live feedback while dragging.
    func verseId(atFraction fraction: Double) -> Int? {
        let index = segmentIndex(atFraction: fraction)
        guard segmentVerseIds.indices.contains(index) else { return nil }
        return segmentVerseIds[index]
    }

    /// Restart playback at the segment covering `fraction`.
    ///
    /// The synthesizer cannot resume mid-utterance, so this snaps to the start of
    /// the containing segment — in practice a verse — and always resumes speaking,
    /// even if playback was paused when the scrub began.
    func seek(toFraction fraction: Double) {
        guard playbackState != .idle else { return }
        seek(toSegment: segmentIndex(atFraction: fraction))
    }

    func seek(toSegment index: Int) {
        guard playbackState != .idle,
              queuedSegments.indices.contains(index),
              segmentStartOffsets.indices.contains(index) else { return }

        replaceSynthesizer()
        configureAudioSession()

        // The queue is rebuilt from `index`, so the completed count has to start
        // there too — it's the index the delegate resolves progress against.
        completedUtteranceCount = index
        spokenFraction = Double(segmentStartOffsets[index]) / Double(totalCharacterCount)
        currentVerseId = queuedSegments[index].verseId
        playbackState = .speaking

        enqueue(from: index)
        updateNowPlaying()
    }

    /// Jump to the start of the previous or next verse relative to the one playing.
    func skipVerse(by offset: Int) {
        guard playbackState != .idle,
              segmentVerseIds.indices.contains(completedUtteranceCount) else { return }
        let current = segmentVerseIds[completedUtteranceCount]

        if offset < 0 {
            // Restart the current verse unless already near its start, matching how
            // a track-back button behaves.
            let startOfCurrent = segmentVerseIds[..<completedUtteranceCount]
                .lastIndex { $0 != current }
                .map { $0 + 1 } ?? 0
            if completedUtteranceCount > startOfCurrent {
                seek(toSegment: startOfCurrent)
                return
            }
            let previousEnd = startOfCurrent - 1
            guard previousEnd >= 0 else { return seek(toSegment: 0) }
            let previous = segmentVerseIds[previousEnd]
            let startOfPrevious = segmentVerseIds[..<previousEnd]
                .lastIndex { $0 != previous }
                .map { $0 + 1 } ?? 0
            seek(toSegment: startOfPrevious)
        } else {
            guard let next = segmentVerseIds[completedUtteranceCount...]
                .firstIndex(where: { $0 != current }) else { return }
            seek(toSegment: next)
        }
    }

    /// Maps the user's reading rate onto AVSpeech's 0...1 scale. The mapping is
    /// approximate — the synthesizer's own curve isn't linear — but it keeps audio
    /// in step with the reading-time estimates derived from the same setting.
    private static func rate(forWordsPerMinute wpm: Double) -> Float {
        guard wpm > 0 else { return AVSpeechUtteranceDefaultSpeechRate }
        let scaled = AVSpeechUtteranceDefaultSpeechRate * Float(wpm / referenceWordsPerMinute)
        return min(max(scaled, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    func pause() {
        guard synthesizer.isSpeaking, !synthesizer.isPaused else { return }
        if synthesizer.pauseSpeaking(at: .word) {
            playbackState = .paused
            updateNowPlaying()
        }
    }

    func resume() {
        guard synthesizer.isPaused else { return }
        configureAudioSession()
        if synthesizer.continueSpeaking() {
            playbackState = .speaking
            updateNowPlaying()
        }
    }

    func stop() {
        guard playbackState != .idle || synthesizer.isSpeaking || synthesizer.isPaused else { return }
        replaceSynthesizer()
        reset()
    }

    private func replaceSynthesizer() {
        synthesizer.delegate = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
    }

    private func reset() {
        playbackState = .idle
        currentSpeechId = nil
        title = ""
        subtitle = nil
        currentVerseId = nil
        queuedSegments = []
        activeVoice = nil
        queuedUtteranceCount = 0
        completedUtteranceCount = 0
        segmentStartOffsets = []
        segmentVerseIds = []
        totalCharacterCount = 0
        activeWordsPerMinute = Self.referenceWordsPerMinute
        spokenFraction = 0
        stopObservingInterruptions()
        unregisterRemoteCommands()
        deactivateAudioSession()
    }

    // MARK: - Interruptions

    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
    }

    private func stopObservingInterruptions() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
    }

    /// A call or another app taking the session silences the synthesizer without
    /// telling the delegate. Reflect that in `playbackState`, or the transport
    /// keeps offering a pause button for audio that isn't playing.
    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            guard playbackState == .speaking else { return }
            synthesizer.pauseSpeaking(at: .immediate)
            playbackState = .paused
            updateNowPlaying()
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            guard options.contains(.shouldResume), playbackState == .paused else { return }
            resume()
        @unknown default:
            break
        }
    }

    // MARK: - Lock Screen & Remote Controls

    private static var handledRemoteCommands: [MPRemoteCommand] {
        let center = MPRemoteCommandCenter.shared()
        return [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.stopCommand]
    }

    private func registerRemoteCommands() {
        guard !hasRemoteCommands else { return }
        hasRemoteCommands = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.playbackState == .paused else { return .commandFailed }
            self.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.playbackState == .speaking else { return .commandFailed }
            self.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            switch self.playbackState {
            case .speaking: self.pause()
            case .paused: self.resume()
            case .idle: return .noSuchContent
            }
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            guard let self, self.playbackState != .idle else { return .commandFailed }
            self.stop()
            return .success
        }
        for command in Self.handledRemoteCommands {
            command.isEnabled = true
        }
    }

    private func unregisterRemoteCommands() {
        guard hasRemoteCommands else { return }
        hasRemoteCommands = false
        for command in Self.handledRemoteCommands {
            command.removeTarget(nil)
            command.isEnabled = false
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Only called on state transitions. Now Playing extrapolates elapsed time
    /// from `playbackRate`, so there's no need to push per-word updates.
    private func updateNowPlaying() {
        guard playbackState != .idle else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let duration = estimatedDuration
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: duration * spokenFraction,
            MPNowPlayingInfoPropertyPlaybackRate: playbackState == .speaking ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        if let subtitle, !subtitle.isEmpty {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[TextSpeechController] Audio session error: \(error.localizedDescription)")
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            print("[TextSpeechController] Audio session deactivation error: \(error.localizedDescription)")
        }
    }

    /// Split oversized segments into utterance-sized pieces on word boundaries,
    /// carrying each piece's verse tag so following along survives the split.
    private static func chunked(_ segments: [TextSpeechSegment], maxLength: Int = 900) -> [TextSpeechSegment] {
        var result: [TextSpeechSegment] = []

        for segment in segments {
            for line in segment.text.components(separatedBy: .newlines) {
                var current = ""
                for word in line.split(whereSeparator: { $0.isWhitespace }) {
                    let next = current.isEmpty ? String(word) : "\(current) \(word)"
                    if next.count > maxLength, !current.isEmpty {
                        result.append(TextSpeechSegment(text: current, verseId: segment.verseId))
                        current = String(word)
                    } else {
                        current = next
                    }
                }
                if !current.isEmpty {
                    result.append(TextSpeechSegment(text: current, verseId: segment.verseId))
                }
            }
        }

        return result
    }
}

extension TextSpeechController: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        // Utterances are spoken in queue order, so the completed count is also the
        // index of the one being spoken now.
        guard segmentStartOffsets.indices.contains(completedUtteranceCount) else { return }
        let spoken = segmentStartOffsets[completedUtteranceCount] + characterRange.location + characterRange.length
        spokenFraction = min(max(Double(spoken) / Double(totalCharacterCount), 0), 1)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard segmentVerseIds.indices.contains(completedUtteranceCount) else { return }
        let verseId = segmentVerseIds[completedUtteranceCount]
        // Chunked verses produce several utterances for one verse; only publish on
        // an actual change so followers don't re-scroll mid-verse.
        if verseId != currentVerseId {
            currentVerseId = verseId
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        completedUtteranceCount += 1
        if completedUtteranceCount >= queuedUtteranceCount {
            reset()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        reset()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        playbackState = .paused
        updateNowPlaying()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        playbackState = .speaking
        updateNowPlaying()
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isPlaying = false
            self?.stopTimer()
            self?.progress = 1.0
            self?.currentTime = self?.duration ?? 0
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.error = error
            self?.isPlaying = false
            self?.stopTimer()
        }
    }
}

// MARK: - Time Formatting

extension AudioPlayer {
    /// Format a time interval as mm:ss or h:mm:ss
    static func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite && time >= 0 else { return "0:00" }

        let hours = Int(time) / 3600
        let minutes = Int(time) / 60 % 60
        let seconds = Int(time) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
