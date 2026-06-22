import SwiftUI
import AppKit
import Combine
import AVFoundation
import Speech
import CoreGraphics
import QuartzCore
import Carbon.HIToolbox
import IOKit.hid
import Sparkle

// MARK: - App shell
// MenuBarExtra (SwiftUI) non renderizzava l'icona in modo affidabile (sparisce su
// menu bar affollata / col notch). Usiamo NSStatusItem imperativo + una finestra
// normale all'avvio, così l'app è SEMPRE visibile.

@main
struct DictatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Solo menu bar (come AeroSpace): nessuna finestra, nessuna Dock icon.
    // Tutta la UI vive nel popover dell'NSStatusItem.
    var body: some Scene { Settings { EmptyView() } }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coord = Coordinator()
    private var statusBar: StatusBarController?
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory) // niente Dock, niente finestra
        statusBar = StatusBarController(coord: coord)
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let coord: Coordinator
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()
    // Sparkle: avvia il check automatico degli aggiornamenti (config in Info.plist).
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var recorderWindow: NSWindow?
    private var recorderMonitor: Any?
    private var recorderMouseMonitor: Any?

    init(coord: Coordinator) {
        self.coord = coord
        super.init()
        statusItem.isVisible = true
        if let b = statusItem.button {
            setSymbol(coord.state.status.symbol, on: b)
            b.target = self
            b.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 480)
        popover.contentViewController = NSHostingController(
            rootView: MenuView(coord: coord, state: coord.state, perm: coord.perm,
                               onCheckUpdates: { [weak self] in self?.updater.checkForUpdates(nil) },
                               onRecordKey: { [weak self] in self?.recordKey() }))

        // Il glifo dell'icona segue lo stato (idle/recording/transcribing/error).
        coord.state.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                guard let self, let b = self.statusItem.button else { return }
                self.setSymbol(s.symbol, on: b)
            }
            .store(in: &bag)
    }

    private func setSymbol(_ name: String, on button: NSStatusBarButton) {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Dictat")
        img?.isTemplate = true
        button.image = img
    }

    @objc private func togglePopover() {
        guard let b = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        }
    }

    // Apre una finestrella che cattura il prossimo tasto/modificatore e lo salva come binding.
    func recordKey() {
        guard recorderWindow == nil else { return }
        popover.performClose(nil)
        let vc = NSHostingController(rootView: KeyRecorderView())
        let w = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        w.title = L("Registra trigger", "Record trigger")
        w.contentViewController = vc
        w.setContentSize(vc.view.fittingSize)   // si adatta al testo
        w.center(); w.level = .floating; w.isReleasedWhenClosed = false
        recorderWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)

        recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown]) { [weak self] ev in
            guard let self else { return ev }
            if ev.type == .keyDown && ev.keyCode == 53 { self.finishRecording(nil); return nil } // Esc
            if let b = keyBinding(from: ev) { self.finishRecording(b); return nil }
            return ev
        }
        // I pulsanti del mouse vanno alla finestra sotto il cursore: serve un monitor
        // globale per catturarli ovunque (per il mouse non richiede permessi speciali).
        recorderMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown]) { [weak self] ev in
            if let b = keyBinding(from: ev) { self?.finishRecording(b) }
        }
    }

    private func finishRecording(_ binding: KeyBinding?) {
        if let m = recorderMonitor { NSEvent.removeMonitor(m); recorderMonitor = nil }
        if let m = recorderMouseMonitor { NSEvent.removeMonitor(m); recorderMouseMonitor = nil }
        if let binding { coord.state.addBinding(binding) }
        recorderWindow?.close(); recorderWindow = nil
    }
}

// MARK: - State

/// Stringa localizzata in base alla lingua scelta (legge dai defaults → vale ovunque,
/// anche fuori dalle View). Default inglese.
func L(_ it: String, _ en: String) -> String {
    (UserDefaults.standard.string(forKey: "language") ?? "en-US").hasPrefix("it") ? it : en
}

enum Status: Equatable {
    case idle, recording, transcribing, error(String)
    var symbol: String {
        switch self {
        case .idle:         return "mic"
        case .recording:    return "mic.fill"
        case .transcribing: return "waveform"
        case .error:        return "exclamationmark.triangle.fill"
        }
    }
    var label: String {
        switch self {
        case .idle:            return L("Inattivo", "Idle")
        case .recording:       return L("Registrazione…", "Recording…")
        case .transcribing:    return L("Trascrizione…", "Transcribing…")
        case .error(let m):    return L("Errore: \(m)", "Error: \(m)")
        }
    }
}

/// Trigger push-to-talk configurabile: modificatore, tasto normale o pulsante del mouse.
struct KeyBinding: Codable, Equatable, Identifiable {
    var id = UUID()
    var keyCode: Int            // keycode tastiera, oppure numero pulsante mouse se isMouse
    var isModifier: Bool
    var isMouse: Bool = false
    var modifierFlags: UInt64   // CGEventFlags raw: per i modificatori è il flag del tasto stesso;
                                // per i tasti normali sono i modificatori richiesti (es. ⌃).
    var label: String

    static let rightOption = KeyBinding(keyCode: 61, isModifier: true,
        modifierFlags: CGEventFlags.maskAlternate.rawValue, label: "Right Option ⌥")
}

/// keycode → flag modificatore (nil = tasto normale).
func modifierFlag(forKeyCode kc: Int) -> CGEventFlags? {
    switch kc {
    case 54, 55: return .maskCommand
    case 56, 60: return .maskShift
    case 58, 61: return .maskAlternate
    case 59, 62: return .maskControl
    case 63:     return .maskSecondaryFn
    default:     return nil
    }
}

