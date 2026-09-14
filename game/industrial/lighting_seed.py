"""Original game lighting assets. Add missing members; preserve authored values."""
import hashlib, json, math, struct
from pathlib import Path

def write_library(path, data):
    payload=json.dumps(data,separators=(',',':')).encode()
    path.write_bytes(b'ICLIGHTS'+struct.pack('<IQ',1,len(payload))+hashlib.sha256(payload).digest()+payload)

def direction_rotation(d):
    length=math.sqrt(sum(v*v for v in d));x,y,z=[v/length for v in d]
    if z > .999999:return [0,1,0,0]
    q=[y,-x,0,1-z];length=math.sqrt(sum(v*v for v in q));return [v/length for v in q]

def generate(root, asset_id, zones):
    path=root/'lighting.iclight'
    defs=[]
    def ident(label):return asset_id(4,'lighting/industrial',label)
    def add(label,value):defs.append(dict(id=ident(label),label=label,revision=1,value=value))
    for label,sun,ambient,background,exposure,enabled in [
        ('Day',100000,[8000,10000,14000],[8000,14000,22000],.00004,False),
        ('Dusk',70,[5,7,14],[6,10,24],.012,True),
        ('Night',.2,[1.5,2,3],[.015,.03,.07],.06,True)]:
        add(label,dict(environment=dict(sun=dict(kind='directional',color=[1,.55,.28] if label=='Dusk' else [1,1,1],intensity=sun,range=None),sun_direction=[-.8804509,-.17609018,-.44022545] if label=='Dusk' else [-.5773503]*3,ambient=ambient,background=background,display=dict(exposure=exposure,bloom_strength=.08,bloom_threshold=1,bloom_radius=32),headlights_enabled=enabled,artificial_lights_enabled=enabled)))
    def fixture(label,p,kind,energy,color=(1,.78,.48),direction=(0,-1,0),distance=24,outer=.75,inner=.45,mount='world',visual=None,night=True,surface=None):
        value=dict(light=dict(kind=kind,color=list(color),intensity=energy,range=distance,outer_angle=outer,inner_angle=inner,source_radius=.08),pose=dict(position=p,rotation=direction_rotation(direction)),mount={mount:{}} if isinstance(mount,str) else mount,follows_night=night)
        if visual:value['visual']=visual
        if surface:value['surface']=surface
        add(label,dict(fixture=value))
    for cx,cz,title in zones:
        if cz<0:continue
        for side in [-1,1]:
            fixture(f'{title} / Street light {side}',[cx*64+side*7.4,5.45,cz*64+side*18],'spot',3600,direction=(0,-1,0),distance=22,outer=.95,inner=.65,surface=dict(mesh=asset_id(1,f'district/industrial_{cx}_{cz}',f'{title} / Street lens {side}'),emissive_scale=650))
    fixture('Foundry Street / Courtyard lamp',[8.8,3.15,8.8],'point',850,distance=14,surface=dict(mesh=asset_id(1,'district/industrial_0_0','Foundry Street / Courtyard lamp lens'),emissive_scale=650))
    for x in [-23,-17]:
        fixture(f'Foundry Street / Shop overhead {x}',[x,2.83,-13.25],'point',750,color=(1,.9,.75),distance=12,night=False,surface=dict(mesh=asset_id(1,'district/industrial_0_0',f'Foundry Street / Shop overhead lens {x}'),emissive_scale=650))
    fixture('Foundry Street / Neon spill',[-26,2.55,-10.60],'point',180,color=(1,.018,.28),distance=6,surface=dict(mesh=asset_id(1,'district/industrial_0_0','Foundry Street / Neon OPEN')))
    fixture('Foundry Street / Store sign spill',[-20,3.70,-10.60],'spot',600,color=(.4,.75,1),direction=(0,-.65,.76),distance=9,outer=1.15,inner=.75,surface=dict(mesh=asset_id(1,'district/industrial_0_0','Foundry Street / Corner Mart illuminated sign')))
    fixture('Foundry Street / Sign floodlight',[18,5.2,-8.3],'spot',2500,color=(1,.88,.6),direction=(2,-1.6,-2.5),distance=12,outer=.65,inner=.3,surface=dict(mesh=asset_id(1,'district/industrial_0_0','Foundry Street / Service floodlight housing')))
    for name in ['meridian','courier','courier-awd']:
        car=json.loads((root.parent/'vehicles'/(name+'.json')).read_text())
        w,h,l=car['tuning']['chassis_half_extents'];belt=.25 if name=='courier-awd' else .2
        for side in [-1,1]:
            fixture(f"{car['label']} / {'Left' if side<0 else 'Right'} headlight",[side*w*.65,belt-.1,-l-.13],'spot',18000,color=(1,.91,.74),direction=(side*.025,-.025,-1),distance=100,outer=.32,inner=.14,mount=dict(vehicle_asset=car['id']['asset']),visual=dict(mesh=asset_id(1,'vehicle/'+name,'HeadlightLens'),material=asset_id(2,'vehicle/'+name,'Headlight Lens'),local_pose=dict(position=[0,0,.07]),scale=[.40,.15,.025],emissive_scale=1200))
    fixture('Portable work lamp',[0,.38,0],'point',400,color=(1,.92,.75),distance=10,mount='carryable',night=False,visual=dict(mesh=asset_id(1,'vehicle/courier','HeadlightLens'),material=asset_id(2,'vehicle/courier','Headlight Lens'),scale=[.3,.2,.15],emissive_scale=700))
    if path.exists():
        saved=json.loads(path.read_bytes()[52:]);known={json.dumps(v['id'],sort_keys=True) for v in saved['definitions']}
        added=[v for v in defs if json.dumps(v['id'],sort_keys=True) not in known]
        if added:saved['definitions'].extend(added);saved['revision']+=1;write_library(path,saved)
    else:write_library(path,dict(revision=1,active_environment=ident('Dusk'),definitions=defs))
    return defs
