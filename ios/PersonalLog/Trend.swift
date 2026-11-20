import Charts
import SwiftUI

/// A chart's trend line: a straight line, or a curve when one predicts the points clearly better.
/// Candidates: the line (least squares), a quadratic, and a local smoother (LOWESS: a weighted line through the
/// nearest 40 % of the points around each x, tricube weights). Each is scored by leave-one-out error (every point
/// predicted from the others), so a bendier fit only wins by predicting unseen days better, not by wiggling: a curve
/// is shown when its error is at least `curveGain` (5 %) below the line's. The line itself only counts as a trend when
/// it beats the plain average the same way; otherwise it is drawn faint as "no clear trend".
/// Raw points, nothing held equal (the effect estimates do that); filled-in days are left out by the callers.
struct TrendFit {
    enum Kind { case line, curve, none }
    let kind: Kind
    let points: [(x: Double, y: Double)]   // the line / curve over the x range, in data units
    let slope: Double                      // the line's (per x unit)
    let gain: Double                       // the chosen fit's error below the line's (curve) or the mean's (line), 0-1
    let turn: (x: Double, y: Double, peak: Bool)?   // a curve's highest / lowest point inside the range

    static let curveGain = 0.05
    static let minPoints = 8

    static func fit(_ pts: [(Double, Double)]) -> TrendFit? {
        let p = pts.filter { $0.0.isFinite && $0.1.isFinite }.sorted { $0.0 < $1.0 }
        guard p.count >= minPoints, let lo = p.first?.0, let hi = p.last?.0, hi > lo else { return nil }
        let xs = p.map(\.0), ys = p.map(\.1)
        guard let line = poly(xs, ys, degree: 1) else { return nil }
        let eMean = looMean(ys), eLine = loo(xs, ys) { x, y in poly(x, y, degree: 1) }
        let eQuad = Set(xs).count >= 4 ? loo(xs, ys) { x, y in poly(x, y, degree: 2) } : .infinity
        let eSmooth = Set(xs).count >= 6 ? looSmooth(xs, ys) : .infinity
        let grid = (0...40).map { lo + (hi - lo) * Double($0) / 40 }
        let slope = line([1]) - line([0])
        if min(eQuad, eSmooth) <= eLine * (1 - curveGain) {
            let quad = eQuad <= eSmooth ? poly(xs, ys, degree: 2) : nil
            let curve: [Double] = quad.map { q in grid.map { q([$0]) } } ?? smooth(xs, ys, at: grid)
            let gain = 1 - min(eQuad, eSmooth) / eLine
            // a turning point well inside the range (not at an end): where it peaks or bottoms out
            var turn: (x: Double, y: Double, peak: Bool)?
            if let iMax = curve.indices.max(by: { curve[$0] < curve[$1] }), let iMin = curve.indices.min(by: { curve[$0] < curve[$1] }) {
                for (i, peak) in [(iMax, true), (iMin, false)] where i >= 4 && i <= curve.count - 5 && turn == nil {
                    turn = (grid[i], curve[i], peak)
                }
            }
            return TrendFit(kind: .curve, points: zip(grid, curve).map { ($0, $1) }, slope: slope, gain: gain, turn: turn)
        }
        let trend = eLine <= eMean * (1 - curveGain)
        return TrendFit(kind: trend ? .line : .none, points: [(lo, line([lo])), (hi, line([hi]))], slope: slope,
                        gain: eMean > 0 ? max(0, 1 - eLine / eMean) : 0, turn: nil)
    }

    // MARK: fits

