import Foundation

/// A complete, editable 12-foot workshop wall. Coordinates: X along the wall, Y up, Z toward the user.
enum GarageCabinets {
    static let parameters = [
        DesignParameter(name:"module_width",expression:"30in"),
        DesignParameter(name:"tall_width",expression:"24in"),
        DesignParameter(name:"cabinet_depth",expression:"24in"),
        DesignParameter(name:"base_height",expression:"34.5in"),
        DesignParameter(name:"toe_height",expression:"4in"),
        DesignParameter(name:"toe_setback",expression:"3in"),
        DesignParameter(name:"tall_height",expression:"84in"),
        DesignParameter(name:"wall_bottom",expression:"54in"),
        DesignParameter(name:"wall_height",expression:"30in"),
        DesignParameter(name:"wall_depth",expression:"12in"),
        DesignParameter(name:"thickness",expression:"0.75in"),
        DesignParameter(name:"back_thickness",expression:"0.25in"),
        DesignParameter(name:"door_thickness",expression:"0.75in"),
        DesignParameter(name:"drawer_side",expression:"0.5in"),
        DesignParameter(name:"drawer_bottom",expression:"0.25in"),
        DesignParameter(name:"drawer_groove",expression:"0.125in"),
        DesignParameter(name:"drawer_bottom_offset",expression:"0.375in"),
        DesignParameter(name:"slide_clearance",expression:"1in"),
        DesignParameter(name:"drawer_depth",expression:"cabinet_depth - 2in"),
        DesignParameter(name:"drawer_front_height",expression:"(base_height - toe_height - 5 * reveal) / 4"),
        DesignParameter(name:"drawer_box_height",expression:"drawer_front_height - 1.75in"),
        DesignParameter(name:"reveal",expression:"0.125in"),
        DesignParameter(name:"front_gap",expression:"0.125in"),
        DesignParameter(name:"dado_depth",expression:"0.25in"),
        DesignParameter(name:"fit_clearance",expression:"0.005in"),
        DesignParameter(name:"shelf_clearance",expression:"0.0625in"),
        DesignParameter(name:"shelf_pitch",expression:"32mm"),
        DesignParameter(name:"pin_diameter",expression:"5mm"),
        DesignParameter(name:"pin_depth",expression:"0.375in"),
        DesignParameter(name:"pin_setback",expression:"2in"),
        DesignParameter(name:"pin_start",expression:"4in"),
        DesignParameter(name:"handle_spacing",expression:"128mm"),
        DesignParameter(name:"worktop_thickness",expression:"1.5in"),
        DesignParameter(name:"worktop_depth",expression:"25.5in"),
        DesignParameter(name:"overall_width",expression:"tall_width + 4 * module_width"),
        DesignParameter(name:"worktop_height",expression:"base_height + worktop_thickness")
    ]

