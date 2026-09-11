import Charts
import SwiftUI

/// One shared ramp so a number means the same thing in every panel:
/// green is healthy, red needs attention.
enum Severity {
    static func color(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: return .green
        case ..<0.8: return .yellow
        case ..<0.92: return .orange
        default: return .red
        }
    }
}

struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 7) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 0.5))
    }
}

/// Circular gauge used for the headline numbers on the overview.
struct RingGauge: View {
    let fraction: Double
    let label: String
    let caption: String
    var tint: Color?
    var size: CGFloat = 108

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: size * 0.1)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint ?? Severity.color(for: fraction),
                        style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.35), value: fraction)
            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(caption)
                    .font(.system(size: size * 0.1))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Horizontal bar that can show several stacked components (app/wired/compressed).
struct SegmentedBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        let value: Double
        let color: Color
        let label: String
    }

    let segments: [Segment]
    let total: Double
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    let width = total > 0 ? geometry.size.width * (segment.value / total) : 0
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(0, width))
                        .help("\(segment.label): \(Fmt.bytes(segment.value))")
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(.quaternary.opacity(0.5))
        .clipShape(Capsule())
    }
}

struct UsageBar: View {
    let fraction: Double
    var tint: Color?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.6))
                Capsule()
                    .fill(tint ?? Severity.color(for: fraction))
                    .frame(width: geometry.size.width * max(0, min(1, fraction)))
                    .animation(.easeOut(duration: 0.3), value: fraction)
            }
        }
        .frame(height: height)
    }
}

/// Filled line chart over the rolling history window.
struct TrendChart: View {
    let history: History
    let tint: Color
    /// Nil lets the chart auto-scale (rates); a value pins the axis (percentages).
    var upperBound: Double?
    var valueFormatter: (Double) -> String = { Fmt.percent($0, decimals: 0) }
    var height: CGFloat = 90

    private var maximum: Double {
        if let upperBound { return upperBound }
        return max(history.peak * 1.15, 1)
    }

    var body: some View {
        Chart(history.points) { point in
            AreaMark(x: .value("Time", point.time), y: .value("Value", min(point.value, maximum)))
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", point.time), y: .value("Value", min(point.value, maximum)))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...maximum)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, maximum / 2, maximum]) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(valueFormatter(number)).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: height)
    }
}

/// Compact label/value row used throughout the detail panels.
struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var monospaced = true

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var caption: String?
    var systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
    }
}

/// Standard page chrome: a title, an optional subtitle, and a scrolling body.
struct PageScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 22, weight: .bold))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 2)
                content
            }
            .padding(20)
        }
        .background(.background)
    }
}