func keyName(keyCode kc: Int, isModifier: Bool) -> String {
    if isModifier {
        switch kc {
        case 55: return "Left Command ⌘";  case 54: return "Right Command ⌘"
        case 56: return "Left Shift ⇧";     case 60: return "Right Shift ⇧"
        case 58: return "Left Option ⌥";    case 61: return "Right Option ⌥"
        case 59: return "Left Control ⌃";   case 62: return "Right Control ⌃"
        case 63: return "Fn / Globe"
        default: return "Modifier \(kc)"
        }
    }
    let names: [Int: String] = [
        49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 51: "Delete",
        122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",
        101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",
        106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"
    ]
    return names[kc] ?? "Key \(kc)"
}

private enum K {
    static let enabled = "enabled", lang = "language"
    static let onDevice = "onDeviceOnly", punct = "autoPunctuation"
    static let bindings = "keyBindings"
}

final class AppState: ObservableObject {
    private let d = UserDefaults.standard
    @Published var status: Status = .idle
    @Published var isRecording = false
    @Published var lastTranscript = ""
    static let maxBindings = 5
    @Published var enabled: Bool         { didSet { d.set(enabled, forKey: K.enabled) } }
    @Published var bindings: [KeyBinding] { didSet { if let v = try? JSONEncoder().encode(bindings) { d.set(v, forKey: K.bindings) } } }
    @Published var language: String      { didSet { d.set(language, forKey: K.lang) } }
    @Published var onDeviceOnly: Bool    { didSet { d.set(onDeviceOnly, forKey: K.onDevice) } }
    @Published var autoPunctuation: Bool { didSet { d.set(autoPunctuation, forKey: K.punct) } }

    init() {
        enabled = d.object(forKey: K.enabled) as? Bool ?? true
        if let v = d.data(forKey: K.bindings), let b = try? JSONDecoder().decode([KeyBinding].self, from: v), !b.isEmpty {
            bindings = b
        } else { bindings = [.rightOption] }
        language = d.string(forKey: K.lang) ?? "en-US"
        onDeviceOnly = d.object(forKey: K.onDevice) as? Bool ?? true
        autoPunctuation = d.object(forKey: K.punct) as? Bool ?? true
    }

    func addBinding(_ b: KeyBinding) {
        guard bindings.count < Self.maxBindings else { return }
        bindings.append(b)
    }
    func removeBinding(_ b: KeyBinding) {
        guard bindings.count > 1 else { return }   // almeno un trigger
        bindings.removeAll { $0.id == b.id }
    }
}

// MARK: - Permissions

final class PermissionsManager: ObservableObject {
    @Published var mic = false
    @Published var speech = false
    @Published var accessibility = false
    @Published var inputMonitoring = false

    func refresh() {
        mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speech = SFSpeechRecognizer.authorizationStatus() == .authorized
        accessibility = AXIsProcessTrusted()
        // Un event tap che ascolta la tastiera globalmente richiede Input Monitoring,
        // altrimenti riceve i tasti solo quando l'app è in primo piano.
        inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    func requestInputMonitoring() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) // prompt di sistema
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() }
        } else {
            Task { @MainActor in PermisoAssistant.shared.present(panel: .inputMonitoring) }
        }
    }

    func requestMic() {
        NSApp.activate(ignoringOtherApps: true)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refresh() } }
        } else { open("Privacy_Microphone") }
    }
    func requestSpeech() {
        NSApp.activate(ignoringOtherApps: true)
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async { self.refresh() } }
        } else { open("Privacy_SpeechRecognition") }
    }
    func requestAccessibility() {
        // Permiso: apre Impostazioni e ci fa fluttuare sopra il pannello guida con
        // la riga trascinabile (icona Dictat → lista Accessibilità).
        Task { @MainActor in PermisoAssistant.shared.present(panel: .accessibility) }
    }
    // macOS 13+ deep-link scheme.
    private func open(_ pane: String) {
        let s = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)"
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
}

// MARK: - Hotkey (global CGEvent tap, push-to-talk via flagsChanged)

private func hotkeyCallback(proxy: CGEventTapProxy, type: CGEventType,
                            event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon = refcon {
        let consumed = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
        if consumed { return nil } // tasto normale usato come hotkey: non farlo digitare
    }
    return Unmanaged.passUnretained(event)
}

