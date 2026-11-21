import SwiftUI
import SwiftData
import Charts

/// The weight graph: every weigh-in as a dot, a 7-day average line through
/// them, and the goal weight as a dashed line. Lives in the Calendar tab next
/// to Trends.
struct WeightView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WeightEntry.date, order: .forward) private var entries: [WeightEntry]
    @Query private var profiles: [UserProfile]

    @State private var range: WeightRange = .threeMonths
    @State private var isLoggingWeight = false

    private var profile: UserProfile? { profiles.first }
    private var allPoints: [WeightPoint] { WeightStats.points(entries) }
    private var points: [WeightPoint] { WeightStats.filter(allPoints, range: range) }
    private var goal: Double? { profile?.targetWeightKg }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
            summaryCard

            Button {
                isLoggingWeight = true
            } label: {
                Label("Log weight", systemImage: "plus")
            }
            .buttonStyle(.appPrimary)
            .disabled(profile == nil)

            if points.isEmpty {
                EmptyStateView(
                    title: "No weigh-ins yet",
                    message: "Log your weight and your progress will be drawn here.",
                    systemImage: "scalemass")
                    .appCard()
            } else {
                chartCard
            }

            if !entries.isEmpty { historySection }
        }
        .sheet(isPresented: $isLoggingWeight) {
            if let profile { WeightCheckInSheet(profile: profile) }
        }
    }

    // MARK: Summary

    private var summaryCard: some View {
        let latest = allPoints.last?.kg ?? profile?.weightKg
        let change = WeightStats.change(points)
        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    currentWeight
                    Spacer()
                    rangePicker.frame(maxWidth: 220)
                }
                VStack(alignment: .leading, spacing: 10) {
                    currentWeight
                    rangePicker
                }
            }
            HStack(spacing: 8) {
                statTile(title: "Change", value: change.map { Self.signedKg($0) } ?? "-",
                         caption: range == .all ? "all time" : "last \(range.displayName)")
                if let goal, let latest {
                    statTile(title: "To goal", value: Self.signedKg(goal - latest),
                             caption: "goal \(Self.kg(goal))")
                } else {
                    statTile(title: "Goal", value: "Not set", caption: "set one in Profile")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private var currentWeight: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Current")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text((allPoints.last?.kg ?? profile?.weightKg).map { Self.kg($0) } ?? "-")
                .scaledHeavyNumber(34, relativeTo: .largeTitle)
                .monospacedDigit()
        }
    }

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(WeightRange.allCases) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private func statTile(title: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Chart

    private var chartCard: some View {
        // Worked out once per redraw; the chart reads them many times.
        let points = self.points
        let average = WeightStats.smoothed(points)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Weight \u{00B7} 7-day average")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Chart {
                if let goal {
                    RuleMark(y: .value("Goal", goal))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(AppTheme.within)
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Goal \(Self.kg(goal))")
                                .font(.caption2.weight(.semibold))
                                // The darker text green: the line's green is
                                // under 4.5:1 as text on a light card.
                                .foregroundStyle(AppTheme.stateTextColor(for: .within))
                        }
                }
                ForEach(points) { point in
                    PointMark(x: .value("Date", point.date), y: .value("Weight", point.kg))
                        .symbolSize(points.count > 60 ? 10 : 28)
                        .foregroundStyle(.secondary.opacity(0.55))
                }
                if average.count >= 2 {
                    ForEach(average) { point in
                        LineMark(x: .value("Date", point.date), y: .value("Average", point.kg))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                            .foregroundStyle(AppTheme.accent)
                    }
                }
            }
            .chartYScale(domain: WeightStats.yDomain(points, goal: goal))
            .chartYAxisLabel("kg")
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true)
                }
            }
            .frame(height: 240)
            .accessibilityLabel("Weight over time")
            .accessibilityValue(accessibilitySummary)
        }
        .appCard()
    }

    private var accessibilitySummary: String {
        guard let first = points.first, let last = points.last else { return "No data" }
        return "From \(Self.kg(first.kg)) to \(Self.kg(last.kg)) over \(points.count) weigh-ins"
    }

    // MARK: History

    /// The latest few; the full list, with swipe to delete, is one tap away.
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppSectionHeading(title: "Latest weigh-ins")
            ForEach(Array(entries.reversed().prefix(5))) { entry in
                WeighInRow(entry: entry)
                Divider()
            }
            NavigationLink {
                WeighInsListView()
            } label: {
                HStack {
                    Text("See all \(entries.count)")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: AppTheme.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .appCard()
    }

    // MARK: Formatting

    static func kg(_ value: Double) -> String { String(format: "%.1f kg", value) }

    static func signedKg(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == 0 { return "0.0 kg" }
        return String(format: "%+.1f kg", rounded)
    }
}

/// One weigh-in: its day and weight.
struct WeighInRow: View {
    let entry: WeightEntry

    var body: some View {
        HStack {
            Text(AppFormatters.dayTitle.string(from: entry.date))
                .font(.subheadline)
            Spacer()
            Text(WeightView.kg(entry.weightKg))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(minHeight: AppTheme.minimumTapTarget)
        .accessibilityElement(children: .combine)
    }
}

/// Every weigh-in, newest first, in a standard list: swipe left to delete,
/// or use Edit.
struct WeighInsListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WeightEntry.date, order: .reverse) private var entries: [WeightEntry]

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    WeighInRow(entry: entry)
                        .listRowBackground(AppTheme.cardBackground)
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(entries[index]) }
                    try? context.save()
                    Haptics.success()
                }
            } footer: {
                Text("Deleting a weigh-in removes it from the graph only. Your profile "
                     + "weight and daily ranges are not changed.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background.ignoresSafeArea())
        .overlay {
            if entries.isEmpty {
                EmptyStateView(title: "No weigh-ins",
                               message: "Log your weight from the Weight page.",
                               systemImage: "scalemass")
            }
        }
        .navigationTitle("Weigh-ins")
        .navigationBarTitleDisplayMode(.inline)
        // Calendar hides its bar for the page title; a pushed screen needs it
        // back for its title and the back button.
        .toolbar(.visible, for: .navigationBar)
        .toolbar { EditButton() }
    }
}
