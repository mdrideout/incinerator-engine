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


def texture_maps(color, metallic, roughness, pattern):
    maps = [[], [], [], []]
    for y in range(128):
        for x in range(128):
            noise = ((x*739 + y*113 + x*y*71) % 23 - 11) / 255
            mortar = pattern == "brick" and (y % 24 < 2 or (x + (y//24 % 2)*32) % 64 < 2)
            seam = pattern == "slab" and (x < 2 or y < 2)
            rib = math.sin(x * math.pi / 8) if pattern == "rib" else 0
            gain = .64 if mortar or seam else 1 + noise + rib*.06
            maps[0].extend([max(0, min(255, int(c*gain))) for c in color] + [255])
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
        for name, color, metal, rough, pattern in MATERIALS:
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
                         emissive=[1.5,1.1,.65] if name == "Lamp" else [0,0,0],
                         metallic_roughness_texture=ids[1], normal_texture=ids[2], occlusion_texture=ids[3],
                         emissive_texture=ids[0] if name == "Lamp" else None)
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
                uv.append([(a+1)/2*size[u]/tile, (b+1)/2*size[v]/tile])
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
            box(f"Building {bi} shell",(x,h/2,z),(w,h,d),mat,.5 if mat == 2 else 2)
            zone_blocks.append(((x+ox,h/2,z+oz),(w/2,h/2,d/2)))
            box(f"Building {bi} roof",(x,h+.1,z),(w+.4,.2,d+.4),7,3)
            front = z-math.copysign(d/2+.04,z)
            for door in [-1,1]:
                dx = x+door*w*.25
                box(f"Building {bi} shutter {door}",(dx,1.65,front),(4,3.3,.07),4,2)
                box(f"Building {bi} lintel {door}",(dx,3.5,front),(4.4,.22,.18),1)
                box(f"Building {bi} lamp {door}",(dx,4.15,front),(1.1,.17,.2),8)
            for wi in range(4):
                wx=x-w/2+2+wi*(w-4)/3
                box(f"Building {bi} upper window {wi}",(wx,h-1.3,front),(1.7,1.1,.08),5)
            # Weathered concrete plinth is part of the same collision envelope.
            box(f"Building {bi} plinth",(x,.3,front),(w,.6,.1),1)
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
        known={json.dumps(v['id'],sort_keys=True) for v in saved['materials']}
        added=[v for v in definitions if json.dumps(v['id'],sort_keys=True) not in known]
        if added:
            new_ids={json.dumps(v['id'],sort_keys=True) for v in added}
            saved['materials'].extend(added)
            # Bindings are scoped to a distinct source bundle/primitive.
            saved['bindings'].extend(v for v in bindings if json.dumps(v['material'],sort_keys=True) in new_ids)
            payload=json.dumps(saved,separators=(",",":")).encode()
            material_path.write_bytes(b"ICMATLIB"+struct.pack("<IQ",1,len(payload))+hashlib.sha256(payload).digest()+payload)
    out = ["//! Generated by game/industrial/generate.py; source geometry and collision share dimensions.",
           "pub const chunk_span: f32 = 64;", "pub const boxes = .{"]
    for zone in blocks:
        out.append("    .{")
        for p,h in zone: out.append("        .{ .position = "+zig(p)+", .half_extents = "+zig(h)+" },")
        out.append("    },")
    out.append("};")
    navigation_positions = [(-8,-8),(0,-8),(8,-8),(8,0),(8,8),(0,8),(-8,8),(-8,0),(31,8),(-31,8),(8,31),(8,-31)]
    out.append("pub const navigation_positions = [_][2]f32" + zig(navigation_positions)[1:] + ";")
    # Eight perimeter links and four spokes are reciprocal. The neighborhood
    # has two adjacent cells per zone; capacities follow these authored edges.
    edges_per_zone = [24 + sum((x+dx,z+dz) in [(a,b) for a,b,_ in ZONES] for dx,dz in [(1,0),(-1,0),(0,1),(0,-1)]) for x,z,_ in ZONES]
    out.append(f"pub const navigation_edge_capacity: usize = {max(edges_per_zone)};")
    out.append("pub const navigation_degree: usize = 3;")
    (ROOT/"scene.zig").write_text("\n".join(out)+"\n")


if __name__ == "__main__": generate()
