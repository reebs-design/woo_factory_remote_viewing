import Foundation
import AVFoundation
import Capacitor
import Speech

@objc(SpeechRecognition)
public class SpeechRecognition: CAPPlugin {

    let defaultMatches = 5
    let messageMissingPermission = "Missing permission"
    let messageAccessDenied = "User denied access to speech recognition"
    let messageRestricted = "Speech recognition restricted on this device"
    let messageNotDetermined = "Speech recognition not determined on this device"
    let messageAccessDeniedMicrophone = "User denied access to microphone"
    let messageOngoing = "Ongoing speech recognition"
    let messageUnknown = "Unknown error occured"

    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var inputTapInstalled = false

    /// After `stop()` / `endAudio()`, iOS often delivers kAFAssistantErrorDomain/216 (cancelled).
    /// That must not surface as a fatal `speechError` to the WebView or listening dies after each restart.
    private func shouldReportSpeechErrorToWeb(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == "kAFAssistantErrorDomain" else { return true }
        // 216 = recognition cancelled; 203 = no speech / silence (benign for continuous dictation)
        let benignCodes: Set<Int> = [203, 216]
        return !benignCodes.contains(ns.code)
    }

    /// AVAudioEngine tap removal and engine lifecycle must run on the main thread.
    private func removeInputTapIfNeeded() {
        guard let engine = self.audioEngine, inputTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        inputTapInstalled = false
    }

    /// Fully tear down so the next `start()` gets a clean session (fixes “dead” second recognition).
    private func fullTeardownSpeechSession(notifyStopped: Bool) {
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if let engine = self.audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            removeInputTapIfNeeded()
        }
        audioEngine = nil
        speechRecognizer = nil

        if notifyStopped {
            self.notifyListeners("listeningState", data: ["status": "stopped"])
        }
    }

    @objc func available(_ call: CAPPluginCall) {
        guard let recognizer = SFSpeechRecognizer() else {
            call.resolve([
                "available": false
            ])
            return
        }
        call.resolve([
            "available": recognizer.isAvailable
        ])
    }

    @objc func start(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if let engine = self.audioEngine, engine.isRunning {
                call.reject(self.messageOngoing)
                return
            }
            // Stale engine (e.g. stopped after isFinal) must be cleared before a new session
            if self.audioEngine != nil || self.recognitionTask != nil {
                self.fullTeardownSpeechSession(notifyStopped: false)
            }

            let status: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
            if status != SFSpeechRecognizerAuthorizationStatus.authorized {
                call.reject(self.messageMissingPermission)
                return
            }

            AVAudioSession.sharedInstance().requestRecordPermission { (granted) in
                if !granted {
                    call.reject(self.messageAccessDeniedMicrophone)
                    return
                }

                DispatchQueue.main.async {
                    let language: String = call.getString("language") ?? "en-US"
                    let maxResults: Int = call.getInt("maxResults") ?? self.defaultMatches
                    let partialResults: Bool = call.getBool("partialResults") ?? false

                    if self.audioEngine != nil || self.recognitionTask != nil {
                        self.fullTeardownSpeechSession(notifyStopped: false)
                    }

                    self.audioEngine = AVAudioEngine()
                    self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: language))

                    let audioSession: AVAudioSession = AVAudioSession.sharedInstance()
                    do {
                        try audioSession.setCategory(AVAudioSession.Category.playAndRecord, options: AVAudioSession.CategoryOptions.defaultToSpeaker)
                        try audioSession.setMode(AVAudioSession.Mode.default)
                        do {
                            try audioSession.setActive(true, options: AVAudioSession.SetActiveOptions.notifyOthersOnDeactivation)
                        } catch {
                            call.reject("Microphone is already in use by another application.")
                            self.fullTeardownSpeechSession(notifyStopped: false)
                            return
                        }
                    } catch {

                    }

                    self.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
                    self.recognitionRequest?.shouldReportPartialResults = partialResults

                    guard let audioEngine = self.audioEngine else {
                        call.reject(self.messageUnknown)
                        return
                    }
                    let inputNode: AVAudioInputNode = audioEngine.inputNode
                    let format: AVAudioFormat = inputNode.outputFormat(forBus: 0)

                    self.recognitionTask = self.speechRecognizer?.recognitionTask(with: self.recognitionRequest!, resultHandler: { (result, error) in
                        if let error = error {
                            DispatchQueue.main.async {
                                self.fullTeardownSpeechSession(notifyStopped: true)
                                // start() already resolved when partialResults is true — rejecting again breaks the bridge
                                if partialResults {
                                    if self.shouldReportSpeechErrorToWeb(error) {
                                        self.notifyListeners("speechError", data: ["message": error.localizedDescription])
                                    }
                                } else {
                                    call.reject(error.localizedDescription)
                                }
                            }
                            return
                        }

                        guard let result = result else { return }

                        let resultArray: NSMutableArray = NSMutableArray()
                        var counter: Int = 0

                        for transcription: SFTranscription in result.transcriptions {
                            if maxResults > 0 && counter < maxResults {
                                resultArray.add(transcription.formattedString)
                            }
                            counter += 1
                        }

                        if partialResults {
                            self.notifyListeners("partialResults", data: ["matches": resultArray])
                        } else {
                            call.resolve([
                                "matches": resultArray
                            ])
                        }

                        if result.isFinal {
                            DispatchQueue.main.async {
                                self.fullTeardownSpeechSession(notifyStopped: true)
                            }
                        }
                    })

                    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { (buffer: AVAudioPCMBuffer, _: AVAudioTime) in
                        self.recognitionRequest?.append(buffer)
                    }
                    self.inputTapInstalled = true

                    audioEngine.prepare()
                    do {
                        try audioEngine.start()
                        self.notifyListeners("listeningState", data: ["status": "started"])
                        if partialResults {
                            call.resolve()
                        }
                    } catch {
                        self.fullTeardownSpeechSession(notifyStopped: false)
                        call.reject(self.messageUnknown)
                    }
                }
            }
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.fullTeardownSpeechSession(notifyStopped: true)
            call.resolve()
        }
    }

    @objc func isListening(_ call: CAPPluginCall) {
        let isListening = self.audioEngine?.isRunning ?? false
        call.resolve([
            "listening": isListening
        ])
    }

    @objc func getSupportedLanguages(_ call: CAPPluginCall) {
        let supportedLanguages: Set<Locale>! = SFSpeechRecognizer.supportedLocales() as Set<Locale>
        let languagesArr: NSMutableArray = NSMutableArray()

        for lang: Locale in supportedLanguages {
            languagesArr.add(lang.identifier)
        }

        call.resolve([
            "languages": languagesArr
        ])
    }

    @objc override public func checkPermissions(_ call: CAPPluginCall) {
        let status: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
        let permission: String
        switch status {
        case .authorized:
            permission = "granted"
        case .denied, .restricted:
            permission = "denied"
        case .notDetermined:
            permission = "prompt"
        @unknown default:
            permission = "prompt"
        }
        call.resolve(["speechRecognition": permission])
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) {
        SFSpeechRecognizer.requestAuthorization { (status: SFSpeechRecognizerAuthorizationStatus) in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    AVAudioSession.sharedInstance().requestRecordPermission { (granted: Bool) in
                        if granted {
                            call.resolve(["speechRecognition": "granted"])
                        } else {
                            call.resolve(["speechRecognition": "denied"])
                        }
                    }
                    break
                case .denied, .restricted, .notDetermined:
                    self.checkPermissions(call)
                    break
                @unknown default:
                    self.checkPermissions(call)
                }
            }
        }
    }
}