final class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var bindingsProvider: (() -> [KeyBinding])?
    var enabledProvider: (() -> Bool)?

    private var tap: CFMachPort?
    private var src: CFRunLoopSource?
    private var downSet = Set<Int>()   // trigger attualmente premuti (per signature)
    private var anyDown = false
    var isRunning: Bool { tap != nil }

    /// Richiede Input Monitoring; ritorna nil finché non concesso.
    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask((1 << CGEventType.flagsChanged.rawValue)
                             | (1 << CGEventType.keyDown.rawValue)
                             | (1 << CGEventType.keyUp.rawValue)
                             | (1 << CGEventType.otherMouseDown.rawValue)
                             | (1 << CGEventType.otherMouseUp.rawValue))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: hotkeyCallback, userInfo: refcon) else { return }
        tap = t
        src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    func stop() {
        if let src { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        src = nil; tap = nil; downSet.removeAll(); anyDown = false
    }

    /// Ricrea il tap: serve dopo che Input Monitoring viene concesso, così il tap
    /// (ri)acquisisce gli eventi globali invece di vederli solo con app in focus.
    func restart() { stop(); start() }

    private let modMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    private func signature(_ b: KeyBinding) -> Int {
        if b.isMouse { return 100_000 + b.keyCode }
        if b.isModifier { return 200_000 + Int(truncatingIfNeeded: b.modifierFlags) &+ b.keyCode } // distingue L/R
        return b.keyCode
    }

    /// Ritorna true se l'evento va consumato (tasto normale o pulsante mouse usato come trigger).
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return false
        }
        let kc = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let flags = event.flags
        var consume = false

        if enabledProvider?() ?? true {
            for b in (bindingsProvider?() ?? [.rightOption]) {
                let sig = signature(b)
                if b.isMouse {
                    guard (type == .otherMouseDown || type == .otherMouseUp), button == b.keyCode else { continue }
                    if type == .otherMouseDown { downSet.insert(sig) } else { downSet.remove(sig) }
                    consume = true
                } else if b.isModifier {
                    guard type == .flagsChanged else { continue }
                    let flag = CGEventFlags(rawValue: b.modifierFlags)
                    guard flag.contains(.maskSecondaryFn) || kc == b.keyCode else { continue }
                    if flags.contains(flag) { downSet.insert(sig) } else { downSet.remove(sig) }
                    // i modificatori non si consumano
                } else {
                    guard (type == .keyDown || type == .keyUp), kc == b.keyCode else { continue }
                    let need = CGEventFlags(rawValue: b.modifierFlags).intersection(modMask)
                    if type == .keyDown, flags.intersection(modMask).isSuperset(of: need) {
                        downSet.insert(sig)
                    } else if type == .keyUp {
                        downSet.remove(sig)
                    }
                    consume = true
                }
            }
        } else {
            downSet.removeAll()
        }

        let now = !downSet.isEmpty
        if now != anyDown { anyDown = now; now ? onPress?() : onRelease?() }
        return consume
    }
}

// MARK: - Speech

final class SpeechTranscriber {
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var req: SFSpeechAudioBufferRecognitionRequest?
    private let lock = NSLock()
    private var best = ""
    private var done = false
    private let onDeviceOnly: Bool
    private let punct: Bool

    init(locale: Locale, onDeviceOnly: Bool, punct: Bool) {
        recognizer = SFSpeechRecognizer(locale: locale)
        self.onDeviceOnly = onDeviceOnly
        self.punct = punct
    }

    func start() throws {
        guard let r = recognizer, r.isAvailable else {
            throw err(L("Riconoscimento non disponibile per questa lingua", "Recognition unavailable for this language"))
        }
        let q = SFSpeechAudioBufferRecognitionRequest()
        q.shouldReportPartialResults = true
        if #available(macOS 13, *) { q.addsPunctuation = punct }
        if onDeviceOnly {
            guard r.supportsOnDeviceRecognition else {
                throw err(L("On-device non disponibile. Disattiva \"Solo on-device\".", "On-device unavailable. Turn off \"On-device only\"."))
            }
            q.requiresOnDeviceRecognition = true
        } else {
            q.requiresOnDeviceRecognition = r.supportsOnDeviceRecognition
        }
        req = q
        task = r.recognitionTask(with: q) { [weak self] res, e in
            guard let self else { return }
            if let res = res {
                self.lock.lock(); self.best = res.bestTranscription.formattedString; self.lock.unlock()
                if res.isFinal { DispatchQueue.main.async { self.complete() } }
            }
            if let e = e {
                DispatchQueue.main.async {
                    self.lock.lock(); let empty = self.best.isEmpty; self.lock.unlock()
                    empty ? self.fail(e.localizedDescription) : self.complete()
                }
            }
        }
    }

    func append(_ b: AVAudioPCMBuffer) { req?.append(b) }

    func stopAndFinalize() {
        req?.endAudio()
        // Fallback: se il riconoscitore non emette mai isFinal, chiudiamo dopo 2s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.complete() }
    }

    func cancel() { done = true; task?.cancel(); task = nil; req = nil }