    static func project(parameters definitions: [DesignParameter] = parameters) throws -> Project {
        let values = try Parametric.values(definitions)
        var parts: [Part] = [],joints: [MatingJoint] = [],fronts: Set<UUID> = [],drawerBoxes: Set<UUID> = []
        let mill = CuttingTool(name:"1/4 inch straight end mill",diameter:0.25,fluteLength:2)
        let drill = CuttingTool(name:"5 mm drill — pins and pull holes",kind:.drill,diameter:5/25.4,fluteLength:1)
        func length(_ expression: String) throws -> Double { try Parametric.evaluate(DesignBinding(target:.size,expression:expression),values:values) }
        @discardableResult func panel(_ name: String,_ group: String,_ origin: [String],_ size: [String],_ thickness: Int,_ grain: Int,
                                     species: Species = .plywood,hardware: Bool = false) throws -> UUID {
            var part = Part(name:name,origin:.zero,size:SIMD3(repeating:1),species:species)
            part.group = "Garage/"+group; part.thicknessAxis = thickness; part.grainDirection = grain
            part.hardware = hardware ? true : nil; part.cncTopPositive = true
            part.bindings = (0..<3).flatMap { axis in [DesignBinding(target:.size,axis:axis,expression:size[axis]),DesignBinding(target:.position,axis:axis,expression:origin[axis])] }
            try Parametric.apply(to:&part,values:values)
            parts.append(part); return part.id
        }
        func join(_ donor: UUID,_ receiver: UUID,_ axis: Int,_ positive: Bool,_ name: String,_ depth: String = "dado_depth") throws {
            joints.append(MatingJoint(name:name,shelf:donor,receiver:receiver,axis:axis,positive:positive,
                depth:try length(depth),clearance:try length("fit_clearance"),autoSeat:false,number:joints.count+1))
        }
        func pinRows(_ id: UUID,_ positive: Bool,_ start: String,_ count: Int) throws {
            let i = parts.firstIndex { $0.id == id }!
            var pattern = DrillingPattern(); pattern.name = "Adjustable shelf pins · "+start
            pattern.axis = 0; pattern.positive = positive; pattern.placement = .margins
            pattern.columns = count; pattern.rows = 2; pattern.spanV = true
            pattern.expressions = [PatternExpression(field:.marginU,expression:start),PatternExpression(field:.marginV,expression:"pin_setback"),
                PatternExpression(field:.pitchU,expression:"shelf_pitch"),PatternExpression(field:.diameter,expression:"pin_diameter"),PatternExpression(field:.depth,expression:"pin_depth")]
            try pattern.evaluate(values); parts[i].patterns = (parts[i].patterns ?? [])+[pattern]
            parts[i].toolAssignments = (parts[i].toolAssignments ?? [:]).merging([pattern.id.uuidString:drill.id]) { _,new in new }
            parts[i].cncTopPositive = positive
        }
        func supportPins(_ group: String,_ x: String,_ width: String,_ sideY: String,_ depth: String,_ shelfY: String) throws {
            for right in [false,true] { for rear in [true,false] {
                let px = right ? "\(x)+\(width)-thickness-0.25in" : "\(x)+thickness-0.25in"
                let pz = rear ? "back_thickness+pin_setback-pin_diameter/2" : "\(depth)-pin_setback-pin_diameter/2"
                let id = try panel("Shelf support pin",group,[px,"\(shelfY)-pin_diameter",pz],["0.5in","pin_diameter","pin_diameter"],0,1,species:.walnut,hardware:true)
                let i = parts.firstIndex { $0.id == id }!; parts[i].profile = .preset(.oval,part:parts[i])
            } }
        }
        @discardableResult func shelf(_ name: String,_ group: String,_ x: String,_ width: String,_ y: String,_ sideY: String,_ depth: String) throws -> UUID {
            let id = try panel(name,group,["\(x)+thickness+shelf_clearance",y,"back_thickness+0.5in"],
                ["\(width)-2*thickness-2*shelf_clearance","thickness","\(depth)-back_thickness-1.25in"],1,0)
            try supportPins(group,x,width,sideY,depth,y); return id
        }
        func pull(_ group: String,_ x: String,_ y: String,_ z: String,_ vertical: Bool) throws {
            try panel("128 mm pull bar (reference)",group,[vertical ? "\(x)-0.1875in" : "\(x)-handle_spacing/2-0.1875in",vertical ? "\(y)-handle_spacing/2-0.1875in" : "\(y)-0.1875in","\(z)+0.75in"],
                [vertical ? "0.375in" : "handle_spacing+0.375in",vertical ? "handle_spacing+0.375in" : "0.375in","0.375in"],2,vertical ? 1 : 0,species:.walnut,hardware:true)
            for sign in ["-","+"] {
                try panel("Pull stand-off (reference)",group,[vertical ? "\(x)-0.125in" : "\(x)\(sign)handle_spacing/2-0.125in",vertical ? "\(y)\(sign)handle_spacing/2-0.125in" : "\(y)-0.125in",z],
                    ["0.25in","0.25in","0.75in"],0,2,species:.walnut,hardware:true)
            }
        }
        func pullHoles(_ id: UUID,_ vertical: Bool,_ centerX: String,_ centerY: String) throws {
            let i = parts.firstIndex { $0.id == id }!
            var pattern = DrillingPattern(); pattern.name = "128 mm pull fixing holes · verify selected hardware"
            pattern.axis = 2; pattern.placement = .margins; pattern.columns = vertical ? 1 : 2; pattern.rows = vertical ? 2 : 1
            pattern.expressions = [PatternExpression(field:.marginU,expression:centerX+(vertical ? "" : "-handle_spacing/2")),
                PatternExpression(field:.marginV,expression:centerY+(vertical ? "-handle_spacing/2" : "")),
                PatternExpression(field:.pitchU,expression:"handle_spacing"),PatternExpression(field:.pitchV,expression:"handle_spacing"),PatternExpression(field:.diameter,expression:"pin_diameter")]
            try pattern.evaluate(values); pattern.through = true
            pattern.diameter = try length("pin_diameter"); parts[i].patterns = [pattern]; parts[i].toolAssignments = [pattern.id.uuidString:drill.id]
        }
        func doors(_ group: String,_ x: String,_ width: String,_ bottom: String,_ height: String,_ depth: String,_ hinges: Int) throws {
            let leaf = "(\(width)-3*reveal)/2",h = "(\(height)-2*reveal)"
            for right in [false,true] {
                let px = right ? "\(x)+(\(width)+reveal)/2" : "\(x)+reveal"
                let handleLocalX = right ? "1.5in" : "\(leaf)-1.5in"
                let py = "\(bottom)+reveal",pz = "\(depth)+front_gap"
                let id = try panel(right ? "Right slab door" : "Left slab door",group,[px,py,pz],[leaf,h,"door_thickness"],2,1,species:.mdf)
                fronts.insert(id); try pullHoles(id,true,handleLocalX,"\(h)/2")
                try pull(group,"\(px)+\(handleLocalX)","\(py)+\(h)/2","\(pz)+door_thickness",true)
                for j in 0..<hinges {
                    let hingeY = j == 0 ? "\(py)+3in" : (j == hinges-1 ? "\(py)+\(h)-3in" : "\(py)+\(h)/2")
                    let hx = right ? "\(x)+\(width)-thickness-0.5in" : "\(x)+thickness-0.75in"
                    try panel("Concealed hinge (reference; mounting holes per selected hinge)",group,[hx,hingeY,"\(depth)-1in"],["1.25in","2in","1in"],0,1,species:.walnut,hardware:true)
                }
            }
        }
        func carcass(_ group: String,_ x: String,_ width: String,_ bottom: String,_ top: String,_ depth: String,_ plinth: Bool) throws -> (UUID,UUID) {
            let left = try panel("Left carcass side",group,[x,bottom,"back_thickness"],["thickness","\(top)-(\(bottom))","\(depth)-back_thickness"],0,1)
            let right = try panel("Right carcass side",group,["\(x)+\(width)-thickness",bottom,"back_thickness"],["thickness","\(top)-(\(bottom))","\(depth)-back_thickness"],0,1)
            for upper in [false,true] {
                let y = upper ? "\(top)-thickness" : bottom
                let id = try panel(upper ? "Fixed carcass top" : "Fixed carcass bottom",group,["\(x)+thickness-dado_depth",y,"back_thickness"],
                    ["\(width)-2*thickness+2*dado_depth","thickness","\(depth)-back_thickness"],1,0)
                try join(id,left,0,true,"Top/bottom housing"); try join(id,right,0,false,"Top/bottom housing")
            }
            try panel("Applied plywood back",group,[x,bottom,"0in"],[width,"\(top)-(\(bottom))","back_thickness"],2,1)
            if plinth {
                for r in [false,true] {
                    try panel("Plinth side bearer",group,[r ? "\(x)+\(width)-thickness" : x,"0in","back_thickness"],
                        ["thickness","toe_height","\(depth)-toe_setback-back_thickness"],0,2)
                }
                for front in [false,true] {
                    try panel(front ? "Recessed toe kick" : "Plinth rear rail",group,["\(x)+thickness","0in",front ? "\(depth)-toe_setback-thickness" : "back_thickness"],
                        ["\(width)-2*thickness","toe_height","thickness"],2,0)
                }
            } else {
                for upper in [false,true] {
                    try panel("Wall fixing cleat — fasteners to suit wall",group,["\(x)+thickness",upper ? "\(top)-thickness-3in" : "\(bottom)+thickness","back_thickness"],
                        ["\(width)-2*thickness","3in","thickness"],2,0,species:.maple)
                }
            }
            return (left,right)
        }

        // Tall storage cabinet: fixed center partition, four adjustable shelves, four doors.
        let tall = "01 Tall storage"
        let tallSides = try carcass(tall,"0in","tall_width","toe_height","tall_height","cabinet_depth",true)
        let middle = "(tall_height+toe_height)/2"
        let divider = try panel("Fixed center shelf",tall,["thickness-dado_depth",middle,"back_thickness"],
            ["tall_width-2*thickness+2*dado_depth","thickness","cabinet_depth-back_thickness"],1,0)
        try join(divider,tallSides.0,0,true,"Tall center shelf dado"); try join(divider,tallSides.1,0,false,"Tall center shelf dado")
        for (side,positive) in [(tallSides.0,true),(tallSides.1,false)] {
            try pinRows(side,positive,"pin_start",25)
            try pinRows(side,positive,"(tall_height-toe_height)/2+pin_start",25)
        }
        for upper in [false,true] { for row in [6,16] {
            let y = upper ? "toe_height+(tall_height-toe_height)/2+pin_start+\(row)*shelf_pitch+pin_diameter/2" : "toe_height+pin_start+\(row)*shelf_pitch+pin_diameter/2"
            try shelf("Adjustable tall shelf",tall,"0in","tall_width",y,"toe_height","cabinet_depth")
        } }
        try doors(tall,"0in","tall_width","toe_height","(tall_height-toe_height)/2","cabinet_depth",3)
        try doors(tall,"0in","tall_width",middle,"(tall_height-toe_height)/2","cabinet_depth",3)

        for bay in 0..<4 {
            let x = "tall_width+\(bay)*module_width",group = String(format:"02 Base %d — ",bay+1)+(bay<2 ? "four drawers" : (bay == 2 ? "double door" : "open shelves"))
            let sides = try carcass(group,x,"module_width","toe_height","base_height","cabinet_depth",true)
            if bay < 2 {
                for n in 0..<4 {
                    let drawerGroup = group+"/Drawer \(n+1)",y = "toe_height+reveal+\(n)*(drawer_front_height+reveal)",boxY = "\(y)+0.875in"
                    let dx = "\(x)+thickness+slide_clearance/2",dw = "module_width-2*thickness-slide_clearance",rear = "1in"
                    let left = try panel("Left drawer box side",drawerGroup,[dx,boxY,rear],["drawer_side","drawer_box_height","drawer_depth"],0,2)
                    let right = try panel("Right drawer box side",drawerGroup,["\(dx)+\(dw)-drawer_side",boxY,rear],["drawer_side","drawer_box_height","drawer_depth"],0,2)
                    let back = try panel("Drawer box back",drawerGroup,["\(dx)+drawer_side",boxY,rear],["\(dw)-2*drawer_side","drawer_box_height","drawer_side"],2,0)
                    let front = try panel("Drawer box front",drawerGroup,["\(dx)+drawer_side",boxY,"\(rear)+drawer_depth-drawer_side"],["\(dw)-2*drawer_side","drawer_box_height","drawer_side"],2,0)
                    let bottom = try panel("Captured drawer bottom",drawerGroup,["\(dx)+drawer_side-drawer_groove","\(boxY)+drawer_bottom_offset","\(rear)+drawer_side-drawer_groove"],
                        ["\(dw)-2*drawer_side+2*drawer_groove","drawer_bottom","drawer_depth-2*drawer_side+2*drawer_groove"],1,0)
                    drawerBoxes.formUnion([left,right,front,back,bottom])
                    try join(bottom,left,0,true,"Drawer bottom groove","drawer_groove"); try join(bottom,right,0,false,"Drawer bottom groove","drawer_groove")
                    try join(bottom,back,2,true,"Drawer bottom groove","drawer_groove"); try join(bottom,front,2,false,"Drawer bottom groove","drawer_groove")
                    let face = try panel("Drawer \(n+1) applied front",drawerGroup,["\(x)+reveal",y,"cabinet_depth+front_gap"],["module_width-2*reveal","drawer_front_height","door_thickness"],2,0,species:.mdf)
                    fronts.insert(face); try pullHoles(face,false,"(module_width-2*reveal)/2","drawer_front_height/2")
                    try pull(drawerGroup,"\(x)+module_width/2","\(y)+drawer_front_height/2","cabinet_depth+front_gap+door_thickness",false)
                    for r in [false,true] {
                        let sx = r ? "\(x)+module_width-thickness-slide_clearance/2" : "\(x)+thickness"
                        try panel("22 inch side-mount slide (reference)",drawerGroup,[sx,"\(boxY)+0.5in",rear],["slide_clearance/2","1.75in","drawer_depth"],0,2,species:.walnut,hardware:true)
                    }
                }
            } else {
                try pinRows(sides.0,true,"pin_start",17); try pinRows(sides.1,false,"pin_start",17)
                for row in [5,13] { try shelf("Adjustable base shelf",group,x,"module_width","toe_height+pin_start+\(row)*shelf_pitch+pin_diameter/2","toe_height","cabinet_depth") }
                if bay == 2 { try doors(group,x,"module_width","toe_height","base_height-toe_height","cabinet_depth",2) }
            }
        }
        for bay in 0..<4 {
            let x = "tall_width+\(bay)*module_width",top = "wall_bottom+wall_height",group = String(format:"03 Wall %d — ",bay+1)+(bay<3 ? "double door" : "open shelves")
            let sides = try carcass(group,x,"module_width","wall_bottom",top,"wall_depth",false)
            if bay < 3 {
                try pinRows(sides.0,true,"pin_start",18); try pinRows(sides.1,false,"pin_start",18)
                for row in [5,13] { try shelf("Adjustable wall shelf",group,x,"module_width","wall_bottom+pin_start+\(row)*shelf_pitch+pin_diameter/2","wall_bottom","wall_depth") }
                try doors(group,x,"module_width","wall_bottom","wall_height","wall_depth",2)
            } else {
                let id = try panel("Fixed open wall center shelf",group,["\(x)+thickness-dado_depth","wall_bottom+(wall_height-thickness)/2","back_thickness"],
                    ["module_width-2*thickness+2*dado_depth","thickness","wall_depth-back_thickness"],1,0)
                try join(id,sides.0,0,true,"Open wall shelf dado"); try join(id,sides.1,0,false,"Open wall shelf dado")
            }
        }
        for half in 0..<2 {
            let x = "tall_width+\(half)*2*module_width"
            try panel("Worktop section \(half+1)","04 Worktop",[x,"base_height","0in"],["2*module_width","worktop_thickness","worktop_depth"],1,0,species:.maple)
            try panel("Backsplash section \(half+1)","04 Worktop",[x,"worktop_height","0in"],["2*module_width","4in","thickness"],2,0,species:.maple)
        }
        var project = Project(parts:parts); project.stockName = "Plywood 3/4 (4x8)"; project.stockLength = 96
        var studio = StudioState(); studio.parameters = definitions; studio.matingJoints = joints
        studio.setupProfile = CNCSetupProfile(name:"Garage cabinets — plywood and 5 mm drilling",tools:[mill,drill],activeTool:mill.id,
            vcarveTemplate:"Garage cabinet pockets, 5 mm drilling, outside profiles",notes:"Stock-specific thicknesses are listed per sheet group. 1/2 inch drawer sides, 1/4 inch backs/bottoms, 3/4 inch carcasses/fronts, and 1-1/2 inch worktop blanks. Hinge and slide mounting geometry is reference-only; drill from your selected hardware template. Cut worktop stock from suitable 60-inch blanks; its join is above the center base-cabinet boundary.")
        studio.assemblySteps = [
            AssemblyStep(text:"Layout: 144 inches wide × 84 inches high. Base work surface 36 inches high; 18 inches to the upper cabinets. Confirm room clearance and measured stock before resizing parameters."),
            AssemblyStep(text:"Sort the labeled parts by cabinet group and stock thickness. Machine the inner-face dados and shelf-pin rows before outside profiles. Positive and negative side faces are identified in each part's CNC setup."),
            AssemblyStep(text:"Assemble each recessed plinth from its two side bearers, rear rail, and toe kick. Level the plinths, then fit the carcass sides, housed bottoms/tops, and applied backs."),
            AssemblyStep(text:"Dry-fit the tall cabinet's center shelf and the open wall unit's center shelf into their linked dados. Join the four base modules beside the tall cabinet and bring the front edges into one plane."),
            AssemblyStep(text:"Build eight drawer boxes with 1/2 inch sides/fronts/backs and captured 1/4 inch bottoms. The 1/8 inch bottom grooves are modeled on all four sides. Assemble the box corners using your chosen screws or dowels."),
            AssemblyStep(text:"Install eight pairs of reference 22-inch side-mount slides in the modeled 1-inch total allowance. Set the four applied fronts per bank with 1/8 inch reveals; verify the selected slide's installation dimensions."),
            AssemblyStep(text:"Install the two 60-inch worktop sections; their joint sits over the center base-cabinet boundary. Fit the backsplash. Use a suitable worktop connection and allow for solid-wood movement."),
            AssemblyStep(text:"Fix the upper cabinet cleats and tall cabinet restraint to suitable wall structure using anchors appropriate for the wall and intended loads. Upper backs and two fixing cleats per unit are modeled."),
            AssemblyStep(text:"Place the fourteen adjustable shelves on their four 5 mm support pins. Their initial shelf heights coincide with the modeled 32 mm pitch pin rows."),
            AssemblyStep(text:"Fit twelve slab doors and eight applied drawer fronts. Pull holes are modeled at 128 mm centers; hinges, slides, and pulls are references. Confirm the actual hardware before using its drilling template."),
            AssemblyStep(text:"Inspect door and drawer travel, clearance at the tall cabinet, squareness, edge finishing, and wall attachment. The saved Interior and Drawer boxes views expose the construction for review.")
        ]
        let width = try length("overall_width"),height = try length("tall_height")
        studio.dimensions = [ModelDimension(a:.zero,b:SIMD3(width,0,0),name:"Overall width"),ModelDimension(a:.zero,b:SIMD3(0,height,0),name:"Overall height"),
            ModelDimension(a:SIMD3(width,0,0),b:SIMD3(width,try length("worktop_height"),0),name:"Worktop height"),ModelDimension(a:SIMD3(width,0,0),b:SIMD3(width,0,try length("worktop_depth")),name:"Worktop depth")]
        let target = SIMD3(width/2,height/2,10.0),distance = max(width,height)*1.45
        studio.scenes = [SavedScene(name:"Garage — complete",target:target,distance:distance,yaw:0.35,pitch:0.22,ortho:true,visible:parts.map(\.id),section:nil),
            SavedScene(name:"Garage — interior",target:target,distance:distance,yaw:0.35,pitch:0.22,ortho:true,visible:parts.filter { !fronts.contains($0.id) && $0.hardware != true }.map(\.id),section:nil),
            SavedScene(name:"Garage — front elevation",target:target,distance:distance,yaw:0,pitch:0,ortho:true,visible:parts.map(\.id),section:nil),
            SavedScene(name:"Garage — drawer boxes",target:SIMD3(try length("tall_width+module_width"),18,12),distance:105,yaw:0.45,pitch:0.4,ortho:true,visible:Array(drawerBoxes),section:nil)]
        project.studio = studio
        try Regeneration.rebuild(parts:&project.parts,links:[],studio:studio)
        project = ShopIdentity.numbered(project)
        try ModelValidation.validate(project)
        return project
    }
}
