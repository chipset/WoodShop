import Foundation
import simd

enum JoineryTools {
    static func holes(part: Part, axis: Int, positive: Bool, centers: [SIMD2<Double>], diameter: Double, depth: Double,
                      counterDiameter: Double = 0, counterDepth: Double = 0, countersinkAngle: Double? = nil) throws -> [MachiningOperation] {
        guard (0..<3).contains(axis), diameter.isFinite, diameter > 0, (1...100).contains(centers.count),
              depth.isFinite, depth > 0 else { throw ModelValidation.Failure(message: "Choose a positive diameter/depth and up to 100 holes.") }
        var operations: [MachiningOperation] = []
        for (i, center) in centers.enumerated() {
            operations.append(MachiningOperation(name: "Hole \(i + 1)", axis: axis, positive: positive, depth: depth,
                contour: MeshTools.circle(center: center, radius: diameter / 2), kind: "Drill"))
            if counterDiameter > 0 {
                guard counterDiameter > diameter else { throw ModelValidation.Failure(message: "Counter diameter must exceed the hole diameter.") }
                let d: Double, scale: Double, kind: String
                if let angle = countersinkAngle {
                    guard angle.isFinite, (30...150).contains(angle) else { throw ModelValidation.Failure(message: "Countersink angle must be 30–150°.") }
                    d = (counterDiameter - diameter) / (2 * tan(angle * .pi / 360)); scale = diameter / counterDiameter; kind = "Countersink"
                } else { d = counterDepth; scale = 1; kind = "Counterbore" }
                operations.append(MachiningOperation(name: "\(kind) \(i + 1)", axis: axis, positive: positive, depth: d,
                    contour: MeshTools.circle(center: center, radius: counterDiameter / 2), bottomScale: scale, kind: kind))
            }
        }
        for op in operations { if let message = op.validation(size: part.size) { throw ModelValidation.Failure(message: message) } }
        return operations
    }
    static func fingers(part: Part, axis: Int, positive: Bool, count: Int, depth: Double, clearance: Double,
                        complementary: Bool, dovetailAngle: Double = 0) throws -> [MachiningOperation] {
        guard (0..<3).contains(axis), (1...24).contains(count), clearance.isFinite, clearance >= 0,
              dovetailAngle.isFinite, (0...20).contains(dovetailAngle), depth.isFinite, depth > 0 else {
            throw ModelValidation.Failure(message: "Use 1–24 fingers, nonnegative clearance, and a 0–20° dovetail angle.")
        }
        let u = (axis + 1) % 3, v = (axis + 2) % 3, cells = count * 2 + 1
        let width = part.size[u] / Double(cells), spread = depth * tan(dovetailAngle * .pi / 180)
        guard clearance + 2 * spread < width else { throw ModelValidation.Failure(message: "The clearance or dovetail angle consumes the finger width.") }
        var result: [MachiningOperation] = []
        for i in 0..<cells where i % 2 == (complementary ? 0 : 1) {
            let lo = max(0, Double(i) * width - clearance / 2), hi = min(part.size[u], Double(i + 1) * width + clearance / 2)
            let bottomWidth = hi - lo + (complementary ? -2 : 2) * spread
            let op = MachiningOperation(name: dovetailAngle > 0 ? "Dovetail socket" : "Finger socket", axis: axis, positive: positive,
                depth: depth, contour: [SIMD2(lo, 0), SIMD2(hi, 0), SIMD2(hi, part.size[v]), SIMD2(lo, part.size[v])],
                kind: dovetailAngle > 0 ? "Dovetail" : "Finger", bottomStretch: SIMD2(bottomWidth / (hi - lo), 1))
            if let error = op.validation(size: part.size) { throw ModelValidation.Failure(message: error) }
            result.append(op)
        }
        return result
    }
}
