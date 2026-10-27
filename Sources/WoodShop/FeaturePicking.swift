import Foundation
import simd

enum FeaturePicking {
    static func onSurface(part: Part,polygon: Geo.Poly?,point: SIMD3<Double>) -> FeatureRef? {
        if let id = polygon?.source,let step = part.featureSteps.first(where: { $0.feature == id }) { return FeatureRef(part:part.id,kind:step.kind,feature:id) }
        for cut in part.cuts.reversed() where cut.suppressed != true {
            let inside = (0..<3).allSatisfy { point[$0] >= cut.lo[$0]-1e-5 && point[$0] <= cut.hi[$0]+1e-5 }
            let boundary = (0..<3).contains { abs(point[$0]-cut.lo[$0])<1e-5 || abs(point[$0]-cut.hi[$0])<1e-5 }
            if inside && boundary { return FeatureRef(part:part.id,kind:.cut,feature:cut.id) }
        }
        return nil
    }
    static func inLayout(point: SIMD2<Double>,placed: [Placed],setup: CNCSetup,threshold: Double) -> FeatureRef? {
        var hits: [(Double,FeatureRef)] = []
        for p in placed {
            let local = point-SIMD2(p.x,p.y)
            for feature in p.part.features+p.part.tenons {
                if setup == .top && feature.side != .top { continue }
                if setup == .bottom && feature.side != .bottom { continue }
                guard let ref = feature.reference else { continue }
                let a = feature.rect.lo,b = feature.rect.hi
                let polygon = feature.polygon ?? [a,SIMD2(b.x,a.y),b,SIMD2(a.x,b.y)]
                var distance = Double.infinity
                for i in polygon.indices {
                    let a = polygon[i],d = polygon[(i+1)%polygon.count]-a
                    let t = max(0,min(1,simd_dot(local-a,d)/max(simd_length_squared(d),1e-15)))
                    distance = min(distance,simd_length(local-a-d*t))
                }
                for island in feature.islands { for i in island.indices {
                    let a = island[i],d = island[(i+1)%island.count]-a
                    let t = max(0,min(1,simd_dot(local-a,d)/max(simd_length_squared(d),1e-15)))
                    distance = min(distance,simd_length(local-a-d*t))
                } }
                if (GeometryImport.contains(local,polygon:polygon) && !feature.islands.contains(where: { GeometryImport.contains(local,polygon:$0) })) || distance <= threshold { hits.append((abs(Planar.signedArea(polygon)),ref)) }
            }
        }
        return hits.min { $0.0 < $1.0 }?.1
    }
}
