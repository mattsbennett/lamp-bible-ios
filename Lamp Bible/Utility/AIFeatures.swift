//
//  AIFeatures.swift
//  Lamp Bible
//

import Combine
import LampModuleKit
import SwiftUI
import UIKit

/// Whether Lamp shows its AI features: plans made from a description, and
/// Apple's Writing Tools in Lamp's text. Off until someone turns it on, since
/// many readers want nothing to do with AI, and one choice covers every
/// device (`LampPreferenceDefaults.aiFeaturesKey`).
///
/// Nothing stored is not the same as off: an older build can write the
/// settings without it, and a library that already uses AI keeps it on. Where
/// nothing is stored, what this device has seen decides. The phone keeps
/// nothing that shows AI was used (a plan made from a description is saved as
/// any other is), so here that is the default until a choice arrives.
@MainActor
final class AIFeatures: ObservableObject {
    static let shared = AIFeatures()

    @Published private(set) var isEnabled: Bool

    /// The text views to tell when the switch changes, held weakly.
    private let textViews = NSHashTable<UITextView>.weakObjects()
    private var observer: NSObjectProtocol?

    private init() {
        isEnabled = Self.isEnabled(in: UserDatabase.shared.getSettings())
        // A choice made here, or one another device's sync brings.
        observer = NotificationCenter.default.addObserver(
            forName: .userDatabaseDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    static func isEnabled(in settings: UserSettings) -> Bool {
        settings.aiEnabled ?? LampPreferenceDefaults.aiFeaturesEnabled
    }

    /// Someone's choice: kept, and carried to the other devices by the sync
    /// pass the write starts.
    func choose(_ enabled: Bool) {
        try? UserDatabase.shared.updateSettings { $0.aiEnabled = enabled }
        refresh()
    }

    /// What Lamp's text offers of Apple's Writing Tools.
    var writingTools: UIWritingToolsBehavior { isEnabled ? .default : .none }

    /// Apple's Writing Tools in one of Lamp's text views only while the AI
    /// features are on: set now, and again when the switch changes.
    func govern(_ textView: UITextView) {
        textViews.add(textView)
        textView.writingToolsBehavior = writingTools
    }

    private func refresh() {
        let enabled = Self.isEnabled(in: UserDatabase.shared.getSettings())
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        for textView in textViews.allObjects {
            textView.writingToolsBehavior = writingTools
        }
        // A web view's is fixed when it is made, so the warm note editor is
        // made again; one open now keeps its own until it closes.
        TipTapPagePool.shared.warmUp(.note)
    }
}

/// Apple's Writing Tools in SwiftUI's text only while the AI features are on.
private struct AIFeaturesWritingTools: ViewModifier {
    @ObservedObject private var features = AIFeatures.shared

    func body(content: Content) -> some View {
        content.writingToolsBehavior(features.isEnabled ? .automatic : .disabled)
    }
}

extension View {
    /// Apple's Writing Tools in this view's text, in its editors and in what
    /// can be selected, only while the AI features are on.
    func writingToolsFollowAIFeatures() -> some View {
        modifier(AIFeaturesWritingTools())
    }
}