    // complete()/fail() girano sempre su main → done fa da guardia, niente race.
    private func complete() {
        guard !done else { return }
        done = true
        task?.finish(); task = nil; req = nil
        lock.lock(); let text = best; lock.unlock()
        onFinal?(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private func fail(_ m: String) {
        guard !done else { return }
        done = true; task?.cancel(); task = nil; req = nil
        onError?(m)
    }
    private func err(_ m: String) -> NSError { NSError(domain: "Dictat", code: 1,
        userInfo: [NSLocalizedDescriptionKey: m]) }
}

// MARK: - Paste

final class PasteManager {
    func copy(_ t: String) {
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString(t, forType: .string)
    }
    func paste(_ t: String) {
        copy(t)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { self.cmdV() }
    }
    private func cmdV() {
        let s = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: s, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: s, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }
}

// MARK: - Coordinator

final class Coordinator: ObservableObject {
    let state = AppState()
    let perm = PermissionsManager()
    private let engine = AVAudioEngine()
    private let paster = PasteManager()
    private let hotkeys = HotkeyManager()
    private var transcriber: SpeechTranscriber?
    private var recording = false
    private var timer: Timer?
    private var lastInputMonitoring = false
    // Gesture: hold = push-to-talk; doppio click = hands-free (start), altro doppio click = stop.
    // Entrambe sempre attive, senza setting di modalità.
    private let holdThreshold: TimeInterval = 0.3   // oltre = hold; sotto = tap
    private let doubleWindow: TimeInterval = 0.4
    private var pressDown: Date?
    private var pendingTapAt: Date?
    private var handsFree = false
    private var ignoreRelease = false
    private var loneTap: DispatchWorkItem?

    init() {
        hotkeys.onPress = { [weak self] in self?.handlePress() }
        hotkeys.onRelease = { [weak self] in self?.handleRelease() }
        hotkeys.bindingsProvider = { [weak self] in self?.state.bindings ?? [.rightOption] }
        hotkeys.enabledProvider = { [weak self] in self?.state.enabled ?? false }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func handlePress() {
        let now = Date()
        // Secondo click di un doppio click?
        if let tap = pendingTapAt, now.timeIntervalSince(tap) < doubleWindow {
            pendingTapAt = nil
            loneTap?.cancel(); loneTap = nil
            ignoreRelease = true
            if handsFree { handsFree = false; stopRecording() }  // doppio click → stop
            else { handsFree = true }                            // doppio click → latch hands-free
            return
        }
        pressDown = now
        if !recording { startRecording() }   // l'audio parte subito (anche per il doppio click)
    }

    private func handleRelease() {
        if ignoreRelease { ignoreRelease = false; return }
        guard let pd = pressDown else { return }
        let held = Date().timeIntervalSince(pd)
        pressDown = nil
        if !handsFree && held >= holdThreshold {
            stopRecording()                   // è stato un hold (push-to-talk)
            return
        }
        // Tap rapido: può essere il 1° click di un doppio click → attendi la finestra.
        pendingTapAt = Date()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingTapAt = nil
            if !self.handsFree { self.stopRecording() }  // tap isolato → ferma (probabilmente vuoto)
        }
        loneTap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleWindow, execute: work)
    }

    private func tick() {
        perm.refresh()
        // Quando Input Monitoring passa a concesso, ricrea il tap così acquisisce
        // gli eventi globali (prima li vedeva solo con app in focus).
        if perm.inputMonitoring != lastInputMonitoring {
            lastInputMonitoring = perm.inputMonitoring
            if perm.inputMonitoring { hotkeys.restart() }
        }
        // Il tap richiede Input Monitoring per i tasti globali; Accessibilità serve per incollare.
        let canListen = perm.inputMonitoring || perm.accessibility
        if canListen && !hotkeys.isRunning { hotkeys.start() }
    }

    func startRecording() {
        guard state.enabled, !recording else { return }
        perm.refresh()
        guard perm.mic else { state.status = .error(L("Microfono non autorizzato", "Microphone not authorized")); perm.requestMic(); return }
        guard perm.speech else { state.status = .error(L("Speech non autorizzato", "Speech not authorized")); perm.requestSpeech(); return }

        let t = SpeechTranscriber(locale: Locale(identifier: state.language),
                                  onDeviceOnly: state.onDeviceOnly, punct: state.autoPunctuation)
        t.onFinal = { [weak self] text in self?.finish(text) }
        t.onError = { [weak self] msg in
            DispatchQueue.main.async { self?.state.status = .error(msg); self?.teardownEngine() }
        }
        do {
            try t.start()
            let input = engine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in t.append(buf) }
            engine.prepare()
            try engine.start()
            transcriber = t
            recording = true; state.isRecording = true; state.status = .recording
            NSSound(named: "Tink")?.play()
        } catch {
            t.cancel(); teardownEngine()
            state.status = .error(error.localizedDescription)
        }
    }

    func stopRecording() {
        guard recording else { return }
        recording = false; state.isRecording = false; state.status = .transcribing
        teardownEngine()
        transcriber?.stopAndFinalize()
        NSSound(named: "Pop")?.play()
    }

    private func teardownEngine() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    private func finish(_ text: String) {
        DispatchQueue.main.async {
            self.transcriber = nil
            self.state.status = .idle
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            self.state.lastTranscript = clean
            if self.perm.accessibility { self.paster.paste(clean) }
            else { self.paster.copy(clean); self.state.status = .error(L("Abilita Accessibilità per incollare", "Enable Accessibility to paste")) }
        }
    }

    func pasteLast() {
        guard !state.lastTranscript.isEmpty else { return }
        if perm.accessibility { paster.paste(state.lastTranscript) }
        else { paster.copy(state.lastTranscript); perm.requestAccessibility() }
    }
}

// MARK: - Menu UI

struct MenuView: View {
    @ObservedObject var coord: Coordinator
    @ObservedObject var state: AppState
    @ObservedObject var perm: PermissionsManager
    var onCheckUpdates: () -> Void = {}
    var onRecordKey: () -> Void = {}

    private func t(_ it: String, _ en: String) -> String { state.language.hasPrefix("it") ? it : en }

    private var hint: String {
        t("Tieni premuto un trigger e parla (rilascia per incollare), oppure doppio click per iniziare e doppio click per fermare.",
          "Hold a trigger and speak (release to paste), or double-press to start and double-press to stop.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: state.status.symbol)
                Text("Dictat — \(state.status.label)").font(.headline).lineLimit(1)
            }

            Toggle(t("Abilita dettatura", "Enable dictation"), isOn: $state.enabled)

            if !allPerms {
                Divider()
                Text(t("Permessi mancanti", "Missing permissions")).font(.caption).bold().foregroundStyle(.orange)
                permRow(t("Microfono", "Microphone"), perm.mic) { perm.requestMic() }
                permRow(t("Riconoscimento vocale", "Speech Recognition"), perm.speech) { perm.requestSpeech() }
                permRow(t("Accessibilità (per incollare)", "Accessibility (paste)"), perm.accessibility) { perm.requestAccessibility() }
                permRow(t("Input Monitoring (hotkey globale)", "Input Monitoring (global hotkey)"), perm.inputMonitoring) { perm.requestInputMonitoring() }
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(t("Trigger (max 5)", "Triggers (max 5)")).font(.caption).foregroundStyle(.secondary)
                ForEach(state.bindings) { b in
                    HStack(spacing: 8) {
                        Image(systemName: b.isMouse ? "computermouse" : "keyboard").foregroundStyle(.secondary)
                        Text(b.label).lineLimit(1)
                        Spacer()
                        if state.bindings.count > 1 {
                            Button { state.removeBinding(b) } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.red)
                        }
                    }
                }
                if state.bindings.count < AppState.maxBindings {
                    Button(t("Aggiungi trigger…", "Add trigger…")) { onRecordKey() }.controlSize(.small)
                }
            }

