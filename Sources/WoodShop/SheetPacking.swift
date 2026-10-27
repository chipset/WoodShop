import Foundation
import simd

private struct PackRect {
    var x: Double;var y: Double;var w: Double;var h: Double
    func contains(_ b: PackRect) -> Bool { b.x>=x-1e-8 && b.y>=y-1e-8 && b.x+b.w<=x+w+1e-8 && b.y+b.h<=y+h+1e-8 }
    func overlaps(_ b: PackRect) -> Bool { x<b.x+b.w-1e-8 && x+w>b.x+1e-8 && y<b.y+b.h-1e-8 && y+h>b.y+1e-8 }
}
private struct PackSheet { var stock: SheetStock;var group: String;var localIndex: Int;var free: [PackRect] }
private struct PackChoice {
    var parts: [FlatPart]
    var offsets: [SIMD2<Double>]
    var width: Double
    var height: Double
}
private struct PackUnit {
    var name: String
    var species: Species
    var thickness: Double
    var grainMatch: Bool
    var choices: [PackChoice]

    static func make(_ parts: [FlatPart],gap: Double) -> (units:[PackUnit],errors:[String]) {
        var groups: [String:[(Int,FlatPart)]] = [:]
        for (index,part) in parts.enumerated() {
            let key = (part.grainMatchGroup ?? "").trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
            if !key.isEmpty { groups[key,default:[]].append((index,part)) }
        }
        var emitted: Set<String> = [],units: [PackUnit] = [],errors: [String] = []
        for part in parts {
            let key = (part.grainMatchGroup ?? "").trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
            if key.isEmpty {
                let choices = (part.allowRotation ? [part,part.rotated()] : [part]).map { flat -> PackChoice in
                    let b = flat.footprint
                    return PackChoice(parts:[flat],offsets:[.zero],width:b.hi.x-b.lo.x,height:b.hi.y-b.lo.y)
                }
                units.append(PackUnit(name:part.name,species:part.species,thickness:part.requiredThickness,grainMatch:false,choices:choices))
                continue
            }
            guard emitted.insert(key).inserted else { continue }
            let members = (groups[key] ?? []).sorted { left,right in
                let a = left.1.grainMatchOrder ?? Int.max,b = right.1.grainMatchOrder ?? Int.max
                return a == b ? left.0 < right.0 : a < b
            }.map(\.1)
            guard !members.isEmpty else { continue }
            let label = "Grain match ‘"+(part.grainMatchGroup ?? key)+"’ (\(members.count) parts)"
            guard members.allSatisfy({ $0.species == part.species && abs($0.requiredThickness-part.requiredThickness)<1e-6 && $0.rotationDegrees % 180 == 0 && $0.flippedFace == part.flippedFace }) else {
                errors.append(label+" needs one material, thickness, face orientation, and grain direction.");continue
            }
            let orders = members.compactMap(\.grainMatchOrder)
            guard Set(orders).count == orders.count else { errors.append(label+" has duplicate order numbers.");continue }
            var offsets: [SIMD2<Double>] = [],cross = 0.0,length = 0.0
            for member in members {
                let b = member.footprint
                offsets.append(SIMD2(0,cross));cross += b.hi.y-b.lo.y+gap
                length = max(length,b.hi.x-b.lo.x)
            }
            let choice = PackChoice(parts:members,offsets:offsets,width:length,height:cross-gap)
            units.append(PackUnit(name:label,species:part.species,thickness:part.requiredThickness,grainMatch:true,choices:[choice]))
        }
        return (units,errors)
    }
}

