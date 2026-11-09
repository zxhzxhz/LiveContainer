//
//  LCGameControllerManager.swift
//  LiveContainerSwiftUI
//
//  Maps game controller input to list navigation commands for the app list.
//

import Combine
import Foundation
import GameController
import UIKit

enum LCControllerCommand: Equatable {
    case moveUp
    case moveDown
    case confirm       // A
    case cancel        // B
    case contextMenu   // X / Menu
    case openSettings  // Y
    case previousTab   // LB
    case nextTab       // RB
    case toggleSearch  // Options / View
}

extension Notification.Name {
    /// Posted when the cancel command should close a controller-opened menu.
    static let LCGameControllerCancel = Notification.Name("LCGameControllerCancel")
}

@MainActor
final class LCGameControllerManager: ObservableObject {
    static let shared = LCGameControllerManager()

    @Published private(set) var isControllerConnected = false
    /// Whether the focus ring should be drawn. Touch scrolling hides it without
    /// losing the logical focus index.
    @Published var isFocusRingVisible = false
    /// Index inside the currently displayed focusable list.
    @Published var focusedIndex = 0
    /// True while a folder detail page is active on the navigation stack so the
    /// root app list yields controller events to the folder view.
    @Published var isInFolderView = false
    /// True while a controller-triggered quick action sheet is presented.
    @Published var isQuickActionSheetPresented = false

    let commandPublisher = PassthroughSubject<LCControllerCommand, Never>()

    private var repeatTimer: Timer?
    private var activeDirection: LCControllerCommand?
    private let thumbstickDeadzone: Float = 0.55
    private let thumbstickReleaseZone: Float = 0.25
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private var boundControllers: Set<ObjectIdentifier> = []
    private var pendingBindRetries: Set<ObjectIdentifier> = []

    private init() {
        setupNotifications()
        refreshConnectedControllers()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshConnectedControllers()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshConnectedControllers()
            }
        }
    }

    func refreshConnectedControllers() {
        let controllers = GCController.controllers()
        isControllerConnected = !controllers.isEmpty
        if !isControllerConnected {
            stopRepeatTimer()
            isFocusRingVisible = false
            boundControllers.removeAll()
            return
        }
        // Drop stale identifiers so a controller that was disconnected while
        // another one stayed connected is rebound when it comes back.
        boundControllers.formIntersection(Set(controllers.map { ObjectIdentifier($0) }))
        for controller in controllers {
            bindController(controller)
        }
    }

    /// Called on any touch interaction: hide the visual focus ring but keep the
    /// logical index so the next D-Pad press continues from the same row.
    func notifyTouchInteraction(updatingIndex newIndex: Int? = nil) {
        stopRepeatTimer()
        if let newIndex {
            focusedIndex = newIndex
        }
        if isFocusRingVisible {
            isFocusRingVisible = false
        }
    }

    private func bindController(_ controller: GCController) {
        let identifier = ObjectIdentifier(controller)
        guard !boundControllers.contains(identifier) else {
            return
        }
        // The input profile can arrive a moment after the connect notification.
        guard controller.extendedGamepad != nil || controller.microGamepad != nil else {
            if pendingBindRetries.insert(identifier).inserted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    Task { @MainActor in
                        self?.pendingBindRetries.remove(identifier)
                        self?.refreshConnectedControllers()
                    }
                }
            }
            return
        }
        boundControllers.insert(identifier)

        if let gamepad = controller.extendedGamepad {
            gamepad.dpad.valueChangedHandler = { [weak self] _, _, yValue in
                Task { @MainActor in
                    self?.handleVerticalAxis(yValue)
                }
            }
            gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, _, yValue in
                Task { @MainActor in
                    self?.handleVerticalAxis(yValue)
                }
            }
            gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.emitCommand(.confirm) }
            }
            gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.emitCommand(.cancel) }
            }
            gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.emitCommand(.contextMenu) }
            }
            gamepad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.emitCommand(.openSettings) }
            }
            gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.emitCommand(.contextMenu) }
            }
            gamepad.buttonOptions?.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.emitCommand(.toggleSearch) }
            }
            gamepad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.emitCommand(.previousTab) }
            }
            gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.emitCommand(.nextTab) }
            }
        } else if let micro = controller.microGamepad {
            micro.dpad.valueChangedHandler = { [weak self] _, _, yValue in
                Task { @MainActor in
                    self?.handleVerticalAxis(yValue)
                }
            }
            micro.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.emitCommand(.confirm) }
            }
            micro.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.emitCommand(.contextMenu) }
            }
        }
    }

    private func handleVerticalAxis(_ yValue: Float) {
        if yValue >= thumbstickDeadzone {
            startDirectionalInput(.moveUp)
        } else if yValue <= -thumbstickDeadzone {
            startDirectionalInput(.moveDown)
        } else if abs(yValue) <= thumbstickReleaseZone {
            stopRepeatTimer()
        }
    }

    private func startDirectionalInput(_ direction: LCControllerCommand) {
        guard activeDirection != direction else {
            return
        }
        stopRepeatTimer()
        activeDirection = direction
        emitCommand(direction)

        // First press moves one row, then auto-repeat after a short delay.
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let currentDir = self.activeDirection else { return }
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.emitCommand(currentDir)
                    }
                }
            }
        }
    }

    private func stopRepeatTimer() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        activeDirection = nil
    }

    private func emitCommand(_ command: LCControllerCommand) {
        if !isFocusRingVisible {
            isFocusRingVisible = true
        }
        if isQuickActionSheetPresented {
            if command == .cancel {
                isQuickActionSheetPresented = false
                NotificationCenter.default.post(name: .LCGameControllerCancel, object: nil)
            }
            return
        }
        if command == .moveUp || command == .moveDown {
            selectionFeedback.selectionChanged()
        }
        commandPublisher.send(command)
    }
}