            Divider()
            HStack {
                Text(t("Lingua", "Language"))
                Picker("", selection: $state.language) {
                    Text("🇮🇹 Italiano").tag("it-IT")
                    Text("🇬🇧 English").tag("en-US")
                }.labelsHidden().fixedSize()
                Spacer()
            }
            Toggle(t("Solo riconoscimento on-device", "On-device recognition only"), isOn: $state.onDeviceOnly)
            Toggle(t("Punteggiatura automatica", "Automatic punctuation"), isOn: $state.autoPunctuation)

            if !state.lastTranscript.isEmpty {
                Divider()
                Text(t("Ultima trascrizione", "Last transcript")).font(.caption).foregroundStyle(.secondary)
                Text(state.lastTranscript).font(.caption).lineLimit(3)
                HStack {
                    Button(t("Copia", "Copy")) { NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(state.lastTranscript, forType: .string) }
                    Button(t("Incolla", "Paste")) { coord.pasteLast() }
                }
            }

            Divider()
            Text(hint).font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button(t("Controlla aggiornamenti…", "Check for updates…")) { onCheckUpdates() }
                Spacer()
                Button(t("Esci", "Quit")) { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var allPerms: Bool { perm.mic && perm.speech && perm.accessibility && perm.inputMonitoring }

    @ViewBuilder
    private func permRow(_ name: String, _ ok: Bool, _ action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(name).font(.caption)
            Spacer()
            if !ok { Button(t("Abilita…", "Enable…"), action: action).controlSize(.small) }
        }
    }
}

// MARK: - Key recorder (cattura qualsiasi tasto/modificatore)

struct KeyRecorderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard").font(.largeTitle)
            Text(L("Premi il tasto, il modificatore o il pulsante del mouse da usare",
                   "Press the key, modifier, or mouse button to use"))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text(L("Esc per annullare", "Esc to cancel")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 360)
    }
}

/// Costruisce un KeyBinding dal primo evento utile (modificatore, tasto o pulsante mouse).
func keyBinding(from ev: NSEvent) -> KeyBinding? {
    let kc = Int(ev.keyCode)
    if ev.type == .otherMouseDown {
        let btn = ev.buttonNumber                 // 2 = centrale, 3 = back, 4 = forward, …
        return KeyBinding(keyCode: btn, isModifier: false, isMouse: true,
                          modifierFlags: 0, label: "Mouse \(btn + 1)")
    }
    if ev.type == .flagsChanged {
        guard let flag = modifierFlag(forKeyCode: kc) else { return nil }
        let m = ev.modifierFlags
        let isOn: Bool
        switch flag {
        case .maskCommand:      isOn = m.contains(.command)
        case .maskAlternate:    isOn = m.contains(.option)
        case .maskControl:      isOn = m.contains(.control)
        case .maskShift:        isOn = m.contains(.shift)
        case .maskSecondaryFn:  isOn = m.contains(.function)
        default:                isOn = false
        }
        guard isOn else { return nil } // cattura solo alla pressione
        return KeyBinding(keyCode: kc, isModifier: true, modifierFlags: flag.rawValue,
                          label: keyName(keyCode: kc, isModifier: true))
    } else { // keyDown
        var cg: CGEventFlags = []
        var lbl = ""
        if ev.modifierFlags.contains(.control) { cg.insert(.maskControl); lbl += "⌃" }
        if ev.modifierFlags.contains(.option)  { cg.insert(.maskAlternate); lbl += "⌥" }
        if ev.modifierFlags.contains(.shift)   { cg.insert(.maskShift); lbl += "⇧" }
        if ev.modifierFlags.contains(.command) { cg.insert(.maskCommand); lbl += "⌘" }
        var name = keyName(keyCode: kc, isModifier: false)
        if name.hasPrefix("Key "), let ch = ev.charactersIgnoringModifiers, !ch.isEmpty {
            name = ch.uppercased()
        }
        return KeyBinding(keyCode: kc, isModifier: false, modifierFlags: cg.rawValue, label: lbl + name)
    }
}

// MARK: - Permiso (vendored from github.com/zats/permiso)
// Overlay che fluttua sopra Impostazioni di Sistema con una riga trascinabile
// (icona app → lista Accessibilità). Adattato: rimossi import/public, invariato il resto.

enum PermisoPanel: String, CaseIterable, Sendable {
    case accessibility = "Privacy_Accessibility"
    case screenRecording = "Privacy_ScreenCapture"
    case inputMonitoring = "Privacy_ListenEvent"

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var settingsURL: URL {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(rawValue)") else {
            preconditionFailure("Invalid System Settings URL for \(rawValue)")
        }
        return url
    }
}

struct PermisoHostApp: Sendable {
    let displayName: String
    let bundleURL: URL
    let icon: NSImage