enum SheetPacker {
    static func nest(_ parts: [FlatPart],sheetL: Double,sheetW: Double,gap: Double,registration: Registration?,stocks: [SheetStock],areaFirst: Bool) -> Nesting.Result {
        let strip = registration?.enabled == true ? registration!.inset+registration!.diameter/2+gap : 0,startX = gap+strip
        var sheets: [PackSheet] = [],placed: [Placed] = [],remaining = stocks.filter { $0.enabled && $0.length<=sheetL && $0.width<=sheetW && (try? $0.validate()) != nil }
        var groupCounts: [String:Int] = [:]
        let built = PackUnit.make(parts,gap:gap)
        var oversize = built.errors
        let sorted = built.units.enumerated().sorted { lhs,rhs in
            let a = lhs.element,b = rhs.element
            if a.grainMatch != b.grainMatch { return a.grainMatch }
            let ac = a.choices[0],bc = b.choices[0]
            let av = areaFirst ? ac.width*ac.height : max(ac.width,ac.height)
            let bv = areaFirst ? bc.width*bc.height : max(bc.width,bc.height)
            return av == bv ? lhs.offset<rhs.offset : av>bv
        }.map(\.element)
        func split(_ free: [PackRect],used: PackRect) -> [PackRect] {
            var result: [PackRect] = []
            for f in free {
                guard f.overlaps(used) else { result.append(f);continue }
                if used.x>f.x { result.append(PackRect(x:f.x,y:f.y,w:used.x-f.x,h:f.h)) }
                if used.x+used.w<f.x+f.w { result.append(PackRect(x:used.x+used.w,y:f.y,w:f.x+f.w-used.x-used.w,h:f.h)) }
                if used.y>f.y { result.append(PackRect(x:f.x,y:f.y,w:f.w,h:used.y-f.y)) }
                if used.y+used.h<f.y+f.h { result.append(PackRect(x:f.x,y:used.y+used.h,w:f.w,h:f.y+f.h-used.y-used.h)) }
            }
            result = result.filter { $0.w>1e-8 && $0.h>1e-8 }
            return result.enumerated().filter { i,r in !result.enumerated().contains { j,s in j != i && s.contains(r) && (!r.contains(s) || j<i) } }.map(\.element)
        }
        for unit in sorted {
            let group = "\(unit.species.rawValue) \(unit.thickness)in"
            var best: (sheet:Int,choice:PackChoice,rect:PackRect,short:Double,long:Double)?
            for index in sheets.indices where sheets[index].group == group {
                for choice in unit.choices {
                    let w = choice.width+gap,h = choice.height+gap
                    for f in sheets[index].free where w<=f.w+1e-8 && h<=f.h+1e-8 {
                        let short = min(f.w-w,f.h-h),long = max(f.w-w,f.h-h)
                        if best == nil || (short,long,index,f.y,f.x)<(best!.short,best!.long,best!.sheet,best!.rect.y,best!.rect.x) { best = (index,choice,PackRect(x:f.x,y:f.y,w:w,h:h),short,long) }
                    }
                }
            }
            if best == nil {
                func fits(_ stock: SheetStock) -> Bool { unit.choices.contains { $0.width+2*gap+strip<=stock.length+1e-8 && $0.height+2*gap<=stock.width+1e-8 } }
                let candidates = remaining.indices.filter { remaining[$0].species == unit.species && abs(remaining[$0].thickness-unit.thickness)<1e-6 && fits(remaining[$0]) }
                let selected = candidates.min { remaining[$0].length*remaining[$0].width<remaining[$1].length*remaining[$1].width }
                var stock: SheetStock
                if let selected { stock = remaining.remove(at:selected) }
                else {
                    stock = SheetStock(id:DrillingPattern.stableID(UUID(uuidString:"99999999-9999-4999-8999-999999999999")!,group+String(groupCounts[group,default:0])),name:"Full sheet",species:unit.species,thickness:unit.thickness,length:sheetL,width:sheetW)
                    guard fits(stock) else { oversize.append(unit.grainMatch ? unit.name+" does not fit one sheet with the current gap and registration margin." : unit.name);continue }
                }
                let number = groupCounts[group,default:0];groupCounts[group] = number+1
                sheets.append(PackSheet(stock:stock,group:group,localIndex:number,free:[PackRect(x:startX,y:gap,w:stock.length-startX,h:stock.width-gap)]))
                let index = sheets.count-1
                for choice in unit.choices {
                    let w = choice.width+gap,h = choice.height+gap,f = sheets[index].free[0]
                    guard w<=f.w+1e-8,h<=f.h+1e-8 else { continue }
                    let short = min(f.w-w,f.h-h),long = max(f.w-w,f.h-h)
                    if best == nil || (short,long)<(best!.short,best!.long) { best = (index,choice,PackRect(x:f.x,y:f.y,w:w,h:h),short,long) }
                }
            }
            guard let chosen = best else { oversize.append(unit.name);continue }
            let sheetOffset = Double(chosen.sheet)*(sheetL+24)
            for (index,part) in chosen.choice.parts.enumerated() {
                let b = part.footprint,relative = chosen.choice.offsets[index]
                placed.append(Placed(part:part,x:sheetOffset+chosen.rect.x+relative.x-b.lo.x,y:chosen.rect.y+relative.y-b.lo.y,sheet:chosen.sheet,group:group))
            }
            sheets[chosen.sheet].free = split(sheets[chosen.sheet].free,used:chosen.rect)
        }
        var result = Nesting.Result(placed:placed,sheets:sheets.enumerated().map { ($0.element.group,$0.element.localIndex,Double($0.offset)*(sheetL+24)) },sheetL:sheetL,sheetW:sheetW,oversize:oversize)
        result.stockRecords = Dictionary(uniqueKeysWithValues:sheets.enumerated().map { ($0.offset,$0.element.stock) });return result
    }
}
extension Nesting.Result {
    func stock(at index: Int) -> SheetStock? {
        if let stock = stockRecords?[index] { return stock }
        guard let part = placed.first(where: { $0.sheet == index })?.part else { return nil }
        return SheetStock(name:"Full sheet",species:part.species,thickness:part.requiredThickness,length:sheetL,width:sheetW)
    }
    var utilization: Double {
        let stockArea = sheets.indices.reduce(0.0) { $0+(stock(at:$1).map { $0.length*$0.width } ?? 0) }
        return stockArea>0 ? placed.reduce(0) { $0+$1.part.cutOutlines.reduce(0) { $0+abs(Planar.signedArea($1)) } }/stockArea : 0
    }
}
extension StudioState {
    var nestingStocks: [SheetStock] { useOffcuts == true ? offcuts ?? [] : [] }
}
