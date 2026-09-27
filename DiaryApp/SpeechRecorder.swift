import AVFoundation
import Combine
import Speech

@MainActor
final class SpeechRecorder: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var isStarting = false
    @Published var isFinalizing = false
    @Published var errorMessage: String?
    @Published private(set) var finalRecognitionErrorMessage: String?
    @Published private(set) var recordingStartedAt: Date?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var audioRequestBox: AudioRecognitionRequestBox?
    private var segmentTimer: Timer?
    private var retryWorkItem: DispatchWorkItem?
    private var retryDelay: TimeInterval = 1
    private var segmentID = 0
    private var completedTranscript = ""
    private var segmentTranscript = ""
    private var completedAudioBufferCount = 0
    private var completedAudibleSignal = false
    private var startupAttempt = 0

    var audioBufferCount: Int {
        completedAudioBufferCount + (audioRequestBox?.appendedBufferCount ?? 0)
    }

    var hasDetectedAudibleSignal: Bool {
        completedAudibleSignal || (audioRequestBox?.hasDetectedAudibleSignal ?? false)
    }

    private let recognitionSegmentDuration: TimeInterval = 45

    func start() {
        guard !isRecording, !isStarting, !isFinalizing else { return }
        startupAttempt += 1
        let currentStartupAttempt = startupAttempt
        errorMessage = nil
        finalRecognitionErrorMessage = nil
        transcript = ""
        completedTranscript = ""
        segmentTranscript = ""
        completedAudioBufferCount = 0
        completedAudibleSignal = false
        audioRequestBox = nil
        retryDelay = 1
        retryWorkItem?.cancel()
        retryWorkItem = nil
        recordingStartedAt = nil
        isStarting = true
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.startupAttempt == currentStartupAttempt else { return }
                guard status == .authorized else {
                    self.isStarting = false
                    self.errorMessage = "请在系统设置中允许语音识别。"
                    return
                }
                requestMicrophonePermission { granted in
                    DispatchQueue.main.async {
                        guard self.startupAttempt == currentStartupAttempt else { return }
                        guard granted else {
                            self.isStarting = false
                            self.errorMessage = "请在系统设置中允许麦克风访问。"
                            return
                        }
                        self.beginRecognition()
                    }
                }
            }
        }
    }

    private func beginRecognition() {
        guard let recognizer, recognizer.isAvailable else {
            isStarting = false
            errorMessage = "系统语音识别当前不可用。请检查网络和“设置 > 隐私与安全性 > 语音识别”权限后重试。"
            return
        }
        do {
#if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            // Xcode's device screen and connected accessories may change the
            // recording route. Prefer the phone's own microphone whenever it
            // is available so tethered debugging does not capture silence.
            if let builtInMicrophone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtInMicrophone)
            }
