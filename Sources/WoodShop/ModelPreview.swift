import AppKit
import simd

/// Software-rendered orthographic views, available without a Metal device or a window server.
struct ModelPreview {
    private var polygons: [UUID:[Geo.Poly]]
    init(parts: [Part]) { polygons = Dictionary(uniqueKeysWithValues:parts.map { ($0.id,Geo.polys(for:$0)) }) }
    func png(project: Project, view: SavedScene, width: Int = 1800, height: Int = 1100) throws -> Data {
        guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                                      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ModelValidation.Failure(message:"The model preview bitmap could not be created.")
        }
        let right = SIMD3(cos(view.yaw),0,-sin(view.yaw))
        let up = SIMD3(-sin(view.yaw)*sin(view.pitch),cos(view.pitch),-cos(view.yaw)*sin(view.pitch))
        let forward = SIMD3(sin(view.yaw)*cos(view.pitch),sin(view.pitch),cos(view.yaw)*cos(view.pitch))
        let light = simd_normalize(SIMD3<Double>(-0.4,0.8,0.6))
        struct Face { var points: [SIMD2<Double>]; var depths: [Double]; var color: CGColor }
        var faces: [Face] = []
        let visible = Set(view.visible)
        for part in project.parts where visible.contains(part.id) {
            let rgb = part.species.base.usingColorSpace(.deviceRGB) ?? .brown
            for polygon in polygons[part.id] ?? [] {
                let normal = part.dirToWorld(polygon.n)
                guard simd_dot(normal,forward) > 1e-7 else { continue }
                let world = polygon.pts.map(part.toWorld)
                let shade = 0.5+0.45*max(0,simd_dot(normal,light))
                let color = CGColor(red:rgb.redComponent*shade,green:rgb.greenComponent*shade,blue:rgb.blueComponent*shade,alpha:1)
                faces.append(Face(points:world.map { SIMD2(simd_dot($0,right),simd_dot($0,up)) },
                                  depths:world.map { simd_dot($0,forward) },color:color))
            }
        }
        guard let first = faces.first?.points.first else { throw ModelValidation.Failure(message:"This saved view contains no visible geometry.") }
        var lo = first,hi = first
        for face in faces { for point in face.points { lo = SIMD2(min(lo.x,point.x),min(lo.y,point.y)); hi = SIMD2(max(hi.x,point.x),max(hi.y,point.y)) } }
        let scale = min(Double(width-120)/(hi.x-lo.x),Double(height-200)/(hi.y-lo.y))
        let center = (lo+hi)/2,screenCenter = SIMD2(Double(width)/2,Double(height-80)/2)
        func map(_ point: SIMD2<Double>) -> CGPoint { let p = (point-center)*scale+screenCenter; return CGPoint(x:p.x,y:p.y) }
        context.setFillColor(CGColor(red:0.96,green:0.965,blue:0.97,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
        context.setShouldAntialias(true)
        guard let storage = context.data else { throw ModelValidation.Failure(message:"The preview pixel storage is unavailable.") }
        let pixels = storage.bindMemory(to:UInt8.self,capacity:width*height*4)
        var depth = [Double](repeating:-Double.infinity,count:width*height)
        func edge(_ a: SIMD2<Double>,_ b: SIMD2<Double>,_ p: SIMD2<Double>) -> Double { (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x) }
        for face in faces {
            let points = face.points.map { point -> SIMD2<Double> in let p = map(point); return SIMD2(Double(p.x),Double(p.y)) }
            let components = face.color.components!
            let color = components.prefix(3).map { UInt8(max(0,min(255,($0*255).rounded()))) }
            for i in 1..<(points.count-1) {
                let a = points[0],b = points[i],c = points[i+1],area = edge(a,b,c)
                guard abs(area)>1e-8 else { continue }
                let x0 = max(0,Int(floor(min(a.x,b.x,c.x)))),x1 = min(width-1,Int(ceil(max(a.x,b.x,c.x))))
                let y0 = max(0,Int(floor(min(a.y,b.y,c.y)))),y1 = min(height-1,Int(ceil(max(a.y,b.y,c.y))))
                guard x1>=x0,y1>=y0 else { continue }
                for y in y0...y1 { for x in x0...x1 {
                    let p = SIMD2(Double(x)+0.5,Double(y)+0.5)
                    let wa = edge(b,c,p)/area,wb = edge(c,a,p)/area,wc = 1-wa-wb
                    guard wa >= -1e-8,wb >= -1e-8,wc >= -1e-8 else { continue }
                    let z = wa*face.depths[0]+wb*face.depths[i]+wc*face.depths[i+1],index = y*width+x
                    guard z > depth[index]+1e-7 else { continue }
                    depth[index] = z
                    let pixel = ((height-1-y)*width+x)*4
                    pixels[pixel] = color[0]; pixels[pixel+1] = color[1]; pixels[pixel+2] = color[2]; pixels[pixel+3] = 255
                } }
            }
        }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
        (view.name as NSString).draw(at:CGPoint(x:48,y:height-60),withAttributes:[.font:NSFont.boldSystemFont(ofSize:28),.foregroundColor:NSColor.black])
        let values = try Parametric.values(project.studio?.parameters ?? [])
        func dimension(_ key: String) -> String { values[key].map { Units.format($0.value,metric:project.metric) } ?? "—" }
        let dimensions = "\(dimension("overall_width")) overall  |  \(dimension("tall_height")) cabinet height  |  \(dimension("worktop_height")) worktop  |  \(dimension("worktop_depth")) worktop depth"
        (dimensions as NSString).draw(at:CGPoint(x:48,y:height-91),withAttributes:[.font:NSFont.systemFont(ofSize:17),.foregroundColor:NSColor.darkGray])
        ("WoodShop · Parametric parts, joinery, and hardware references" as NSString).draw(at:CGPoint(x:48,y:24),withAttributes:[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.darkGray])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage(),let data = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {
            throw ModelValidation.Failure(message:"The model preview could not be encoded.")
        }
        return data
    }
}