    init(displayName: String, bundleURL: URL, icon: NSImage) {
        self.displayName = displayName
        self.bundleURL = bundleURL
        self.icon = icon
    }

    static func current(bundle: Bundle = .main) -> PermisoHostApp {
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: bundle.bundleURL.path)
        icon.size = NSSize(width: 48, height: 48)
        return PermisoHostApp(displayName: displayName, bundleURL: bundle.bundleURL, icon: icon)
    }
}

@MainActor
final class PermisoAssistant {
    static let shared = PermisoAssistant()

    private var overlayController: OverlayWindowController?
    private var trackingTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var activePanel: PermisoPanel?
    private var pendingSourceFrameInScreen: CGRect?
    private var didPresentCurrentOverlay = false

    var onGranted: (() -> Void)?
    init() {}

    private func grantedNow() -> Bool {
        switch activePanel {
        case .accessibility:   return AXIsProcessTrusted()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .inputMonitoring: return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        case .none:            return false
        }
    }

    private func handleGranted() {
        let cb = onGranted
        dismiss()
        NSApp.activate(ignoringOtherApps: true) // riporta avanti l'app: feedback "fatto"
        cb?()
    }

    func present(
        panel: PermisoPanel,
        hostApp: PermisoHostApp = .current(),
        sourceFrameInScreen: CGRect? = nil
    ) {
        activePanel = panel
        pendingSourceFrameInScreen = sourceFrameInScreen
        didPresentCurrentOverlay = false
        overlayController = OverlayWindowController(hostApp: hostApp, panel: panel) { [weak self] in
            self?.dismiss()
        }
        NSWorkspace.shared.open(panel.settingsURL)
        startTracking()
    }

    func dismiss() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        overlayController?.close()
        overlayController = nil
        activePanel = nil
        pendingSourceFrameInScreen = nil
        didPresentCurrentOverlay = false
    }

    private func startTracking() {
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Appena il permesso è attivo, chiudi l'overlay → l'utente capisce che è fatto.
                if self.grantedNow() { self.handleGranted(); return }
                self.refreshPosition()
            }
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPosition()
            }
        }
        refreshPosition()
    }

    private func refreshPosition() {
        guard let snapshot = SettingsWindowLocator.frontmostWindow() else {
            overlayController?.hide()
            return
        }
        if didPresentCurrentOverlay {
            overlayController?.updatePosition(with: snapshot.frame, visibleFrame: snapshot.visibleFrame)
            return
        }

        overlayController?.present(
            from: pendingSourceFrameInScreen,
            settingsFrame: snapshot.frame,
            visibleFrame: snapshot.visibleFrame
        )
        didPresentCurrentOverlay = true
    }
}

struct SettingsWindowSnapshot: Equatable {
    let pid: pid_t
    let frame: CGRect
    let visibleFrame: CGRect
}

enum SettingsWindowLocator {
    static let bundleIdentifier = "com.apple.systempreferences"

    static var isSystemSettingsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
    }

    static func frontmostWindow() -> SettingsWindowSnapshot? {
        guard isSystemSettingsFrontmost else { return nil }

        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .max(by: { ($0.activationPolicy == .prohibited ? 0 : 1) < ($1.activationPolicy == .prohibited ? 0 : 1) }) else {
            return nil
        }

        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], .zero) as? [[String: Any]] else {
            return nil
        }

        let windows = windowInfo.compactMap { info -> SettingsWindowSnapshot? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == app.processIdentifier else { return nil }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { return nil }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }

            let cgFrame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
            )
            let converted = appKitGeometry(from: cgFrame)
            let frame = converted.frame
            guard frame.width > 320, frame.height > 240 else { return nil }
            return SettingsWindowSnapshot(pid: ownerPID, frame: frame, visibleFrame: converted.visibleFrame)
        }

        return windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }

    private static func appKitGeometry(from cgFrame: CGRect) -> (frame: CGRect, visibleFrame: CGRect) {
        let screens = NSScreen.screens.compactMap { screen -> (frame: CGRect, visibleFrame: CGRect, cgBounds: CGRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            return (frame: screen.frame, visibleFrame: screen.visibleFrame, cgBounds: CGDisplayBounds(displayID))
        }

        let matchedScreen = screens
            .filter { $0.cgBounds.intersects(cgFrame) }
            .max { lhs, rhs in
                lhs.cgBounds.intersection(cgFrame).width * lhs.cgBounds.intersection(cgFrame).height
                    < rhs.cgBounds.intersection(cgFrame).width * rhs.cgBounds.intersection(cgFrame).height
            }

        guard let matchedScreen else {
            let mainVisibleFrame = NSScreen.main?.visibleFrame ?? CGRect(origin: .zero, size: cgFrame.size)
            return (frame: cgFrame, visibleFrame: mainVisibleFrame)
        }

        let localX = cgFrame.minX - matchedScreen.cgBounds.minX
        let localY = cgFrame.minY - matchedScreen.cgBounds.minY
        let frame = CGRect(
            x: matchedScreen.frame.minX + localX,
            y: matchedScreen.frame.maxY - localY - cgFrame.height,
            width: cgFrame.width, height: cgFrame.height
        )
        return (frame: frame, visibleFrame: matchedScreen.visibleFrame)
    }
}

final class AppDragSourceView: NSView, NSPasteboardItemDataProvider, NSDraggingSource {
    private let hostApp: PermisoHostApp
    private let rowView = NSView()
    private let iconChrome = NSView()
    private let label = NSTextField(labelWithString: "")

