import Carbon
import os

/// Global hot key through Carbon. Needs no permission.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private static let signature: OSType = 0x4E_46_49_4C // "NFIL"

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: virtual key code, e.g. `kVK_ANSI_F`.
    ///   - modifiers: Carbon modifiers, e.g. `cmdKey | optionKey | controlKey`.
    init?(id: UInt32, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        self.id = id
        Self.installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            Log.app.error("Hot key \(id, privacy: .public) not registered: OSStatus \(status, privacy: .public)")
            return nil
        }
        Self.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotKey.signature else { return OSStatus(eventNotHandledErr) }
            Log.app.info("Hot key \(hotKeyID.id, privacy: .public) pressed")
            DispatchQueue.main.async { HotKey.handlers[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