    /// Least squares polynomial of `degree` (x centred and scaled for stability); returns the fitted function.
    static func poly(_ xs: [Double], _ ys: [Double], degree: Int) -> (([Double]) -> Double)? {
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n
        let sx = max((xs.map { ($0 - mx) * ($0 - mx) }.reduce(0, +) / n).squareRoot(), 1e-12)
        let k = degree + 1
        var a = [[Double]](repeating: [Double](repeating: 0, count: k + 1), count: k)
        for (x, y) in zip(xs, ys) {
            let t = (x - mx) / sx
            let pw = (0..<k).map { pow(t, Double($0)) }
            for i in 0..<k {
                for j in 0..<k { a[i][j] += pw[i] * pw[j] }
                a[i][k] += pw[i] * y
            }
        }
        // Gaussian elimination with partial pivoting
        for c in 0..<k {
            guard let piv = (c..<k).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[piv][c]) > 1e-12 else { return nil }
            a.swapAt(c, piv)
            for r in 0..<k where r != c {
                let f = a[r][c] / a[c][c]
                for j in c...k { a[r][j] -= f * a[c][j] }
            }
        }
        let b = (0..<k).map { a[$0][k] / a[$0][$0] }
        return { v in
            let t = (v[0] - mx) / sx
            return (0..<k).reduce(0) { $0 + b[$1] * pow(t, Double($1)) }
        }
    }

    /// LOWESS at each of `at` (xs sorted): a tricube-weighted line through the nearest `span` share of the points,
    /// leaving out index `skip` (for leave-one-out).
    static func smooth(_ xs: [Double], _ ys: [Double], at: [Double], span: Double = 0.4, skip: Int? = nil) -> [Double] {
        let n = xs.count, q = max(4, Int((span * Double(n)).rounded(.up)))
        return at.map { x0 in
            // the q nearest by widening a window from where x0 falls (xs sorted)
            var r = xs.firstIndex { $0 >= x0 } ?? n
            var l = r - 1
            var idx: [Int] = []
            while idx.count < q && (l >= 0 || r < n) {
                if r >= n || (l >= 0 && x0 - xs[l] <= xs[r] - x0) { if l != skip { idx.append(l) }; l -= 1 }
                else { if r != skip { idx.append(r) }; r += 1 }
            }
            let h = max(idx.map { abs(xs[$0] - x0) }.max() ?? 0, 1e-12) * 1.0001
            var sw = 0.0, swx = 0.0, swy = 0.0, swxx = 0.0, swxy = 0.0
            for i in idx {
                let u = abs(xs[i] - x0) / h, w = pow(1 - u * u * u, 3)
                sw += w; swx += w * xs[i]; swy += w * ys[i]; swxx += w * xs[i] * xs[i]; swxy += w * xs[i] * ys[i]
            }
            guard sw > 0 else { return ys.reduce(0, +) / Double(n) }
            let d = sw * swxx - swx * swx
            if abs(d) < 1e-12 { return swy / sw }   // all at one x: their mean
            let b = (sw * swxy - swx * swy) / d
            return (swy - b * swx) / sw + b * x0
        }
    }

    // MARK: leave-one-out errors (root mean square)

    static func looMean(_ ys: [Double]) -> Double {
        let n = Double(ys.count), s = ys.reduce(0, +)
        return (ys.map { y in let m = (s - y) / (n - 1); return (y - m) * (y - m) }.reduce(0, +) / n).squareRoot()
    }

    static func loo(_ xs: [Double], _ ys: [Double], _ make: ([Double], [Double]) -> (([Double]) -> Double)?) -> Double {
        var sse = 0.0
        for i in xs.indices {
            var x = xs, y = ys
            x.remove(at: i); y.remove(at: i)
            guard let f = make(x, y) else { return .infinity }
            let e = ys[i] - f([xs[i]])
            sse += e * e
        }
        return (sse / Double(xs.count)).squareRoot()
    }

    static func looSmooth(_ xs: [Double], _ ys: [Double]) -> Double {
        var sse = 0.0
        for i in xs.indices {
            let e = ys[i] - smooth(xs, ys, at: [xs[i]], skip: i)[0]
            sse += e * e
        }
        return (sse / Double(xs.count)).squareRoot()
    }
}

/// The trend's caption under a chart.
struct TrendCaption: View {
    let fit: TrendFit
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(fit.kind == .none ? Theme.muted.opacity(0.5) : Theme.text.opacity(0.7))
                .frame(width: 14, height: 2)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }
}

extension TrendFit {
    /// The line's style on a chart: solid for a trend, dashed and faint for "no clear trend".
    var color: Color { kind == .none ? Theme.muted.opacity(0.5) : Theme.text.opacity(0.7) }
    var stroke: StrokeStyle { kind == .none ? StrokeStyle(lineWidth: 1.5, dash: [4, 4]) : StrokeStyle(lineWidth: 2) }

    /// "rising 0.3 h a week", "curved: best around 7.5 h (fits 12 % better than a line)", "no clear trend".
    /// `overTime`: x is days (a curve without a turn "faster lately"), else a lever ("steeper toward the high end").
    func caption(change: (Double) -> String, at: (Double) -> String, per: String, goalMin: Bool? = nil,
                 overTime: Bool = false) -> String {
        let pct = Int((gain * 100).rounded())
        switch kind {
        case .none:
            return "No clear trend: a line predicts no better than the average"
        case .line:
            return "Trend: \(slope >= 0 ? "rising" : "falling") \(change(abs(slope))) \(per) (predicts \(pct)% better than the average)"
        case .curve:
            var s = "Trend: curved"
            if let t = turn {
                let word = goalMin == nil ? (t.peak ? "highest" : "lowest")
                    : ((t.peak != (goalMin == true)) ? "best" : "worst")
                s += ", \(word) around \(at(t.x))"
            } else if let a = points.first?.y, let b = points.last?.y {
                s += b >= a ? ", rising" : ", falling"
                let m = points.count / 2
                let early = abs(points[m].y - a), late = abs(b - points[m].y)
                if max(early, late) > 0 { s += early > 2 * late ? " then levelling off" : late > 2 * early ? (overTime ? " faster lately" : " steeper toward the high end") : "" }
            }
            return s + " (predicts \(pct)% better than a straight line)"
        }
    }
}