    init(hostApp: PermisoHostApp) {
        self.hostApp = hostApp
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setDataProvider(self, forTypes: [.fileURL])
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(draggingFrame(), contents: draggingImage())
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .fileURL else { return }
        item.setData(hostApp.bundleURL.dataRepresentation, forType: .fileURL)
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { rowView.isHidden = true }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { rowView.isHidden = false }

    private func setup() {
        wantsLayer = true
        rowView.wantsLayer = true
        rowView.layer?.cornerRadius = 7
        rowView.layer?.borderWidth = 1
        rowView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowView)

        iconChrome.wantsLayer = true
        iconChrome.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        iconChrome.layer?.cornerRadius = 6
        iconChrome.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(iconChrome)

        let iconView = NSImageView(image: hostApp.icon)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconChrome.addSubview(iconView)

        label.stringValue = hostApp.displayName
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        label.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(label)

        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowView.topAnchor.constraint(equalTo: topAnchor),
            rowView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowView.heightAnchor.constraint(equalToConstant: 43),

            iconChrome.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 10),
            iconChrome.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            iconChrome.widthAnchor.constraint(equalToConstant: 26),
            iconChrome.heightAnchor.constraint(equalToConstant: 26),

            iconView.centerXAnchor.constraint(equalTo: iconChrome.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconChrome.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            label.leadingAnchor.constraint(equalTo: iconChrome.trailingAnchor, constant: 11),
            label.trailingAnchor.constraint(lessThanOrEqualTo: rowView.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: rowView.centerYAnchor)
        ])
    }

    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            rowView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            rowView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        } else {
            rowView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor
            rowView.layer?.borderColor = NSColor(red: 0.87451, green: 0.866667, blue: 0.862745, alpha: 1).cgColor
        }
    }

    private func draggingFrame() -> NSRect { convert(rowView.bounds, from: rowView) }

    private func draggingImage() -> NSImage {
        let image = NSImage(size: rowView.bounds.size)
        image.lockFocus()
        rowView.displayIgnoringOpacity(rowView.bounds, in: NSGraphicsContext.current!)
        image.unlockFocus()
        return image
    }
}

final class OverlayWindowController: NSWindowController {
    private let windowSize = NSSize(width: 530, height: 109)
    private let launchAnimationDuration: TimeInterval = 0.72
    private let launchAnimationResponse: Double = 0.72
    private let launchAnimationDampingFraction: Double = 1.0
    private let initialAlpha: CGFloat = 0.9
    private var launchDisplayLink: CADisplayLink?
    private var launchStartTime: CFTimeInterval = 0
    private var launchFromFrame = NSRect.zero
    private var launchToFrame = NSRect.zero
    private var isAnimatingLaunch = false

    init(hostApp: PermisoHostApp, panel: PermisoPanel, onBack: @escaping () -> Void) {
        let window = PassiveOverlayPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        configureWindow(window)
        window.contentView = OverlayContentView(hostApp: hostApp, panel: panel, onBack: onBack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func close() {
        stopLaunchAnimation()
        window?.orderOut(nil)
        super.close()
    }

    func present(from sourceFrameInScreen: CGRect?, settingsFrame: CGRect, visibleFrame: CGRect) {
        stopLaunchAnimation()
        guard let window else { return }
        let targetOrigin = anchoredOrigin(for: settingsFrame, visibleFrame: visibleFrame)
        let targetFrame = NSRect(origin: targetOrigin, size: windowSize)

        guard let sourceFrameInScreen, !sourceFrameInScreen.isEmpty else {
            isAnimatingLaunch = false
            window.alphaValue = 1
            window.setFrame(targetFrame, display: false)
            window.orderFrontRegardless()
            return
        }

        isAnimatingLaunch = true
        launchFromFrame = sourceFrameInScreen
        launchToFrame = targetFrame
        launchStartTime = CACurrentMediaTime()

        window.alphaValue = initialAlpha
        window.setFrame(sourceFrameInScreen, display: false)
        window.orderFrontRegardless()
        stepLaunchAnimation()

        let displayLink = window.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        displayLink.add(to: .main, forMode: .common)
        launchDisplayLink = displayLink
    }

    func updatePosition(with settingsFrame: CGRect, visibleFrame: CGRect) {
        guard let window else { return }
        let origin = anchoredOrigin(for: settingsFrame, visibleFrame: visibleFrame)
        launchToFrame.origin = origin
        guard !isAnimatingLaunch else { return }
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
    }

    func hide() {
        isAnimatingLaunch = false
        stopLaunchAnimation()
        window?.orderOut(nil)
    }

    private func configureWindow(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.animationBehavior = .none
    }

    private func stepLaunchAnimation() {
        guard let window else { stopLaunchAnimation(); return }
        let elapsed = max(0, CACurrentMediaTime() - launchStartTime)
        if elapsed >= launchAnimationDuration {
            isAnimatingLaunch = false
            stopLaunchAnimation()
            window.alphaValue = 1
            window.setFrame(launchToFrame, display: true)
            return
        }
        let progress = springProgress(at: elapsed)
        window.alphaValue = initialAlpha + ((1 - initialAlpha) * progress)
        window.setFrame(curvedFrame(from: launchFromFrame, to: launchToFrame, progress: progress), display: true)
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) { stepLaunchAnimation() }

    private func stopLaunchAnimation() {
        launchDisplayLink?.invalidate()
        launchDisplayLink = nil
    }

    private func springProgress(at elapsed: TimeInterval) -> CGFloat {
        let omega = (2 * Double.pi) / launchAnimationResponse
        let t = max(0, elapsed)
        let progress: Double
        if abs(launchAnimationDampingFraction - 1) < 0.0001 {
            progress = 1 - exp(-omega * t) * (1 + (omega * t))
        } else {
            progress = min(1, t / launchAnimationDuration)
        }
        return min(max(progress, 0), 1)
    }

    private func curvedFrame(from: NSRect, to: NSRect, progress: CGFloat) -> NSRect {
        let size = NSSize(
            width: from.size.width + ((to.size.width - from.size.width) * progress),
            height: from.size.height + ((to.size.height - from.size.height) * progress)
        )
        let startCenter = CGPoint(x: from.midX, y: from.midY)
        let endCenter = CGPoint(x: to.midX, y: to.midY)
        let midPoint = CGPoint(x: (startCenter.x + endCenter.x) * 0.5, y: max(startCenter.y, endCenter.y))
        let distance = hypot(endCenter.x - startCenter.x, endCenter.y - startCenter.y)
        let lift = min(140, max(44, distance * 0.18))
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y + lift)
        let inverse = 1 - progress
        let center = CGPoint(
            x: (inverse * inverse * startCenter.x) + (2 * inverse * progress * controlPoint.x) + (progress * progress * endCenter.x),
            y: (inverse * inverse * startCenter.y) + (2 * inverse * progress * controlPoint.y) + (progress * progress * endCenter.y)
        )
        return NSRect(x: center.x - (size.width * 0.5), y: center.y - (size.height * 0.5), width: size.width, height: size.height)
    }

    private func anchoredOrigin(for settingsFrame: CGRect, visibleFrame: CGRect) -> NSPoint {
        let sidebarWidth: CGFloat = 170
        let contentMinX = settingsFrame.minX + sidebarWidth
        let contentWidth = max(settingsFrame.width - sidebarWidth, windowSize.width)
        let preferredX = contentMinX + ((contentWidth - windowSize.width) / 2) - 8
        let preferredY = settingsFrame.minY + 14
        let minX = visibleFrame.minX + 8
        let maxX = visibleFrame.maxX - windowSize.width - 8
        let minY = visibleFrame.minY + 8
        let maxY = visibleFrame.maxY - windowSize.height - 8
        return NSPoint(x: min(max(preferredX, minX), maxX), y: min(max(preferredY, minY), maxY))
    }
}

private final class PassiveOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class OverlayContentView: NSView {
    private let onBack: () -> Void

