#!/usr/bin/env python3
"""Original industrial demo assets. Python standard library; metres, Y up.

Regenerates geometry, textures and the matching logical scene. materials.icmat
is a separately authored asset: seed it once, never overwrite authored edits.
The GLBs carry named material slots; the canonical library owns their values.
"""
import hashlib
import json
import math
from pathlib import Path
import struct
import zlib
import lighting_seed

ROOT = Path(__file__).resolve().parent
SPAN = 64
ZONES = [(0, 0, "Foundry Street"), (1, 0, "Freight Yard"),
         (0, 1, "Motor Works"), (1, 1, "Canal Warehouses")] + [(0, -i, f"Vehicle Test Road {i}") for i in range(1, 17)]
MATERIALS = [
    ("Asphalt", (58, 60, 61), 0, .94, "grain"),
    ("Concrete", (157, 151, 136), 0, .83, "slab"),
    ("Brick", (125, 65, 43), 0, .88, "brick"),
    ("Galvanized", (137, 150, 151), .85, .48, "rib"),
    ("Painted Steel", (45, 73, 66), .25, .58, "rib"),
    ("Window", (31, 48, 55), .45, .2, "window"),
    ("Road Paint", (221, 196, 125), 0, .72, "grain"),
    ("Roof", (55, 57, 54), .1, .92, "grain"),
    ("Lamp", (248, 218, 162), 0, .4, "grain"),
]


def asset_id(kind, key, label):
    h = hashlib.sha256(b"incinerator.game.asset.identity.v1" + bytes([kind]))
    for s in (key, label):
        b = s.encode()
        h.update(struct.pack("<I", len(b)) + b)
    return dict(namespace=0x494e43494e455241, local=int.from_bytes(h.digest()[:8], "little") or 1)


def png(pixels, size=128):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
    rows = b"".join(b"\0" + bytes(pixels[y*size*4:(y+1)*size*4]) for y in range(size))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


