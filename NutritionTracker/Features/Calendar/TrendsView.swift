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

    /// Tapping a bar opens the Calendar on it: a daily bar on that day, a
    /// weekly or monthly bar on that whole week or month.
    var onSelect: (CalendarSelection) -> Void

    @Query private var allEntries: [FoodEntry]
    @Query(sort: \NutritionTarget.updatedAt, order: .reverse) private var targets: [NutritionTarget]

    @Environment(AppRouter.self) private var router

    // Kept by the router, so the same scale and nutrient are still chosen
    // after switching to Days or another tab and back.
    private var scale: TrendScale { router.trendsScale }
    private var nutrient: Nutrient { router.trendsNutrient }
    private var scaleBinding: Binding<TrendScale> {
        Binding(get: { router.trendsScale }, set: { router.trendsScale = $0 })
    }
    private var nutrientBinding: Binding<Nutrient> {
        Binding(get: { router.trendsNutrient }, set: { router.trendsNutrient = $0 })
    }

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
            }
        }
    }

    private var controls: some View {
        Picker("Scale", selection: scaleBinding) {
            ForEach(TrendScale.allCases) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(chartCaption)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                // The nutrient lives with the chart it changes.
                Picker("Nutrient", selection: nutrientBinding) {
                    ForEach(Nutrient.allCases) { nutrient in
                        Label(nutrient.displayName, systemImage: nutrient.symbolName)
                            .tag(nutrient)
                    }
                }
                .pickerStyle(.menu)
                .tint(AppTheme.accent)
                .accessibilityLabel("Nutrient")
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
                        // Green, like the in-range bars it holds.
                        .foregroundStyle(AppTheme.within.opacity(0.2))
                }

                ForEach(buckets) { bucket in
                    if bucket.hasData {
                        let value = bucket.plotValue(for: scale)[nutrient]
                        BarMark(
                            x: .value(scale.displayName, bucket.interval.start,
                                      unit: scale.calendarComponent),
                            y: .value(nutrient.displayName, value))
                            // Green in range, orange over, neutral grey under.
                            .foregroundStyle(
                                AppTheme.summaryColor(for: range.state(consumed: value)))
                            // A sparse bucket is drawn hollow-ish so an average
                            // over two logged days is not read as a full week.
                            .opacity(bucket.isSparse ? 0.45 : 1)
                            .cornerRadius(6)
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
                                atX: location.x - origin.x),
                                  let bucket = Self.bucket(containing: date, in: buckets) else {
                                return
                            }
                            onSelect(CalendarSelection(interval: bucket.interval, scale: scale))
                            Haptics.selection()
                        }
                }
            }
            .accessibilityLabel("\(nutrient.displayName) \(scale.displayName) trend")

            if range.max > 0 {
                legend
            }

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

    /// "Per day · last 14 days", "Daily average per week · last 8 weeks".
    private var chartCaption: String {
        let count = scale.bucketCount
        switch scale {
        case .daily: return "Per day \u{00B7} last \(count) days"
        case .weekly: return "Daily average per week \u{00B7} last \(count) weeks"
        case .monthly: return "Daily average per month \u{00B7} last \(count) months"
        }
    }

    /// What the band and each bar colour mean. Wraps at large text sizes.
    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { legendItems }
            VStack(alignment: .leading, spacing: 6) { legendItems }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var legendItems: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(AppTheme.within.opacity(0.35))
                .frame(width: 14, height: 10)
            Text("Target band")
        }
        legendDot("In range", AppTheme.within)
        legendDot("Under", AppTheme.stillToGo)
        legendDot("Over", AppTheme.over)
    }

    private func legendDot(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(title)
        }
    }

    /// The bar a tap belongs to: the one whose period contains it, else the
    /// nearest (taps at a bar's edge can fall just outside its period).
    static func bucket(containing date: Date, in buckets: [TrendBucket]) -> TrendBucket? {
        if let match = buckets.first(where: { $0.interval.contains(date) }) { return match }
        return buckets.min { lhs, rhs in
            abs(lhs.interval.start.addingTimeInterval(lhs.interval.duration / 2).timeIntervalSince(date))
                < abs(rhs.interval.start.addingTimeInterval(rhs.interval.duration / 2).timeIntervalSince(date))
        }
    }

    private var axisFormat: Date.FormatStyle {
        switch scale {
        case .daily: .dateTime.day().month(.abbreviated)
        case .weekly: .dateTime.day().month(.abbreviated)
        case .monthly: .dateTime.month(.abbreviated)
        }
    }
}
