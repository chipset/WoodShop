import SwiftUI

struct FeatureThumbnail: View {
    let part: Part
    let step: FeatureStep
    var body: some View {
        Canvas { context,size in
            var axis = part.materialAxes.t,contours: [[SIMD2<Double>]] = []
            switch step.kind {
            case .cut:
                if let cut = part.cuts.first(where: { $0.id == step.feature }) { axis = cut.faceAxis ?? axis;contours = [cut.machiningContour(part:part)] }
            case .operation:
                if let op = part.operations?.first(where: { $0.id == step.feature }) { axis = op.axis;contours = [op.contour] }
            case .pattern:
                if var pattern = part.patterns?.first(where: { $0.id == step.feature }) {
                    axis = pattern.axis;pattern.suppressed = false;contours = ((try? pattern.generated(size:part.size)) ?? []).map(\.contour)
                }
            case .trim: break
            }
            let u = (axis+1)%3,v = (axis+2)%3
            let scale = min((size.width-6)/part.size[u],(size.height-6)/part.size[v])
            let origin = CGPoint(x:(size.width-part.size[u]*scale)/2,y:(size.height-part.size[v]*scale)/2)
            let rect = CGRect(origin:origin,size:CGSize(width:part.size[u]*scale,height:part.size[v]*scale))
            context.fill(Path(rect),with:.color(.brown.opacity(0.15)));context.stroke(Path(rect),with:.color(.secondary),lineWidth:0.7)
            for contour in contours {
                var path = Path();path.addLines(contour.map { CGPoint(x:origin.x+$0.x*scale,y:origin.y+(part.size[v]-$0.y)*scale) });path.closeSubpath()
                context.fill(path,with:.color(.accentColor.opacity(0.25)));context.stroke(path,with:.color(.accentColor),lineWidth:1)
            }
            if step.kind == .trim { var line = Path();line.move(to:rect.origin);line.addLine(to:CGPoint(x:rect.maxX,y:rect.maxY));context.stroke(line,with:.color(.accentColor),lineWidth:2) }
        }.accessibilityLabel(part.featureName(step)+" preview")
    }
}