LETTERS = {
'C':['01110','10001','10000','10000','10000','10001','01110'],
'O':['01110','10001','10001','10001','10001','10001','01110'],
'R':['11110','10001','10001','11110','10100','10010','10001'],
'N':['10001','11001','10101','10011','10001','10001','10001'],
'E':['11111','10000','10000','11110','10000','10000','11111'],
'M':['10001','11011','10101','10101','10001','10001','10001'],
'A':['01110','10001','10001','11111','10001','10001','10001'],
'T':['11111','00100','00100','00100','00100','00100','00100'],
'P':['11110','10001','10001','11110','10000','10000','10000'],
'S':['01111','10000','10000','01110','00001','00001','11110'],
'V':['10001','10001','10001','10001','10001','01010','00100'],
'I':['11111','00100','00100','00100','00100','00100','11111'],
}
def lettering(pattern,x,y):
    text={'neon':'OPEN','store':'CORNER MART','service':'SERVICE'}[pattern]
    # Independent x/y scales make the square atlas fit each physical sign.
    scale=108/(len(text)*6-1);column=int((x-10)/scale);row=int((y-42)/6)
    if x<10 or y<42 or row>=7 or column<0 or column//6>=len(text):return False
    letter=LETTERS.get(text[column//6]);return bool(letter and column%6<5 and letter[row][column%6]=='1')


def texture_maps(color, metallic, roughness, pattern):
    maps = [[], [], [], []]
    for y in range(128):
        for x in range(128):
            noise = ((x*739 + y*113 + x*y*71) % 23 - 11) / 255
            mortar = pattern == "brick" and (y % 24 < 2 or (x + (y//24 % 2)*32) % 64 < 2)
            seam = pattern == "slab" and (x < 2 or y < 2)
            rib = math.sin(x * math.pi / 8) if pattern == "rib" else 0
            gain = .64 if mortar or seam else 1 + noise + rib*.06
            if pattern in ('neon','store','service'):
                lit=lettering(pattern,x,y)
                rgb=list(color) if lit else ([3,4,7] if pattern!='service' else [12,18,15])
                maps[0].extend(rgb+[255])
            else:maps[0].extend([max(0, min(255, int(c*gain))) for c in color] + [255])
            maps[1].extend([255, int(roughness*255), int(metallic*255), 255])
            nx = int(128 + rib*32) if pattern == "rib" else 128 + int(noise*90)
            maps[2].extend([nx, 128 + int(noise*90), 254, 255])
            ao = 205 if mortar or seam else 255
            maps[3].extend([ao, ao, ao, 255])
    return [png(m) for m in maps]


class Scene:
    def __init__(self, key, title):
        self.key, self.title = key, title
        self.data = bytearray()
        self.g = dict(asset=dict(version="2.0", generator="Incinerator original industrial authoring"),
                      buffers=[], bufferViews=[], accessors=[], images=[], textures=[],
                      samplers=[dict(magFilter=9729, minFilter=9729, wrapS=10497, wrapT=10497)],
                      materials=[], meshes=[], nodes=[], scenes=[dict(nodes=[])], scene=0)
        self.definitions, self.bindings = [], []
        authored_materials=MATERIALS + ([('Neon',(255,18,108),0,.4,'neon'),('Store Sign',(190,225,255),0,.65,'store'),('Service Sign',(230,233,197),0,.82,'service')] if title=='Foundry Street' else [])
        for name, color, metal, rough, pattern in authored_materials:
            label = title + " / " + name
            ids = []
            for role, pixels in zip(("Color", "Response", "Normal", "Occlusion"), texture_maps(color, metal, rough, pattern)):
                texname = label + " " + role
                view = self.view(pixels)
                index = len(self.g["textures"])
                self.g["images"].append(dict(name=texname, bufferView=view, mimeType="image/png"))
                self.g["textures"].append(dict(name=texname, sampler=0, source=index))
                ids.append(asset_id(3, key, texname))
            start = len(self.g["textures"]) - 4
            # These map references also declare the color-space roles to the cooker.
            self.g["materials"].append(dict(name=label, pbrMetallicRoughness=dict(
                baseColorTexture=dict(index=start), metallicRoughnessTexture=dict(index=start+1),
                metallicFactor=1, roughnessFactor=1), normalTexture=dict(index=start+2),
                occlusionTexture=dict(index=start+3)))
            value = dict(base_color=[1,1,1,1], base_color_texture=ids[0], base_color_texcoord=0,
                         metallic=1, roughness=1, normal_scale=.45, occlusion_strength=.6,
                         emissive=([1000,720,300] if name=="Lamp" else [500,20,150] if name=="Neon" else [450,550,700] if name=="Store Sign" else [0,0,0]),
                         metallic_roughness_texture=ids[1], normal_texture=ids[2], occlusion_texture=ids[3],
                         emissive_texture=ids[0] if name in ("Lamp","Neon","Store Sign") else None)
            self.definitions.append(dict(id=asset_id(2,key,label),label=label,revision=1,value=value))

    def view(self, data):
        while len(self.data) % 4: self.data.append(0)
        index = len(self.g["bufferViews"])
        self.g["bufferViews"].append(dict(buffer=0, byteOffset=len(self.data), byteLength=len(data)))
        self.data.extend(data)
        return index

    def accessor(self, values, width, scalar=5126):
        flat = [v for row in values for v in row]
        data = struct.pack("<" + ("f" if scalar == 5126 else "I")*len(flat), *flat)
        a = dict(bufferView=self.view(data), componentType=scalar, count=len(values), type={1:"SCALAR",2:"VEC2",3:"VEC3"}[width])
        if width == 3:
            a.update(min=[min(row[i] for row in values) for i in range(3)], max=[max(row[i] for row in values) for i in range(3)])
        self.g["accessors"].append(a)
        return len(self.g["accessors"])-1

    def box(self, name, center, size, material, tile=2):
        # Explicit CCW exterior quads with physical-scale UVs.
        positions, normals, uv, indices = [], [], [], []
        for axis, sign, u, v in [(0,1,1,2),(0,-1,2,1),(1,1,2,0),(1,-1,0,2),(2,1,0,1),(2,-1,1,0)]:
            base = len(positions)
            for a,b in [(-1,-1),(1,-1),(1,1),(-1,1)]:
                p = list(center)
                p[axis] += size[axis]*sign/2
                p[u] += size[u]*a/2
                p[v] += size[v]*b/2
                n = [0,0,0]; n[axis] = sign
                positions.append(p); normals.append(n)
                uv.append([(a+1)/2*(size[u]/tile if tile else 1), ((b+1)/2*size[v]/tile if tile else (1-b)/2)])
            indices.extend([(base,), (base+1,), (base+2,), (base,), (base+2,), (base+3,)])
        label = self.title + " / " + name
        mi = len(self.g["meshes"])
        self.g["meshes"].append(dict(name=label, primitives=[dict(attributes=dict(
            POSITION=self.accessor(positions,3), NORMAL=self.accessor(normals,3), TEXCOORD_0=self.accessor(uv,2)),
            indices=self.accessor(indices,1,5125), material=material)]))
        self.g["nodes"].append(dict(name=label, mesh=mi))
        self.g["scenes"][0]["nodes"].append(mi)
        self.bindings.append(dict(mesh=asset_id(1,self.key,label),material=self.definitions[material]["id"],revision=1))

    def save(self, path):
        self.g["buffers"] = [dict(byteLength=len(self.data))]
        js = json.dumps(self.g, separators=(",", ":")).encode()
        js += b" " * (-len(js)%4)
        self.data += b"\0" * (-len(self.data)%4)
        content = struct.pack("<I4s", len(js), b"JSON") + js + struct.pack("<I4s",len(self.data),b"BIN\0") + self.data
        path.write_bytes(struct.pack("<4sII",b"glTF",2,12+len(content))+content)


def zig(value):
    if isinstance(value, (list,tuple)): return ".{ " + ", ".join(zig(v) for v in value) + " }"
    return str(value)


def generate():
    definitions, bindings, blocks = [], [], []
    for zi, (cx, cz, title) in enumerate(ZONES):
        key = f"district/industrial_{cx}_{cz}"
        scene = Scene(key,title)
        ox,oz = cx*SPAN,cz*SPAN
        def box(name, p, s, m, tile=2): scene.box(name,(p[0]+ox,p[1],p[2]+oz),s,m,tile)
        if cz < 0:
            # A kilometre of connected test road, streamed in ordinary 64 m cells.
            box("Test apron",(0,-.035,0),(64,.05,64),1,3)
            box("Test road",(0,-.003,0),(24,.02,64),0,4)
            for n in range(-30,32,6):
                box(f"Test center line {n}",(0,.011,n),(.12,.012,3),6)
            for side in [-1,1]:
                box(f"Test edge {side}",(side*12,.011,0),(.15,.012,64),6)
            zone_blocks=[]
            for x,z in [(-28,-24),(28,-24),(-28,24),(28,24)]:
                box(f"Distance marker {x} {z}",(x,.5,z),(1,1,1),6)
                zone_blocks.append(((x+ox,.5,z+oz),(.5,.5,.5)))
            scene.save(ROOT/f"industrial_{cx}_{cz}.glb")
            definitions.extend(scene.definitions); bindings.extend(scene.bindings); blocks.append(zone_blocks)
            continue
        box("Yard paving",(0,-.035,0),(64,.05,64),1,3)
        box("East west street",(0,-.003,0),(64,.02,12),0,4)
        box("North south street",(0,-.002,0),(12,.02,64),0,4)
        for side in [-1,1]:
            box(f"Street walk Z {side}",(0,.013,side*7.3),(64,.025,2.6),1,2)
            box(f"Street walk X {side}",(side*7.3,.014,0),(2.6,.025,64),1,2)
            for n in range(-30,32,6):
                if abs(n)<7: continue
                box(f"Lane marking {side} {n}",(n,.011,side*.18),(2.7,.012,.12),6)
        zone_blocks=[]
        for bi,(x,z,w,d,h,mat) in enumerate([
            (-20,-20,18,18,8+zi,2), (20,-20,20,18,6+zi,3),
            (-20,18,20,14,5 if zi==0 else 8,2 if zi%2==0 else 3),
            (20,20,18,20,9-zi,3 if zi%2==0 else 2)]):
            if zi==0 and bi==0:
                # A real shallow shop. Window aperture is absent from BOTH
                # render geometry and collision; it is not a glowing solid box.
                for name,p,size in [
                    ('rear volume',(-20,4,-22.5),(18,8,13)),
                    ('left wall',(-28.85,1.6,-13.5),(.3,3.2,5)),
                    ('right wall',(-11.15,1.6,-13.5),(.3,3.2,5)),
                    ('front left',(-26.5,4,-11),(5,8,.3)),
                    ('front right',(-13.5,4,-11),(5,8,.3)),
                    ('window sill',(-20,.5,-11),(8,1,.3)),
                    ('window lintel',(-20,5.5,-11),(8,5,.3)),
                    ('ceiling',(-20,3.25,-13.5),(18,.12,5)),
                    ('counter',(-20,.65,-14.6),(7,1.3,.65)),
                ]:
                    box('Shop '+name,p,size,mat if name not in ('ceiling','counter') else 1)
                    zone_blocks.append(((p[0]+ox,p[1],p[2]+oz),tuple(v/2 for v in size)))
                box('Shop floor',(-20,.065,-13.5),(17.6,.10,4.5),1,1)
                for wx in [-24,-20,-16]:
                    box(f'Shop window mullion {wx}',(wx,2,-10.80),(.07,2,.10),4)
                    zone_blocks.append(((wx,2,-10.80),(.035,1,.05)))
                for wx in [-23,-17]:
                    box(f'Shop overhead housing {wx}',(wx,3.02,-13.25),(1.8,.12,.5),4)
                    box(f'Shop overhead lens {wx}',(wx,2.95,-13.25),(1.65,.025,.4),8)
                box('Corner Mart illuminated sign',(-20,3.7,-10.75),(9,1.3,.10),10,None)
                box('Neon OPEN',(-26,2.55,-10.73),(3.4,1.0,.10),9,None)
            else:
                box(f"Building {bi} shell",(x,h/2,z),(w,h,d),mat,.5 if mat == 2 else 2)
                zone_blocks.append(((x+ox,h/2,z+oz),(w/2,h/2,d/2)))
            box(f"Building {bi} roof",(x,h+.1,z),(w+.4,.2,d+.4),7,3)
            front = z-math.copysign(d/2+.04,z)
            for door in ([] if zi==0 and bi==0 else [-1,1]):
                dx = x+door*w*.25
                box(f"Building {bi} shutter {door}",(dx,1.65,front),(4,3.3,.07),4,2)
                box(f"Building {bi} lintel {door}",(dx,3.5,front),(4.4,.22,.18),1)
                box(f"Building {bi} lamp {door}",(dx,4.15,front),(1.1,.17,.2),8)
            for wi in ([] if zi==0 and bi==0 else range(4)):
                wx=x-w/2+2+wi*(w-4)/3
                box(f"Building {bi} upper window {wi}",(wx,h-1.3,front),(1.7,1.1,.08),5)
            # Weathered concrete plinth is part of the same collision envelope.
            box(f"Building {bi} plinth",(x,.3,front),(w,.6,.1),1)
        for side in [-1,1]:
            px,pz=side*8.65,side*18
            box(f'Street pole {side}',(px,2.85,pz),(.20,5.7,.20),3)
            zone_blocks.append(((px+ox,2.85,pz+oz),(.10,2.85,.10)))
            box(f'Street arm {side}',(side*8,5.65,pz),(1.5,.12,.12),3)
            box(f'Street housing {side}',(side*7.4,5.58,pz),(.7,.16,.5),4)
            box(f'Street lens {side}',(side*7.4,5.49,pz),(.58,.025,.4),8)
        if zi==0:
            box('Courtyard lamp post',(8.8,1.5,8.8),(.16,3,.16),4)
            zone_blocks.append(((8.8,1.5,8.8),(.08,1.5,.08)))
            box('Courtyard lamp shade',(8.8,3.28,8.8),(.65,.10,.65),4)
            box('Courtyard lamp lens',(8.8,3.21,8.8),(.48,.025,.48),8)
            box('Service sign',(20,3.6,-10.76),(6,1.25,.10),11,None)
            box('Service floodlight housing',(18,5.2,-8.15),(.40,.24,.18),4)
        # Loading markings and a service alley remain traversable, with no fake solids.
        for n in range(3):
            box(f"Loading bay line {n}",(11+n*5,.012,29),(0.12,.014,5),6)
        scene.save(ROOT/f"industrial_{cx}_{cz}.glb")
        definitions.extend(scene.definitions); bindings.extend(scene.bindings); blocks.append(zone_blocks)
    # Source material data has one writer once authored. Regenerating geometry
    # cannot reset material edits or bindings.
    material_path = ROOT/"materials.icmat"
    if not material_path.exists():
        payload=json.dumps(dict(materials=definitions,bindings=bindings),separators=(",",":")).encode()
        material_path.write_bytes(b"ICMATLIB"+struct.pack("<IQ",1,len(payload))+hashlib.sha256(payload).digest()+payload)
    else:
        saved=json.loads(material_path.read_bytes()[52:])
        key=lambda value:json.dumps(value,sort_keys=True)
        known={key(v['id']) for v in saved['materials']}
        saved['materials'].extend(v for v in definitions if key(v['id']) not in known)
        meshes={key(v['mesh']) for v in bindings}
        saved['bindings']=[v for v in saved['bindings'] if key(v['mesh']) in meshes]
        bound={key(v['mesh']) for v in saved['bindings']}
        saved['bindings'].extend(v for v in bindings if key(v['mesh']) not in bound)
        payload=json.dumps(saved,separators=(",",":")).encode()
        material_path.write_bytes(b"ICMATLIB"+struct.pack("<IQ",1,len(payload))+hashlib.sha256(payload).digest()+payload)
    lighting_seed.generate(ROOT,asset_id,ZONES)
    out = ["//! Generated by game/industrial/generate.py; source geometry and collision share dimensions.",
           "pub const chunk_span: f32 = 64;", "pub const boxes = .{"]
    for zone in blocks:
        out.append("    .{")
        for p,h in zone: out.append("        .{ .position = "+zig(p)+", .half_extents = "+zig(h)+" },")
        out.append("    },")
    out.append("};")
    out.append(f"pub const max_static_box_count: usize = {max(len(zone) for zone in blocks)};")
    navigation_positions = [(-8,-8),(0,-8),(8,-8),(8,0),(8,8),(0,8),(-8,8),(-8,0),(31,8),(-31,8),(8,31),(8,-31)]
    out.append("pub const navigation_positions = [_][2]f32" + zig(navigation_positions)[1:] + ";")
    # Eight perimeter links and four spokes are reciprocal. The neighborhood
    # has two adjacent cells per zone; capacities follow these authored edges.
    edges_per_zone = [24 + sum((x+dx,z+dz) in [(a,b) for a,b,_ in ZONES] for dx,dz in [(1,0),(-1,0),(0,1),(0,-1)]) for x,z,_ in ZONES]
    out.append(f"pub const navigation_edge_capacity: usize = {max(edges_per_zone)};")
    out.append("pub const navigation_degree: usize = 3;")
    (ROOT/"scene.zig").write_text("\n".join(out)+"\n")


if __name__ == "__main__": generate()
