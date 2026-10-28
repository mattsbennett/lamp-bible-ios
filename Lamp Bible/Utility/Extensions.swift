//
//  Extensions.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-02.
//

import SwiftUI

struct ConditionalGlassButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content
        }
    }
}

extension View {
    // Applies the given transform if the given condition evaluates to `true`.
    // - Parameters:
    //   - condition: The condition to evaluate.
    //   - transform: The transform to apply to the source `View`.
    // - Returns: Either the original `View` or the modified `View` if the condition is `true`.
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// https://stackoverflow.com/a/71935810/3362399
// Resolves issue where NavigationLink elements inside a toolbar don't allow swipe-back navigation
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return viewControllers.count > 1
    }

    // To make it work also with ScrollView
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

extension UIApplication {
    /// Sees work begun as the app leaves the foreground, such as an edit's
    /// save, through to its end. Without asking for the time the app can be
    /// suspended partway, and closed from the switcher before it resumes.
    @MainActor
    func finishing(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = beginBackgroundTask(withName: name) { [self] in
            endBackgroundTask(taskId)
            taskId = .invalid
        }
        Task { @MainActor in
            await work()
            if taskId != .invalid {
                endBackgroundTask(taskId)
                taskId = .invalid
            }
        }
    }
}

extension Calendar {
    static let iso8601 = Calendar(identifier: .iso8601)
}

extension Int {
    // Approach with most performance, adqequate accuracy
    // https://stackoverflow.com/a/73590526/3362399
    var isALeapYear: Bool {
        if self % 4 != 0 { return false }
        if self % 400 == 0 { return true }
        if self % 100 == 0 { return false }
        return true
    }
}
