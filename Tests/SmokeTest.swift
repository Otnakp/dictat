import Foundation
import Speech
import AVFoundation

// Usage: SmokeTest <audioFilePath>
// Feeds the audio file to SFSpeechRecognizer (it-IT, on-device if available)
// and prints the final transcript. This mirrors Dictate/SpeechTranscriber.swift
// logic so we can verify the Italian transcription pipeline end-to-end.

@inline(__always) private func log(_ s: String) {
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}

func main() -> Int32 {
    setvbuf(stdout, nil, _IONBF, 0)
    setvbuf(stderr, nil, _IONBF, 0)
    log("SMOKE_TEST_START")

    let args = CommandLine.arguments
    guard args.count >= 2 else {
        FileHandle.standardError.write("Usage: SmokeTest <audioFilePath>\n".data(using: .utf8)!)
        return 64
    }
    let url = URL(fileURLWithPath: args[1])
    guard FileManager.default.fileExists(atPath: url.path) else {
        FileHandle.standardError.write("File not found: \(url.path)\n".data(using: .utf8)!)
        return 66
    }
    log("Audio file: \(url.path)")

    // Recognizer availability does NOT require authorization.
    let locale = Locale(identifier: "it-IT")
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
        FileHandle.standardError.write("SFSpeechRecognizer unavailable for \(locale.identifier)\n".data(using: .utf8)!)
        return 78
    }
    log("Recognizer available for \(locale.identifier). supportsOnDeviceRecognition=\(recognizer.supportsOnDeviceRecognition)")

    let authSem = DispatchSemaphore(value: 0)
    var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    SFSpeechRecognizer.requestAuthorization { st in
        authStatus = st
        authSem.signal()
    }
    let waitRes = authSem.wait(timeout: .now() + 30)
    if case .timedOut = waitRes {
        log("Auth dialog not answered within 30s.")
    }
    log("Speech auth status: \(authStatus.rawValue) (0=notDetermined 1=denied 2=restricted 3=authorized)")
    guard authStatus == .authorized else {
        FileHandle.standardError.write("Speech recognition not authorized. Approve the system prompt and re-run.\n".data(using: .utf8)!)
        return 77
    }

    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = false
    if #available(macOS 13, *) { req.addsPunctuation = true }
    req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

    let file: AVAudioFile
    do {
        file = try AVAudioFile(forReading: url)
    } catch {
        FileHandle.standardError.write("Failed to open audio: \(error.localizedDescription)\n".data(using: .utf8)!)
        return 79
    }
    let format = file.processingFormat
    log("Audio format: \(format.sampleRate) Hz, \(format.channelCount) ch, \(file.length) frames")

    let doneSem = DispatchSemaphore(value: 0)
    var finalText = ""
    var gotFinal = false

    let task = recognizer.recognitionTask(with: req) { result, error in
        if let r = result {
            finalText = r.bestTranscription.formattedString
            log("progress: isFinal=\(r.isFinal) text=\"\(finalText)\"")
            if r.isFinal { gotFinal = true; doneSem.signal() }
        }
        if let e = error {
            FileHandle.standardError.write("Recognition error: \(e.localizedDescription)\n".data(using: .utf8)!)
            gotFinal = true
            doneSem.signal()
        }
    }

    let chunkFrames: AVAudioFrameCount = 8192
    while file.framePosition < file.length {
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
        do { try file.read(into: buf) } catch { break }
        req.append(buf)
        // Spin the run loop briefly while feeding so recognition callbacks can fire.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
    }
    req.endAudio()
    log("Finished feeding audio; waiting for final result (spinning run loop)…")

    // The recognition task delivers callbacks through the run loop, so we must
    // spin it rather than block on the semaphore.
    let deadline = Date(timeIntervalSinceNow: 90)
    while Date() < deadline && !gotFinal {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    task.cancel()
    if !gotFinal {
        FileHandle.standardError.write("Timed out waiting for final result.\n".data(using: .utf8)!)
    }
    log("FINAL_TRANSCRIPT_BEGIN")
    log(finalText)
    log("FINAL_TRANSCRIPT_END")
    return finalText.isEmpty ? 1 : 0
}

exit(main())

