#!/usr/bin/env python3
"""Original vehicle geometry and atlas artwork. No external or game assets.

This regenerates only the GLBs. Vehicle handling assets have their own writer.
Coordinates: metres, +Y up, -Z forward, wheel axle +X.
"""
from pathlib import Path
import math, struct, json, zlib
ROOT = Path(__file__).parent

def png(w,h,pixels):
    def chunk(t,b): return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)
    data=b''.join(b'\0'+bytes(pixels[y*w*4:(y+1)*w*4]) for y in range(h))
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(data))+chunk(b'IEND',b'')

class Scene:
    def __init__(self,paint):
        self.data=bytearray();self.g=dict(asset=dict(version='2.0',generator='Incinerator original vehicle authoring'),buffers=[],bufferViews=[],accessors=[],images=[],textures=[],samplers=[dict(magFilter=9728,minFilter=9728,wrapS=33071,wrapT=33071)],materials=[],meshes=[],nodes=[],scenes=[dict(nodes=[])],scene=0)
        colors=[paint,(26,43,52),(24,24,27),(185,191,194),(248,227,166),(156,19,20),(238,165,37),(16,16,18)]
        for name,role in [('Color','color'),('Response','response')]:
            pixels=[]
            for y in range(32):
                for x in range(256):
                    band=x//32
                    if role=='color':
                        c=colors[band];shade=.82+.18*y/31
                        pixels.extend([int(v*shade) for v in c]+[255])
                    else:
                        rough=[95,45,210,70,75,80,85,225][band];metal=[180,0,0,240,0,0,0,0][band]
                        pixels.extend([255,rough,metal,255])
            view=self.view(png(256,32,pixels));i=len(self.g['images']);self.g['images'].append(dict(name=name,bufferView=view,mimeType='image/png'));self.g['textures'].append(dict(name=name,sampler=0,source=i))
        for name in ['Paint','Rubber']:
            self.g['materials'].append(dict(name=name,pbrMetallicRoughness=dict(baseColorTexture=dict(index=0),metallicRoughnessTexture=dict(index=1),metallicFactor=1,roughnessFactor=1)))
    def view(self,b):
        self.data.extend(b'\0'*(-len(self.data)%4));i=len(self.g['bufferViews']);self.g['bufferViews'].append(dict(buffer=0,byteOffset=len(self.data),byteLength=len(b)));self.data.extend(b);return i
    def accessor(self,rows,n,typ=5126):
        values=[v for row in rows for v in row];a=dict(bufferView=self.view(struct.pack('<'+('f' if typ==5126 else 'I')*len(values),*values)),componentType=typ,count=len(rows),type={1:'SCALAR',2:'VEC2',3:'VEC3'}[n]);
        if n==3:a.update(min=[min(r[i] for r in rows) for i in range(3)],max=[max(r[i] for r in rows) for i in range(3)])
        self.g['accessors'].append(a);return len(self.g['accessors'])-1
    def mesh(self,name,faces,material):
        p=[];n=[];uv=[];ix=[]
        for vertices,band in faces:
            a,b,c=vertices[:3];u=[b[i]-a[i] for i in range(3)];v=[c[i]-a[i] for i in range(3)];normal=[u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]];mag=math.sqrt(sum(x*x for x in normal));normal=[x/mag for x in normal];base=len(p)
            for j,vert in enumerate(vertices):p.append(vert);n.append(normal);uv.append(((band+.2+.6*(j%2))/8,.2+.6*(j//2%2)))
            for j in range(1,len(vertices)-1):ix.extend([(base,),(base+j,),(base+j+1,)])
        i=len(self.g['meshes']);self.g['meshes'].append(dict(name=name,primitives=[dict(attributes=dict(POSITION=self.accessor(p,3),NORMAL=self.accessor(n,3),TEXCOORD_0=self.accessor(uv,2)),indices=self.accessor(ix,1,5125),material=material)]));self.g['nodes'].append(dict(name=name,mesh=i));self.g['scenes'][0]['nodes'].append(i)
    def save(self,path):
        self.g['buffers']=[dict(byteLength=len(self.data))];js=json.dumps(self.g,separators=(',',':')).encode();js+=b' '*(-len(js)%4);self.data.extend(b'\0'*(-len(self.data)%4));chunks=struct.pack('<I4s',len(js),b'JSON')+js+struct.pack('<I4s',len(self.data),b'BIN\0')+self.data;path.write_bytes(struct.pack('<4sII',b'glTF',2,len(chunks)+12)+chunks)

def box(faces,center,size,band):
    for axis,sign,u,v in [(0,1,1,2),(0,-1,2,1),(1,1,2,0),(1,-1,0,2),(2,1,0,1),(2,-1,1,0)]:
        verts=[]
        for a,b in [(-1,-1),(1,-1),(1,1),(-1,1)]:
            p=list(center);p[axis]+=size[axis]*sign/2;p[u]+=size[u]*a/2;p[v]+=size[v]*b/2;verts.append(p)
        faces.append((verts,band))

# Each silhouette owns its cabin, doors and trim; physics owns wheel placement.
STYLES = {
    'meridian': dict(kind='coupe', color=(47,99,151), roof=.69, cabin_front=-.32, cabin_rear=.43, roof_front=-.08, roof_rear=.19, pillar=.16, doors=(-.04,)),
    'courier': dict(kind='sedan', color=(176,80,39), roof=.80, cabin_front=-.38, cabin_rear=.54, roof_front=-.20, roof_rear=.34, pillar=.01, doors=(-.10,.34)),
    'courier-awd': dict(kind='suv', color=(64,112,77), roof=1.01, cabin_front=-.40, cabin_rear=.89, roof_front=-.26, roof_rear=.82, pillar=.04, doors=(-.09,.35)),
}

def cabin_side(faces, side, w, l, bottom_y, top_y, z0, z1, band):
    # Side glass lies on the tapered cabin plane. Paint strips divide panes.
    verts=[(side*w*.94,bottom_y,z0*l),(side*w*.94,bottom_y,z1*l),
           (side*w*.78,top_y,z1*l),(side*w*.78,top_y,z0*l)]
    if side > 0: verts.reverse()
    faces.append((verts,band))

def generate():
    for name,style in STYLES.items():
        d=json.loads((ROOT/(name+'.json')).read_text());t=d['tuning'];w,h,l=t['chassis_half_extents'];scene=Scene(style['color']);f=[]
        suv=style['kind']=='suv';coupe=style['kind']=='coupe'
        bottom_y=-.47 if suv else -.30
        belt=.25 if suv else .20
        box(f,(0,(bottom_y+belt)/2,0),(2*w,belt-bottom_y,2*l),0)
        # Long hood + separate trunk on coupe/sedan; tall enclosed cargo body on SUV.
        box(f,(0,belt+.04,-l*.65),(w*1.92,.12,l*.67),0)
        if not suv:box(f,(0,belt+.025,l*.76),(w*1.92,.10,l*.43),0)
        front,rear=style['cabin_front'],style['cabin_rear'];rf,rr=style['roof_front'],style['roof_rear'];roof=style['roof']
        bottom=[(-w*.94,belt,front*l),(w*.94,belt,front*l),(w*.94,belt,rear*l),(-w*.94,belt,rear*l)]
        top=[(-w*.78,roof,rf*l),(w*.78,roof,rf*l),(w*.78,roof,rr*l),(-w*.78,roof,rr*l)]
        f.append(([top[0],top[3],top[2],top[1]],0))
        for a,b in [(0,1),(1,2),(2,3),(3,0)]:f.append(([top[a],top[b],bottom[b],bottom[a]],1))
        for side in [-1,1]:
            # Pillars and seams distinguish two long coupe doors from four sedan/SUV doors.
            pillar=style['pillar']
            cabin_side(f,side,w*1.002,l,belt,roof,pillar-.018,pillar+.018,0)
            if suv:cabin_side(f,side,w*1.002,l,belt,roof,.53,.57,0)
            for z in style['doors']:
                box(f,(side*(w+.01),belt-.10,z*l),(.025,.045,.17),3)
                seam=z+.075
                box(f,(side*(w+.006),(bottom_y+belt)/2,seam*l),(.012,belt-bottom_y-.035,.013),2)
            box(f,(side*(w+.07),belt+.10,front*l),(.17,.12,.24),0)
            box(f,(side*(w+.009),bottom_y+.055,0),(.025,.085,l*1.85),2)
            if suv:
                box(f,(side*w*.70,roof+.045,.27*l),(.045,.09,1.86),2)
                box(f,(side*(w+.035),bottom_y+.07,.1),(.13,.10,l*1.45),2)
        for z in [-l-.015,l+.015]:box(f,(0,bottom_y+.10,z),(w*1.98,.20 if suv else .14,.095),2)
        for x in [-w*.65,w*.65]:
            box(f,(x,belt-.10,-l-.025),(.43,.17,.03),4)
            box(f,(x,belt-.10,l+.025),(.19 if suv else .40,.32 if suv else .14,.03),5)
        box(f,(0,belt-.15,-l-.045),(.61,.22,.03),2)
        # Semantic design metadata is retained in the authored source GLB.
        scene.g['asset']['extras']=dict(body_style=style['kind'],door_count=2 if coupe else 4,archetype=name)
        scene.mesh('Body',f,0)
        # Canonical wheel mesh has width=1 and diameter=1; definition supplies scaling.
        f=[];segments=24
        for i in range(segments):
            a=2*math.pi*i/segments;b=2*math.pi*(i+1)/segments
            ring=lambda x,r,ang:(x,math.cos(ang)*r,math.sin(ang)*r)
            f.append(([ring(-.5,.5,b),ring(.5,.5,b),ring(.5,.5,a),ring(-.5,.5,a)],7))
            for side in [-1,1]:
                verts=[ring(side*.5,.5,a),ring(side*.5,.5,b),ring(side*.505,.30,b),ring(side*.505,.30,a)]
                if side<0:verts.reverse()
                f.append((verts,7));v=[(side*.51,0,0),ring(side*.51,.30,a),ring(side*.51,.30,b)]
                if side<0:v.reverse()
                f.append((v,3 if i%4<2 else 2))
        scene.mesh('Wheel',f,1)
        # EA3 reusable unit lens mesh/material; the lighting rig owns pose,
        # scale and emission strength, independently from the handling asset.
        scene.g['materials'].append(dict(name='Headlight Lens',pbrMetallicRoughness=dict(baseColorFactor=[0,0,0,1],metallicFactor=0,roughnessFactor=.35),emissiveFactor=[1,1,1]))
        lens=[];box(lens,(0,0,0),(1,1,1),4)
        scene.mesh('HeadlightLens',lens,2)
        scene.save(ROOT/(name+'.glb'))
if __name__=='__main__':generate()
