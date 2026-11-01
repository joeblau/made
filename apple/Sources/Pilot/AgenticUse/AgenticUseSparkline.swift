import Charts
import SwiftUI

/// A chrome-free Swift Charts trend line with a tinted gradient fill
/// underneath — the KPI cards and the Top Models table both use it.
///
/// Points are positional (index on x) because every caller already passes a
/// contiguous, zero-filled bucket series; long series are binned so a 90-day
/// or All-history line stays readable at sparkline width.
struct AgenticUseSparkline: View {
    let values: [Double]
    let tint: Color
    /// Pin the y-domain to zero (volumes) or fit it to the data (rates such as
    /// cache hit rate, where a zero floor would flatten every change).
    var anchorsAtZero = true
    var lineWidth: CGFloat = 1.5

    /// Most points drawn; longer series are averaged into this many bins.
    private static let maxPoints = 45

    private struct Point: Identifiable {
        let id: Int
        let value: Double
    }

    private var points: [Point] {
        Self.binned(values, limit: Self.maxPoints).enumerated().map { Point(id: $0.offset, value: $0.element) }
    }

    var body: some View {
        let points = points
        let domain = yDomain(points)
        Chart(points) { point in
            AreaMark(
                x: .value("Bucket", point.id),
                yStart: .value("Floor", domain.lowerBound),
                yEnd: .value("Value", point.value)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(
                LinearGradient(
                    colors: [tint.opacity(0.32), tint.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            LineMark(
                x: .value("Bucket", point.id),
                y: .value("Value", point.value)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(tint)
            .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXScale(domain: 0...max(1, points.count - 1))
        .chartYScale(domain: domain)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func yDomain(_ points: [Point]) -> ClosedRange<Double> {
        let lo = points.map(\.value).min() ?? 0
        let hi = points.map(\.value).max() ?? 0
        if anchorsAtZero {
            return 0...max(hi * 1.08, .leastNonzeroMagnitude)
        }
        let pad = max((hi - lo) * 0.15, abs(hi) * 0.002, .leastNonzeroMagnitude)
        return (lo - pad)...(hi + pad)
    }

    /// Average consecutive runs so at most `limit` values remain. Static so
    /// the binning rule is unit-testable.
    nonisolated static func binned(_ values: [Double], limit: Int) -> [Double] {
        guard limit > 0, values.count > limit else { return values }
        let size = Double(values.count) / Double(limit)
        return (0..<limit).map { index in
            let start = Int((Double(index) * size).rounded(.down))
            let end = max(start + 1, Int((Double(index + 1) * size).rounded(.down)))
            let slice = values[start..<min(end, values.count)]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }
}
