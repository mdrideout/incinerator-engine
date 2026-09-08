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

def generate():
    for name,color in [('meridian',(49,83,103)),('courier',(148,66,37))]:
        d=json.loads((ROOT/(name+'.json')).read_text());t=d['tuning'];w,h,l=t['chassis_half_extents'];scene=Scene(color);f=[]
        box(f,(0,-.05,0),(2*w,.50,2*l),0)
        box(f,(0,.23,-l*.61),(2*w*.96,.15,l*.7),0)
        box(f,(0,.22,l*.75),(2*w*.96,.13,l*.44),0)
        # Sloped cabin: windshield and rear window are textured geometry.
        bottom=[(-w*.94,.20,-l*.34),(w*.94,.20,-l*.34),(w*.94,.20,l*.52),(-w*.94,.20,l*.52)]
        top=[(-w*.76,.83,-l*.14),(w*.76,.83,-l*.14),(w*.76,.83,l*.32),(-w*.76,.83,l*.32)]
        f.append(([top[0],top[3],top[2],top[1]],0))
        for a,b in [(0,1),(1,2),(2,3),(3,0)]:f.append(([bottom[a],bottom[b],top[b],top[a]],1))
        for side in [-1,1]:
            box(f,(side*w*.85,.5,l*.12),(.035,.63,.075),0)
            box(f,(side*(w+.07),.32,-l*.27),(.17,.12,.24),0)
            for z in [-l*.05,l*.30]:box(f,(side*(w+.009),.08,z),(.025,.045,.16),3)
            box(f,(side*(w+.004),-.13,0),(.018,.065,l*1.85),2)
        for z in [-l-.015,l+.015]:box(f,(0,-.16,z),(w*1.98,.15,.095),2)
        for x in [-w*.65,w*.65]:
            box(f,(x,.055,-l-.025),(.43,.17,.03),4)
            box(f,(x,.055,l+.025),(.4,.16,.03),5)
        box(f,(0,-.01,-l-.045),(.61,.21,.03),2)
        scene.mesh('Body',f,0)
        # Canonical wheel mesh has width=1 and diameter=1; definition supplies scaling.
        f=[];segments=24
        for i in range(segments):
            a=2*math.pi*i/segments;b=2*math.pi*(i+1)/segments
            ring=lambda x,r,ang:(x,math.cos(ang)*r,math.sin(ang)*r)
            f.append(([ring(-.5,.5,a),ring(.5,.5,a),ring(.5,.5,b),ring(-.5,.5,b)],7))
            for side in [-1,1]:
                verts=[ring(side*.5,.5,a),ring(side*.5,.5,b),ring(side*.505,.30,b),ring(side*.505,.30,a)]
                if side<0:verts.reverse()
                f.append((verts,7));v=[(side*.51,0,0),ring(side*.51,.30,a),ring(side*.51,.30,b)]
                if side<0:v.reverse()
                f.append((v,3 if i%4<2 else 2))
        scene.mesh('Wheel',f,1);scene.save(ROOT/(name+'.glb'))
if __name__=='__main__':generate()
