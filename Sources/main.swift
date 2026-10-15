// 진입점. 메뉴바 전용 앱이므로 Dock 아이콘과 메뉴바 메뉴가 없다.

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var titleTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()
        controller.installHotKeys()

        // 상태를 매 탭마다 반영하면 초당 수십 번 UI를 건드린다.
        // 메뉴바 제목은 주기적으로만 갱신한다.
        titleTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.refreshTitle()
        }

        // 권한이 없으면 첫 실행에 바로 알려준다. 나중에 "안 된다"로 헤매지 않게.
        if !controller.axTrusted {
            controller.requestAXPermission()
            showPopover()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.panicStop()
        titleTimer?.invalidate()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.click",
                                           accessibilityDescription: "Tapper")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
    }

    private func setUpPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(controller: controller))
    }

    private func refreshTitle() {
        switch controller.state {
        case .idle:
            statusItem.button?.title = ""
        case .waiting:
            statusItem.button?.title = " 대기"
        case .running:
            statusItem.button?.title = " \(controller.taps)"
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        controller.refreshTrust()
        // accessory 앱은 활성화하지 않으면 팝오버의 TextField가 키 입력을
        // 받지 못한다. 숫자를 직접 입력받으려면 이게 필요하다.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // Dock 아이콘 없음
app.run()