#endif
            let input = audioEngine.inputNode
            // Follow the current hardware input format. Some microphones and
            // Bluetooth routes do not use the engine's default output rate.
            let format = input.inputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                throw SpeechRecorderError.noMicrophoneInput
            }
            let requestBox = AudioRecognitionRequestBox()
            audioRequestBox = requestBox
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                requestBox.append(buffer)
            }
            let initialRequest = makeRecognitionRequest()
            request = initialRequest
            requestBox.replace(with: initialRequest)
            audioEngine.prepare()
            try audioEngine.start()
            recordingStartedAt = Date()
            isRecording = true
            isStarting = false
            startRecognitionTask(using: recognizer, requestBox: requestBox, request: initialRequest)
        } catch {
            isStarting = false
            errorMessage = "无法开始录音：\(error.localizedDescription)"
            tearDownAudioCapture(cancelRecognition: true)
        }
    }

    private func tearDownAudioCapture(cancelRecognition: Bool) {
        completedAudioBufferCount = audioBufferCount
        completedAudibleSignal = hasDetectedAudibleSignal
        segmentID += 1
        segmentTimer?.invalidate()
        segmentTimer = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil
        audioRequestBox?.replace(with: nil)
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        if cancelRecognition { task?.cancel() }
        request = nil
        task = nil
        audioRequestBox = nil
        isRecording = false
        isStarting = false
        isFinalizing = false
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }

    private func startRecognitionSegment(using recognizer: SFSpeechRecognizer, requestBox: AudioRecognitionRequestBox) {
        let request = makeRecognitionRequest()
        self.request = request
        requestBox.replace(with: request)
        startRecognitionTask(using: recognizer, requestBox: requestBox, request: request)
    }

    private func makeRecognitionRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        return request
    }

    private func startRecognitionTask(
        using recognizer: SFSpeechRecognizer,
        requestBox: AudioRecognitionRequestBox,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        segmentID += 1
        let currentSegmentID = segmentID
        segmentTranscript = ""
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.segmentID == currentSegmentID else { return }
                if let result {
                    self.segmentTranscript = result.bestTranscription.formattedString
                    self.updateTranscript()
                    self.retryDelay = 1
                    if self.errorMessage?.hasPrefix("语音转写暂时中断") == true {
                        self.errorMessage = nil
                    }
                }
                if result?.isFinal == true || error != nil {
                    self.segmentTimer?.invalidate()
                    self.segmentTimer = nil
                    if self.isRecording {
                        if let error, Self.isRecognizerInitializationFailure(error) {
                            let message = Self.userFacingMessage(for: error)
                            self.errorMessage = message
                            self.finalRecognitionErrorMessage = message
                            self.tearDownAudioCapture(cancelRecognition: true)
                            return
                        }
                        self.continueRecordingAfterRecognitionEnds(using: recognizer, error: error)
                    } else {
                        if self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let error {
                            self.finalRecognitionErrorMessage = Self.userFacingMessage(for: error)
                        }
                        self.isStarting = false
                        self.isFinalizing = false
                        self.request = nil
                        self.task = nil
#if os(iOS)
                        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
                    }
                }
            }
        }
        segmentTimer?.invalidate()
        segmentTimer = Timer.scheduledTimer(withTimeInterval: recognitionSegmentDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.rotateRecognitionSegment() }
        }
    }

    private func continueRecordingAfterRecognitionEnds(using recognizer: SFSpeechRecognizer, error: Error?) {
        guard isRecording, let requestBox = audioRequestBox else { return }
        completedTranscript = transcript
        segmentTranscript = ""
        requestBox.replace(with: nil)
        request = nil
        task = nil
        segmentID += 1
        if let error {
            errorMessage = "语音转写暂时中断，录音仍在继续并会自动重试：\(error.localizedDescription)"
        }
        scheduleRecognitionRetry(using: recognizer, requestBox: requestBox)
    }

    private func scheduleRecognitionRetry(using recognizer: SFSpeechRecognizer, requestBox: AudioRecognitionRequestBox) {
        guard isRecording, audioRequestBox === requestBox else { return }
        retryWorkItem?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 8)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording, self.audioRequestBox === requestBox else { return }
            self.retryWorkItem = nil
            guard recognizer.isAvailable else {
                self.errorMessage = "语音转写暂时中断，录音仍在继续并会自动重试。"
                self.scheduleRecognitionRetry(using: recognizer, requestBox: requestBox)
                return
            }
            self.startRecognitionSegment(using: recognizer, requestBox: requestBox)
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func rotateRecognitionSegment() {
        guard isRecording, let recognizer, let audioRequestBox, let oldRequest = request, let oldTask = task else { return }
        completedTranscript = transcript
        segmentTranscript = ""
        startRecognitionSegment(using: recognizer, requestBox: audioRequestBox)
        oldRequest.endAudio()
        oldTask.finish()
    }

    private func updateTranscript() {
        transcript = [completedTranscript, segmentTranscript]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func userFacingMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "kLSRErrorDomain" {
            switch nsError.code {
            case 300:
#if os(iOS) && targetEnvironment(simulator)
                return "iOS 模拟器的系统语音识别无法初始化。请在真实 iPhone 上测试语音输入。"
#else
                return "系统语音识别无法初始化。请检查系统听写和语音识别权限后重试。"
#endif
            case 201:
                return "iPhone 系统听写未开启。请到“设置 > 通用 > 键盘”打开“启用听写”，并在“设置 > 隐私与安全性 > 语音识别”允许留白日记。"
            case 102:
                return "iPhone 的中文语音识别资源尚未准备好。请连接网络，稍后再试。"
            default:
                break
            }
        }
        if nsError.domain == "kAFAssistantErrorDomain", [1101, 1107].contains(nsError.code) {
            return "iPhone 系统语音识别连接中断。请检查网络和系统听写设置后重试。"
        }
        return "iPhone 系统语音识别失败：\(error.localizedDescription)"
    }

    private static func diagnosticDescription(for error: Error) -> String {
        var currentError: NSError? = error as NSError
        var details: [String] = []
        var visited = Set<String>()

        while let nsError = currentError {
            let identity = "\(nsError.domain):\(nsError.code):\(nsError.localizedDescription)"
            guard visited.insert(identity).inserted else { break }
            details.append("\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)")
            currentError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }

        return details.joined(separator: "\n")
    }

    private static func isRecognizerInitializationFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "kLSRErrorDomain" && nsError.code == 300
    }

    func stop() {
        guard isRecording else {
            isStarting = false
            return
        }
        if audioEngine.isRunning { audioEngine.stop() }
        retryWorkItem?.cancel()
        retryWorkItem = nil
        segmentTimer?.invalidate()
        segmentTimer = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioRequestBox?.replace(with: nil)
        request?.endAudio()
        isRecording = false
        if task != nil {
            isFinalizing = true
            task?.finish()
        } else {
            isFinalizing = false
            request = nil
#if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
        }
    }

    func cancel() {
        startupAttempt += 1
        tearDownAudioCapture(cancelRecognition: true)
        transcript = ""
        completedTranscript = ""
        segmentTranscript = ""
        completedAudioBufferCount = 0
        completedAudibleSignal = false
        recordingStartedAt = nil
        errorMessage = nil
        finalRecognitionErrorMessage = nil
    }
}

private enum SpeechRecorderError: LocalizedError {
    case noMicrophoneInput

    var errorDescription: String? {
        switch self {
        case .noMicrophoneInput:
            return "没有检测到可用的麦克风输入。请检查手机麦克风权限或断开耳机后重试。"
        }
    }
}

private final class AudioRecognitionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private var bufferCount = 0
    private var detectedAudibleSignal = false

    var appendedBufferCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bufferCount
    }

    var hasDetectedAudibleSignal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return detectedAudibleSignal
    }

    func replace(with request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        currentRequest = request
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        bufferCount += 1
        if !detectedAudibleSignal, let channels = buffer.floatChannelData {
            let samples = channels[0]
            let count = Int(buffer.frameLength)
            var index = 0
            while index < count {
                if abs(samples[index]) > 0.003 {
                    detectedAudibleSignal = true
                    break
                }
                index += 16
            }
        }
        let request = currentRequest
        lock.unlock()
        request?.append(buffer)
    }
}

private func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
    #if os(macOS)
    AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    #else
    AVAudioApplication.requestRecordPermission(completionHandler: completion)
    #endif
}