    init(hostApp: PermisoHostApp, panel: PermisoPanel, onBack: @escaping () -> Void) {
        self.onBack = onBack
        super.init(frame: NSRect(x: 0, y: 0, width: 530, height: 109))
        translatesAutoresizingMaskIntoConstraints = false
        setup(hostApp: hostApp, panel: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup(hostApp: PermisoHostApp, panel: PermisoPanel) {
        let materialView = NSVisualEffectView()
        materialView.translatesAutoresizingMaskIntoConstraints = false
        materialView.material = .popover
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = 18
        materialView.layer?.masksToBounds = true
        materialView.layer?.borderWidth = 0.5
        materialView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        addSubview(materialView)

        let tintView = NSView()
        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.78).cgColor
        materialView.addSubview(tintView)

        let backChrome = NSView()
        backChrome.translatesAutoresizingMaskIntoConstraints = false
        backChrome.wantsLayer = true
        backChrome.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.95).cgColor
        backChrome.layer?.cornerRadius = 16
        materialView.addSubview(backChrome)

        let backButton = NSButton()
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.isBordered = false
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.contentTintColor = NSColor.labelColor.withAlphaComponent(0.72)
        backButton.target = self
        backButton.action = #selector(backPressed)
        if let cell = backButton.cell as? NSButtonCell { cell.imagePosition = .imageOnly }
        backChrome.addSubview(backButton)

        let arrowView = NSImageView()
        arrowView.translatesAutoresizingMaskIntoConstraints = false
        arrowView.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        arrowView.symbolConfiguration = .init(pointSize: 28, weight: .bold)
        arrowView.contentTintColor = NSColor(calibratedRed: 0.15, green: 0.54, blue: 0.98, alpha: 1)
        materialView.addSubview(arrowView)

        let titleLabel = NSTextField(labelWithAttributedString: title(hostApp: hostApp, panel: panel))
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        materialView.addSubview(titleLabel)

        let dragSource = AppDragSourceView(hostApp: hostApp)
        materialView.addSubview(dragSource)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 530),
            heightAnchor.constraint(equalToConstant: 109),

            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: materialView.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: materialView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: materialView.bottomAnchor),

            backChrome.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 18),
            backChrome.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 52),
            backChrome.widthAnchor.constraint(equalToConstant: 32),
            backChrome.heightAnchor.constraint(equalToConstant: 32),

            backButton.centerXAnchor.constraint(equalTo: backChrome.centerXAnchor),
            backButton.centerYAnchor.constraint(equalTo: backChrome.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 14),
            backButton.heightAnchor.constraint(equalToConstant: 14),

            arrowView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 35),
            arrowView.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 10),
            arrowView.widthAnchor.constraint(equalToConstant: 28),
            arrowView.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: arrowView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: arrowView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -22),

            dragSource.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 64),
            dragSource.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -21),
            dragSource.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 47),
            dragSource.heightAnchor.constraint(equalToConstant: 43)
        ])
    }

    private func title(hostApp: PermisoHostApp, panel: PermisoPanel) -> NSAttributedString {
        NSAttributedString(
            string: "Trascina \(hostApp.displayName) nella lista qui sopra per abilitare \(panel.title)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.82)
            ]
        )
    }

    @objc private func backPressed() { onBack() }
}
