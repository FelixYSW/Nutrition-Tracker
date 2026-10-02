import SwiftUI
import SwiftData
import Charts

/// Macro and calorie trends over daily / weekly / monthly scales
/// (spec section 15).
///
/// The target band is shaded on the chart with the same three-state logic the
/// Dashboard rings use, so an over or under day is obvious here too rather than
/// being judged by a different scheme.
struct TrendsView: View {
    @Environment(\.modelContext) private var context

    /// Tapping a bar jumps back to the Day view for that date.
    var onSelectDate: (Date) -> Void

    @Query private var allEntries: [FoodEntry]
    @Query(sort: \NutritionTarget.updatedAt, order: .reverse) private var targets: [NutritionTarget]

    @State private var scale: TrendScale = .daily
    @State private var nutrient: Nutrient = .calories

    /// Computed on the fly from `FoodEntry` records; nothing is persisted.
    private var buckets: [TrendBucket] {
        TrendAggregator.buckets(entries: allEntries, scale: scale, endingOn: .now)
    }

    private var range: NutrientRange {
        targets.first?.ranges[nutrient] ?? .zero
    }

    private var bucketsWithData: [TrendBucket] {
        buckets.filter(\.hasData)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
            controls

            if bucketsWithData.isEmpty {
                EmptyStateView(
                    title: "Not enough data yet",
                    message: "Log some food and your \(scale.displayName.lowercased()) "
                        + "trend will appear here.",
                    systemImage: "chart.xyaxis.line")
                    .appCard()
            } else {
                chartCard
                summaryCard
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Scale", selection: $scale) {
                ForEach(TrendScale.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            // Scrollable rather than segmented: five nutrients will not fit
            // across an SE at larger text sizes.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Nutrient.allCases) { candidate in
                        Button {
                            withAnimation(.snappy) { nutrient = candidate }
                        } label: {
                            Text(candidate.displayName)
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    nutrient == candidate
                                        ? AppTheme.color(for: candidate).opacity(0.18)
                                        : AppTheme.subtleFill,
                                    in: Capsule())
                                .foregroundStyle(nutrient == candidate
                                    ? AppTheme.color(for: candidate)
                                    : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            nutrient == candidate ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(scale.plotsDailyAverage
                     ? "Daily average per \(scale == .weekly ? "week" : "month")"
                     : "Per day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if range.max > 0 {
                    Label("Target band", systemImage: "rectangle.fill")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.color(for: nutrient).opacity(0.5))
                }
            }

            Chart {
                // The shaded target band, drawn behind the bars.
                if range.max > 0,
                   let first = buckets.first?.interval.start,
                   let last = buckets.last?.interval.end {
                    RectangleMark(
                        xStart: .value("Start", first),
                        xEnd: .value("End", last),
                        yStart: .value("Minimum", range.min),
                        yEnd: .value("Maximum", range.max))
                        .foregroundStyle(AppTheme.color(for: nutrient).opacity(0.14))

                    RuleMark(y: .value("Minimum", range.min))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(AppTheme.color(for: nutrient).opacity(0.5))

                    RuleMark(y: .value("Maximum", range.max))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(AppTheme.color(for: nutrient).opacity(0.5))
                }

                ForEach(buckets) { bucket in
                    if bucket.hasData {
                        let value = bucket.plotValue(for: scale)[nutrient]
                        BarMark(
                            x: .value(scale.displayName, bucket.interval.start,
                                      unit: scale.calendarComponent),
                            y: .value(nutrient.displayName, value))
                            .foregroundStyle(
                                AppTheme.color(for: range.state(consumed: value),
                                               nutrient: nutrient))
                            // A sparse bucket is drawn hollow-ish so an average
                            // over two logged days is not read as a full week.
                            .opacity(bucket.isSparse ? 0.45 : 1)
                            .cornerRadius(3)
                    }
                }
            }
            .chartYAxisLabel(nutrient.unitLabel)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: axisFormat, centered: true)
                }
            }
            .frame(height: 220)
            .chartOverlay { proxy in
                // Tap anywhere to jump to that bucket's day.
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let plotFrame = proxy.plotFrame else { return }
                            let origin = geometry[plotFrame].origin
                            guard let date: Date = proxy.value(
                                atX: location.x - origin.x) else { return }
                            onSelectDate(date)
                            Haptics.selection()
                        }
                }
            }
            .accessibilityLabel("\(nutrient.displayName) \(scale.displayName) trend")

            if buckets.contains(where: \.isSparse) {
                Text("Faded bars cover periods where fewer than half the days "
                     + "were logged, so the average is only partial.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .appCard()
    }

    private var axisFormat: Date.FormatStyle {
        switch scale {
        case .daily: .dateTime.day().month(.abbreviated)
        case .weekly: .dateTime.day().month(.abbreviated)
        case .monthly: .dateTime.month(.abbreviated)
        }
    }

    private var summaryCard: some View {
        let tally = TrendAggregator.tally(buckets: buckets, nutrient: nutrient,
                                          range: range, scale: scale)
        let unit = scale == .daily ? "day" : (scale == .weekly ? "week" : "month")

        return VStack(alignment: .leading, spacing: 10) {
            AppSectionHeading(title: "Summary")

            if range.max <= 0 {
                Text("Set a \(nutrient.displayName.lowercased()) target to see how "
                     + "these compare.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                summaryRow(state: .within, count: tally.within, unit: unit)
                summaryRow(state: .under, count: tally.under, unit: unit)
                summaryRow(state: .over, count: tally.over, unit: unit)

                if tally.noData > 0 {
                    Text("\(tally.noData) \(unit)\(tally.noData == 1 ? "" : "s") with "
                         + "nothing logged.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .appCard()
    }

    private func summaryRow(state: RangeState, count: Int, unit: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(AppTheme.color(for: state, nutrient: nutrient))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(label(for: state))
                .font(.footnote)
            Spacer(minLength: 4)
            Text("\(count) \(unit)\(count == 1 ? "" : "s")")
                .font(.footnote.weight(.medium))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func label(for state: RangeState) -> String {
        switch state {
        case .under: "Below the minimum"
        case .within: "In range"
        case .over: "Above the maximum"
        }
    }
}
