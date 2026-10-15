// 전역 핫키.
//
// Carbon의 RegisterEventHotKey를 쓴다. NSEvent 전역 모니터와 달리 키 입력을
// '소비'하기 때문에, 핫키가 미러링 창을 거쳐 아이폰까지 전달되지 않는다.
// 이게 이 앱에서는 결정적이다 — ⌘C가 미러링된 iOS 앱으로 새어 들어가면 안 된다.

import AppKit
import Carbon.HIToolbox

struct HotKey {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    static let capture = HotKey(keyCode: UInt32(kVK_ANSI_C),
                                modifiers: UInt32(optionKey | cmdKey), label: "⌥⌘C")
    static let toggle = HotKey(keyCode: UInt32(kVK_ANSI_S),
                               modifiers: UInt32(optionKey | cmdKey), label: "⌥⌘S")
    static let panic = HotKey(keyCode: UInt32(kVK_ANSI_Period),
                              modifiers: UInt32(optionKey | cmdKey), label: "⌥⌘.")
}

final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var installed = false

    private init() {}

    /// 등록 실패를 조용히 삼키면 "핫키가 안 먹는다"로만 보이고 원인을 알 수 없다.
    /// 실패한 핫키 라벨을 돌려주어 호출자가 사용자에게 알릴 수 있게 한다.
    @discardableResult
    func register(_ key: HotKey, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x54_50_50_52), id: id)  // 'TPPR'
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, hkID,
                                        GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("[Tapper] 핫키 \(key.label) 등록 실패 (status \(status)) — 다른 앱이 선점했을 수 있습니다")
            return false
        }
        handlers[id] = handler
        refs.append(ref)
        return true
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard err == noErr else { return err }
            Unmanaged<HotKeyCenter>.fromOpaque(userData)
                .takeUnretainedValue()
                .fire(hkID.id)
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func fire(_ id: UInt32) {
        // Carbon 핸들러는 메인 스레드에서 호출되지만, 호출자가 UI를 만지므로
        // 명시적으로 메인 큐에 올려 보장한다.
        DispatchQueue.main.async { self.handlers[id]?() }
    }
}
