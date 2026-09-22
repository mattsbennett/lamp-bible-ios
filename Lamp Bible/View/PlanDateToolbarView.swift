//
//  PlanDateToolbar.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-08.
//

import SwiftUI

struct PlanDateToolbarView: ToolbarContent {
    @Binding var date: Date
    @Binding var showingDatePicker: Bool
    /// Full width of the screen, from the enclosing `GeometryReader`. A principal
    /// `ToolbarItem` is laid out at its ideal size, so the stepper can only claim
    /// the bar if it is given an explicit width.
    let availableWidth: CGFloat

    /// Space kept clear on the trailing edge for the presentation remote (a 44pt
    /// capsule), the bar's own margins, and the gap between the two.
    private let trailingAllowance: CGFloat = 86

    /// Everything the remote isn't using, within bounds that stop the date pill
    /// from stretching absurdly wide on iPad.
    private var stepperWidth: CGFloat {
        min(max(availableWidth - trailingAllowance, 200), 520)
    }

    /// Candidate label widths, widest first. `ViewThatFits` walks these in order
    /// and takes the first that fits the pill, so the full form shows whenever
    /// there is room and only degrades under real pressure — a narrow device, a
    /// long weekday/month pairing, or large Dynamic Type.
    private enum LabelWidth: CaseIterable {
        case full        // Sunday, August 30
        case abbreviated // Sun, Aug 30
        case minimal     // Aug 30
    }

    /// A year is appended whenever the date falls outside the current one, at
    /// every width. That used to force a permanent downgrade to the abbreviated
    /// form; now it just makes the wider candidates less likely to be chosen.
    private func dateLabel(_ width: LabelWidth) -> String {
        let calendar = Calendar.current
        let isCurrentYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: Date.now)

        var style: Date.FormatStyle
        switch width {
        case .full:
            style = .dateTime.weekday(.wide).day().month(.wide)
        case .abbreviated:
            style = .dateTime.weekday().day().month()
        case .minimal:
            style = .dateTime.day().month()
        }

        if !isCurrentYear {
            style = style.year()
        }

        return date.formatted(style)
    }

    var body: some ToolbarContent {
        // All three controls live in the principal slot so the stepper reads as
        // one unit centred in the bar. Splitting it across leading/principal/
        // trailing let the presentation remote crowd into the trailing edge and
        // pushed the date off centre.
        ToolbarItem(placement: .principal) {
            HStack(spacing: 6) {
                stepButton(days: -1, systemImage: "chevron.left")
                dateButton
                stepButton(days: 1, systemImage: "chevron.right")
            }
            .frame(width: stepperWidth)
        }
    }

    /// Each arrow gets its own glass circle sized to match the presentation
    /// remote across the bar.
    ///
    /// This deliberately avoids `buttonStyle(.glass)`, which derives its capsule
    /// from the label's intrinsic size and its own control metrics: a chevron is a
    /// much narrower glyph than the remote's `play.rectangle.on.rectangle`, so it
    /// came out visibly smaller, and neither a frame on the label nor one on the
    /// finished button would override it. `glassEffect` takes the shape and the
    /// size from us instead.
    private func stepButton(days: Int, systemImage: String) -> some View {
        Button {
            date = Calendar.current.date(byAdding: .day, value: days, to: date)!
        } label: {
            stepLabel(systemImage)
        }
        .buttonStyle(.plain)
    }

    /// Pre-26 has no Liquid Glass, and these arrows carried no background there
    /// either, so the fallback is the bare glyph at the same 44pt target.
    @ViewBuilder
    private func stepLabel(_ systemImage: String) -> some View {
        let glyph = Image(systemName: systemImage)
            .frame(width: 44, height: 44)

        if #available(iOS 26.0, *) {
            glyph
                .glassEffect(.regular, in: Circle())
                .contentShape(Circle())
        } else {
            glyph.contentShape(Rectangle())
        }
    }

    /// One candidate label. `fixedSize` is what makes the fitting work: without it
    /// a `Text` reports that it fits at any width by truncating, so `ViewThatFits`
    /// would always settle on the first candidate.
    private func dateRow(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(Image(systemName: "calendar"))
                .font(.system(size: 17))
                .foregroundColor(Calendar.current.isDate(date, inSameDayAs: Date.now) ? .accentColor : .primary)
            Text(text)
                .font(.system(size: 16))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var dateButton: some View {
        Button {
            showingDatePicker.toggle()
        } label: {
            // Listed out rather than driven by a ForEach: ViewThatFits picks
            // between its direct subviews, and a ForEach is one subview.
            ViewThatFits(in: .horizontal) {
                dateRow(dateLabel(.full))
                dateRow(dateLabel(.abbreviated))
                dateRow(dateLabel(.minimal))
            }
            // The arrows are fixed-size circles, so all the slack in the row
            // lands here and the date pill grows to fill the bar. This also
            // gives ViewThatFits the width it measures its candidates against.
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .modifier(ConditionalGlassButtonStyle())
        .sheet(
            isPresented: $showingDatePicker
        ) {
                NavigationStack {
                    DatePicker(selection: $date, displayedComponents: [.date]){
                    }
                        .datePickerStyle(.graphical)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button {
                                    date = Date.now
                                    showingDatePicker = false
                                } label: {
                                    Text("Today")
                                }
                                .tint(.accentColor)
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button {
                                    showingDatePicker = false
                                } label: {
                                    Text("Done")
                                }
                            }
                        }
                    }
                    .presentationDetents([.height(455)])
                    .presentationDragIndicator(.visible)
                    .padding()
        }
    }
}
