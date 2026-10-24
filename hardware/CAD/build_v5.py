#!/usr/bin/env python3
"""机械指针 V5: 90 mm stroke, 74T gear on SG90, rear ESP32 pod.

Mechanism frame: the case back plane is z=B (=-DZ); every part is shifted +DZ
on export so the plaque back lands on z=0. Z values of the gear/rack/faceplate
stack are the ones proven on the printed V4.
"""
from pathlib import Path
import json, math, hashlib, argparse, os
import cadquery as cq
import numpy as np
import trimesh
from shapely.geometry import Polygon
from shapely.affinity import rotate, translate
ROOT=Path(__file__).resolve().parents[1]
P=json.loads((ROOT/'CAD/parameters.json').read_text())
CAD=ROOT/'CAD';STL=ROOT/'STL';CHECK=ROOT/'verification'
CACHE=Path(os.environ.get('GAUGE_WORK_DIR',str(ROOT/'work'))).resolve()
for d in (CAD,STL,CHECK,CACHE):d.mkdir(parents=True,exist_ok=True)
W=P['case_width'];H=P['case_height'];WALL=P['wall'];T=P['stroke'];L=P['rack_length']
M=P['gear_module'];N=P['gear_teeth'];ALPHA=math.radians(P['pressure_angle_deg'])
R=M*N/2;GX=P['gear_center_x'];GY=H/2;PX=GX+R+P['rack_center_extra'];AX=PX+4.25
RB=GY-L/2;GZ=30.6
DZ=P['back_extension'];B=-DZ;COVER_Z=P['case_depth']-DZ-WALL
SG=P['sg90'];CY=GY+SG['shaft_offset_from_body_center']
EAR_TO_SHAFT=SG['total_height_to_shaft_top']-SG['ear_bottom_from_base']
# Ear seat: shaft top lands on the gear back face (GZ) with the nominal shim.
SERVO_SEAT=GZ-EAR_TO_SHAFT-P['servo_nominal_shim']
EAR_Y=[CY-SG['ear_hole_spacing']/2,CY+SG['ear_hole_spacing']/2]
JZ0=P['cover_journal_start_z']
FL=PX+1.35;FR=FL+9;GL=PX-.25
# Rail covers the whole rack sweep plus 1.2 mm to each end stop.
RAIL_Y0=GY-(L+T)/2-2.0;RAIL_LEN=L+T+4.0;RAIL_Y1=RAIL_Y0+RAIL_LEN
# Faceplate: two screws at the top; two hooks at the bottom slide under lips in
# the case. Fit it 3.5 mm high, press down, slide down, then screw the top.
MOUNTS=[(5,H-5),(W-5,H-5)]
FACE_SLIDE=3.5
HOOKS_X=[(18,30),(56,68)]
E=P['esp32'];BXC=E['center_x'];BYC=E['center_y']
BX0=BXC-E['pcb_length']/2;BX1=BXC+E['pcb_length']/2
BY0=BYC-E['pcb_width']/2;BY1=BYC+E['pcb_width']/2
HOLES=[(BXC+sx*E['hole_spacing_x']/2,BYC+sy*E['hole_spacing_y']/2) for sx in (-1,1) for sy in (-1,1)]
ROWS=[BYC-E['header_row_spacing']/2,BYC+E['header_row_spacing']/2]
# Pod stack, going backwards from the case back plane B.
POD_FLOOR=2.0;STANDOFF=E['header_plastic'];PCB_Z0=B-POD_FLOOR-STANDOFF
LID_IN=PCB_Z0-E['pcb_thickness']-E['component_height']-.5;LID_T=1.6
IX0,IX1,IY0,IY1=BX0-.5,BX1+.5,BY0-.5,BY1+.5
# Antenna-end holes: two long screws through PCB, standoff and pod floor into
# the case. USB-end holes: locating pins. No other pod screws.
POD_SCREWS=[h for h in HOLES if h[0]>BXC]
POD_PINS=[h for h in HOLES if h[0]<BXC]
# Slide-in lid: grooves in the long walls; the antenna-end wall stops short.
GROOVE=1.2;LID_CLR=.2
WALL_TOP=LID_IN-LID_T-.15-1.2
SLOT_X=E['hole_spacing_x']/2-2.0-.4  # pin slot half-length, clear of standoffs

def box(x,y,z,dx,dy,dz): return cq.Solid.makeBox(dx,dy,dz,cq.Vector(x,y,z))
def cylinder(x,y,z,r,h): return cq.Solid.makeCylinder(r,h,cq.Vector(x,y,z))
def poly(points,z,h):
    return cq.Workplane('XY',origin=(0,0,z)).polyline(points).close().extrude(h).val()
def rbox(x,y,z,dx,dy,dz,r):
    return cq.Workplane('XY',origin=(x,y,z)).box(dx,dy,dz,centered=False).edges('|Z').fillet(r).val()
def join(*s):
    return s[0].fuse(*s[1:]).clean() if len(s)>1 else s[0]
def cut(s,*others):
    # Distinct BOP tools, rather than an overlapping Compound of cutters.
    return s.cut(*others).clean() if others else s
def slot(x,y,z,length,d,h,axis='x'):
    q=(length-d)/2
    if axis=='x': return join(box(x-q,y-d/2,z,2*q,d,h), cylinder(x-q,y,z,d/2,h), cylinder(x+q,y,z,d/2,h))
    return join(box(x-d/2,y-q,z,d,2*q,h), cylinder(x,y-q,z,d/2,h), cylinder(x,y+q,z,d/2,h))

def gear_points(teeth,phase=0,thin=None):
    """Unshifted external involute; root radial relief below base circle.
    Tooth thickness reduction is tangential at pitch circle, for printed backlash.
    """
    r=M*teeth/2; rb=r*math.cos(ALPHA); rf=r-1.25*M; ra=r+M
    thin=P['gear_tooth_thinning'] if thin is None else thin
    invp=math.tan(ALPHA)-ALPHA
    half=math.pi/(2*teeth)-thin/(2*r)
    def flank_angle(rr):
        a=math.acos(min(1.,rb/max(rr,rb)))
        return half+invp-(math.tan(a)-a)
    start=max(rf,rb)
    rr=np.linspace(start,ra,14)
    pts=[]
    for k in range(teeth):
        a=phase+2*math.pi*k/teeth
        lo=flank_angle(start)
        if rf<rb: pts.append((rf*math.cos(a-lo),rf*math.sin(a-lo)))
        pts.extend((float(q*math.cos(a-flank_angle(q))),float(q*math.sin(a-flank_angle(q)))) for q in rr)
        top=flank_angle(ra)
        pts.extend((ra*math.cos(a+b),ra*math.sin(a+b)) for b in np.linspace(-top,top,6)[1:])
        pts.extend((float(q*math.cos(a+flank_angle(q))),float(q*math.sin(a+flank_angle(q)))) for q in rr[::-1][1:])
        if rf<rb: pts.append((rf*math.cos(a+lo),rf*math.sin(a+lo)))
        next_a=a+2*math.pi/teeth-flank_angle(start)
        pts.extend((rf*math.cos(b),rf*math.sin(b)) for b in np.linspace(a+lo,next_a,6)[1:-1])
    return pts

def gear_solid(teeth,x,y,z,h,phase=0):
    return poly([(x+a,y+b) for a,b in gear_points(teeth,phase)],z,h)

def rack_profile():
    root=PX+1.25*M;tip=PX-M;ht=math.pi*M/4-P['gear_tooth_thinning']/2
    htip=ht-M*math.tan(ALPHA);hroot=ht+1.25*M*math.tan(ALPHA)
    points=[(root+6,RB),(root,RB)];centers=[]
    for n in range(-80,81):
        y=GY+(n+.5)*math.pi*M
        if y-hroot>RB+.6 and y+hroot<RB+L-.6:
            centers.append(y);points.extend([(root,y-hroot),(tip,y-htip),(tip,y+htip),(root,y+hroot)])
    points.extend([(root,RB+L),(root+6,RB+L)])
    return points,centers

def rib(y):
    # Self-supporting triangular ribs under the rail. Floor bridges <=11 mm.
    pts=[cq.Vector(W-WALL,y,B+2.4),cq.Vector(W-WALL,y,25.3),cq.Vector(GL,y,25.3)]
    return cq.Solid.extrudeLinear(cq.Wire.makePolygon(pts,close=True),[],cq.Vector(0,3,0))

def arch_window(a,b,start,axis,z0=B+6,top=34):
    """Side-wall opening with a >=45 degree roof and a 2 mm crown bridge."""
    mid=(a+b)/2
    shoulder=top-(b-a-2)/2
    assert shoulder>z0,('arch too wide',a,b)
    outline=[(a,z0),(b,z0),(b,shoulder),(mid+1,top),(mid-1,top),(a,shoulder)]
    if axis=='x':
        pts=[cq.Vector(start,u,z) for u,z in outline];direction=cq.Vector(2.8,0,0)
    else:
        pts=[cq.Vector(u,start,z) for u,z in outline];direction=cq.Vector(0,2.8,0)
    return cq.Solid.extrudeLinear(cq.Wire.makePolygon(pts,close=True),[],direction)

def ribs_y():
    return list(np.arange(RAIL_Y0,RAIL_Y1-3,14))+[RAIL_Y1-3]

def pin_slots(z,h):
    # Two header slots, wide enough for Dupont housings to pass from inside.
    return [box(BXC-SLOT_X,y-2.25,z,2*SLOT_X,4.5,h) for y in ROWS]

def housing():
    outer=rbox(0,0,B,W,H,COVER_Z-B,2.4)
    s=cut(outer,box(WALL,WALL,B+WALL,W-2*WALL,H-2*WALL,COVER_Z-B-WALL+.1))
    bits=[s]
    for x,y in MOUNTS:bits.append(cylinder(x,y,B+2.4,4,COVER_Z-B-2.4))
    # Integral open-front rail. The faceplate provides the capturing lip.
    bits.append(box(GL,RAIL_Y0,25.3,W-WALL-GL,RAIL_LEN,2.4))
    bits.append(box(GL,RAIL_Y0,27.7,FL-.3-GL,RAIL_LEN,2.4))
    bits.append(box(FR+.3,RAIL_Y0,27.7,W-WALL-FR-.3,RAIL_LEN,COVER_Z-27.7))
    for y in ribs_y():bits.append(rib(float(y)))
    for y in (RAIL_Y0,RAIL_Y1-.8):bits.append(box(FL-.3,y,27.7,9.6,.8,8.2))
    # SG90 ear posts, 19.2 mm wide: the cap takes the ear screw, the tunnel
    # below lets the servo lead out, leaving 6.85 mm legs either side.
    CW=9.6;hgt=SERVO_SEAT-B-2.4
    for i,y in enumerate(EAR_Y):
        bits.append(box(GX-CW,y-3.5 if i else y-3.25,B+2.4,2*CW,6.75,hgt))
    # Bosses for the four ESP32 pod screws.
    for x,y in POD_SCREWS:bits.append(cylinder(x,y,B+2.4,2.6,5))
    # Lips on the bottom wall that the faceplate hooks slide under.
    for x0,x1 in HOOKS_X:bits.append(box(x0,WALL,COVER_Z-2.0,x1-x0,1.6,2.0))
    s=join(*bits)
    holes=[]
    for x,y in MOUNTS:holes.append(cylinder(x,y,COVER_Z-6,.85,6.1))
    # Servo body relief goes through the back skin; ear height trimmed with shims.
    holes.append(box(GX-P['servo_body_window_width']/2,CY-P['servo_body_window_length']/2,B-.1,P['servo_body_window_width'],P['servo_body_window_length'],27-B))
    for y in EAR_Y:
        holes.append(slot(GX,y,SERVO_SEAT-6.2,2.6,1.7,6.3,'y'))
        holes.append(box(GX-2.75,y-4,B+2.4,5.5,8,SERVO_SEAT-6.5-B-2.4))
    holes.extend(pin_slots(B-.1,2.6))
    for x,y in POD_SCREWS:holes.append(cylinder(x,y,B-.1,.85,7))
    # Keyhole to hang the plaque.
    holes.extend([cylinder(W/2,H-12,B-.1,3.2,2.7),box(W/2-1.7,H-12,B-.1,3.4,6,2.7)])
    for a,b in P['shell_arch_left_windows_y']:
        holes.append(arch_window(a,b,-.2,'x'))
    for a,b in P['shell_arch_top_bottom_windows_x']:
        for start in (-.2,H-WALL-.2):holes.append(arch_window(a,b,start,'y'))
    # The guide wall above z=25.3 stays intact; lower openings sit between ribs.
    r=ribs_y()
    for a,b in zip(r,r[1:]):
        if b-a>5:holes.append(arch_window(float(a)+3.5,float(b)-.5,W-WALL-.2,'x',top=21))
    return cut(s,*holes)

def faceplate():
    s=rbox(0,0,COVER_Z,W,H,2.4,2.4)
    # Integral front guide lip closes the open rear rail around rack flange.
    lip=box(PX+7.25+.3,RAIL_Y0+1.1,30.9,2.4,RAIL_LEN-2.2-FACE_SLIDE-.5,COVER_Z-30.9+.02)
    # Anti-tilt journal, 0.5 mm radial clearance in x. Elongated by FACE_SLIDE in
    # y so the plate can slide down onto its hooks with the hub already inside.
    bore=P['cover_journal_bore']
    journal=slot(GX,GY-FACE_SLIDE/2,JZ0,18+FACE_SLIDE,18,COVER_Z-JZ0+.02,'y')
    journal=cut(journal,slot(GX,GY-FACE_SLIDE/2,JZ0-.1,bore+FACE_SLIDE,bore,COVER_Z-JZ0+.1+.12,'y'))
    hooks=[]
    for x0,x1 in HOOKS_X:
        hooks.append(box(x0+.5,4.3,COVER_Z-3.6,x1-x0-1,1.5,3.62))
        hooks.append(box(x0+.5,2.8,COVER_Z-3.6,x1-x0-1,1.6,1.3))
    s=join(s,lip,journal,*hooks)
    holes=[slot(AX,GY,COVER_Z-.1,T+11,6.5,2.7,'y')]
    for x,y in MOUNTS:
        holes.extend([cylinder(x,y,COVER_Z-.1,1.15,2.7),cylinder(x,y,COVER_Z+1.,2.2,1.5)])
    # Solid face, ticks only: 25% major, 10% medium, 5% minor.
    base=AX-27.9
    for q in range(0,101,5):
        y=GY-T/2+T*q/100;length=12 if q%25==0 else (8 if q%10==0 else 5)
        w=.8 if q%25==0 else .6
        holes.append(box(base-length,y-w/2,40.8,length,w,.9))
    holes.append(box(base-.6,GY-T/2-.4,40.8,.6,T+.8,.9))
    return cut(s,*holes)

HORN=P['horn']
def horn_outline(clr,z,h):
    """Cross horn: long arms along y, short arms along x, tapered with round tips."""
    parts=[cylinder(GX,GY,z,HORN['hub_d']/2+clr,h)]
    for ang,L,w1 in ((90,HORN['long_arm'],HORN['width_tip_long']),(270,HORN['long_arm'],HORN['width_tip_long']),
                     (0,HORN['short_arm'],HORN['width_tip_short']),(180,HORN['short_arm'],HORN['width_tip_short'])):
        w0=HORN['width_hub']/2+clr;r1=w1/2+clr;e=L-w1/2
        a=math.radians(ang);ux,uy=math.cos(a),math.sin(a);vx,vy=-uy,ux
        pts=[(GX+vx*w0,GY+vy*w0),(GX+ux*e+vx*r1,GY+uy*e+vy*r1),(GX+ux*e-vx*r1,GY+uy*e-vy*r1),(GX-vx*w0,GY-vy*w0)]
        parts+= [poly(pts,z,h),cylinder(GX+ux*e,GY+uy*e,z,r1,h)]
    return join(*parts)

def pinion():
    s=gear_solid(N,GX,GY,GZ,5)
    s=join(s,cylinder(GX,GY,35.55,P['gear_front_journal_diameter']/2,P['gear_front_hub_length']))
    # Through bore: room for the horn's centre screw head and a screwdriver.
    holes=[cylinder(GX,GY,GZ-.1,P['gear_center_bore']/2,8.7)]
    # Pocket follows the cross horn with 0.2 mm per side, so it cannot rock.
    hd=P['horn_pocket_depth']
    holes.extend([horn_outline(HORN['clearance'],GZ-.1,hd+.1),cylinder(GX,GY,GZ-.1,4.2,hd+.1)])
    for dx in (-7,7):
        for dy in (-7,7):
            if dx==dy:holes.append(cylinder(GX+dx,GY+dy,GZ-.1,.85,4.4))
    # Four open sectors reduce mass; keep a 3.75 mm rim, hub and four spokes.
    for k in range(4):
        angles=np.linspace(k*math.pi/2+.18,(k+1)*math.pi/2-.18,32)
        pts=[(GX+32*math.cos(a),GY+32*math.sin(a)) for a in angles]
        pts += [(GX+14.5*math.cos(a),GY+14.5*math.sin(a)) for a in angles[::-1]]
        holes.append(poly(pts,GZ-.1,5.2))
    return cut(s,*holes)

def keeper():
    s=cut(cylinder(GX,GY,28.6,14,2),cylinder(GX,GY,28.5,6.2,2.2))
    return cut(s,*[cylinder(GX+d,GY+d,28.5,1.15,2.2) for d in (-7,7)])  # 2 diagonal screws

def rack():
    s=join(poly(rack_profile()[0],GZ,5),box(FL,RB,28,9,L,2.6))
    # Neck runs through the arrow, which is a press fit (no screw).
    return join(s,box(AX-2,GY-3,35.55,4,6,10.3))

def arrow():
    # Long arrow: tip reaches 2 mm over the tick baseline, tail past the neck.
    tip=AX-29.9;hb=AX-16.9
    pts=[(tip,GY),(hb,GY-6),(hb,GY-4.5),(AX+7,GY-4.5),(AX+7,GY+4.5),(hb,GY+4.5),(hb,GY+6)]
    s=poly(pts,43.7,2.4)
    # Press fit onto the 4 x 6 neck; a drop of glue if the print is loose.
    return cut(s,box(AX-2.075,GY-3.075,43.6,4.15,6.15,2.6))

def pod_base():
    """ESP32 tray on the case back: floor with header slots, standoffs on the
    board's 3 mm holes (2 locating pins + 2 through-screws into the case),
    walls with lid grooves, and a USB-C side opening."""
    top=B-POD_FLOOR
    floor=rbox(IX0-2,IY0-3,top,IX1-IX0+4,IY1-IY0+6,POD_FLOOR,2)
    long_walls=[box(IX0-2,y,WALL_TOP,IX1-IX0+4,3,top-WALL_TOP) for y in (IY0-3,IY1)]
    usb_wall=box(IX0-2,IY0,WALL_TOP,2,IY1-IY0,top-WALL_TOP)
    end_wall=box(IX1,IY0,LID_IN+.15,2,IY1-IY0,top-LID_IN-.15)
    s=join(floor,*long_walls,usb_wall,end_wall,*[cylinder(x,y,PCB_Z0,2.0,STANDOFF) for x,y in HOLES],
           *[cylinder(x,y,PCB_Z0-1.4,1.3,1.42) for x,y in POD_PINS])
    holes=pin_slots(top-.1,POD_FLOOR+.2)
    holes+=[cylinder(x,y,PCB_Z0-.1,1.15,STANDOFF+POD_FLOOR+.2) for x,y in POD_SCREWS]
    # Lid groove: long walls and the USB-end wall; open at the antenna end.
    holes.append(box(IX0-GROOVE,IY0-GROOVE,LID_IN-LID_T-.15,IX1+2.1-(IX0-GROOVE),IY1-IY0+2*GROOVE,LID_T+.3))
    # USB-C plug opening through the USB-end wall, from PCB level up to the lid.
    holes.append(box(IX0-2.1,BYC-6.5,LID_IN-.1,2.3,13,PCB_Z0-LID_IN+.6))
    return cut(s,*holes)

def pod_lid():
    g=GROOVE-LID_CLR
    s=box(IX0-g,IY0-g,LID_IN-LID_T,IX1+2-(IX0-g),IY1-IY0+2*g,LID_T)
    # Detent bump just inside the low end wall: clicks past its edge.
    s=join(s,box(IX1-1.2,BYC-5,LID_IN-.01,.9,10,.41))
    # Opening over the USB end: plug clearance plus the EN/BOOT buttons.
    return cut(s,box(IX0-g-.1,BYC-12.5,LID_IN-LID_T-.1,g+.1+9,25,LID_T+.2))

def ear_shim(t,y):
    # Under one SG90 ear; inner edge stops 0.25 mm short of a 23 mm body end.
    y0=y-2.0 if y>CY else y-3.0
    return cut(box(GX-3,y0,SERVO_SEAT,6,5,t),cylinder(GX,y,SERVO_SEAT-.1,1.2,t+.2))

def refs():
    # Nominal envelopes, not scanned models.
    bl=SG['body_length'];bw=SG['body_width']
    ear_z=SERVO_SEAT+P['servo_nominal_shim'];base=ear_z-SG['ear_bottom_from_base']
    top=base+SG['case_height'];tower_top=GZ-SG['shaft_exposed']
    sg=join(box(GX-bw/2,CY-bl/2,base,bw,bl,SG['case_height']),
            box(GX-bw/2,CY-SG['ear_span']/2,ear_z,bw,SG['ear_span'],SG['ear_thickness']),
            cylinder(GX,GY,top-.01,SG['tower_radius'],tower_top-top+.01),cylinder(GX,GY,tower_top-.01,2.4,GZ-tower_top+.01))
    sg=cut(sg,*[cylinder(GX,y,ear_z-.1,1.1,SG['ear_thickness']+.2) for y in EAR_Y])
    # Ear screw heads and the small second gear boss on the SG90 top.
    sg=join(sg,*[cylinder(GX,y,ear_z+SG['ear_thickness']-.01,1.9,2.01) for y in EAR_Y],
            cylinder(GX,GY+6.5,top-.01,3.0,2.51))
    shims=join(*[ear_shim(P['servo_nominal_shim'],y) for y in EAR_Y])
    # Horn hub is a socket over the spline, so it is hollow below GZ.
    # Cross horn; hub is a hollow socket over the spline below GZ.
    hz=GZ-HORN['hub_below_arm']
    horn=join(horn_outline(0,GZ,HORN['thickness']),cylinder(GX,GY,hz,HORN['hub_d']/2,GZ-hz+HORN['thickness']))
    horn=cut(horn,cylinder(GX,GY,hz-.1,2.45,GZ-hz+.1),cylinder(GX,GY,GZ-.2,1.1,3))
    # ESP32 behind the case: component side faces back, header pins into the case.
    pcb=cut(box(BX0,BY0,PCB_Z0-E['pcb_thickness'],E['pcb_length'],E['pcb_width'],E['pcb_thickness']),
            *[cylinder(x,y,PCB_Z0-2,E['hole_diameter']/2,3) for x,y in HOLES])
    comp=box(BX0+8,BY0+3,PCB_Z0-E['pcb_thickness']-E['component_height'],E['pcb_length']-9,E['pcb_width']-6,E['component_height'])
    usb=box(BX0-.5,BYC-4.5,PCB_Z0-E['pcb_thickness']-3.3,7.5,9,3.3)
    xs=BXC-1.5-19.05  # rows assumed shifted 1.5 mm towards the USB end
    pins=[]
    for y in ROWS:
        pins.append(box(xs,y-1.27,PCB_Z0,38.1,2.54,STANDOFF))
        for i in range(15):pins.append(box(xs+.95+2.54*i,y-.32,B-POD_FLOOR,.64,.64,E['pin_length_below_plastic']))
    headers=join(*pins)
    # 3 Dupont housings (3V3, GND, D13 near the USB end) and their wire bend.
    dupont=join(box(xs,ROWS[0]-1.27,B-POD_FLOOR,2.54,2.54,18),box(xs+2.54,ROWS[1]-1.27,B-POD_FLOOR,5.08,2.54,18))
    screw=cylinder(GX,GY,GZ+HORN['thickness'],HORN['center_screw_head_d']/2,HORN['center_screw_head_h'])
    return {'REF_SG90':sg,'REF_EAR_SHIMS':shims,'REF_HORN':horn,'REF_HORN_SCREW':screw,'REF_PCB':pcb,'REF_COMPONENTS':comp,
            'REF_USB':usb,'REF_HEADERS':headers,'REF_DUPONT_ENVELOPE':dupont}

PARTS={};MECH={}
def export_part(name,cn,shape,orientation=None,group='static',note='',main=True):
    shape=shape.clean()
    assert shape.isValid() and len(shape.Solids())==1,('invalid solid',name)
    MECH[name]=shape
    shape=shape.translate((0,0,DZ))
    pr=shape
    if orientation:pr=pr.rotate((0,0,0),orientation[0],orientation[1])
    b=pr.BoundingBox();pr=pr.translate((-b.xmin,-b.ymin,-b.zmin))
    cq.exporters.export(pr,str(STL/(name+'.stl')),tolerance=.03,angularTolerance=.1)
    cq.exporters.export(shape,str(CAD/(name+'.step')))
    cq.exporters.export(shape,str(CACHE/(name+'_assembly.stl')),tolerance=.1,angularTolerance=.2)
    PARTS[name]={'shape':shape,'name_zh':cn,'group':group,'main':main,'note':note,'print_bbox_mm':[b.xlen,b.ylen,b.zlen]}
    print('BUILT',name,cn,flush=True)

def build():
    export_part('01_plaque_back','后壳、一体导轨及SG90安装座',housing(),note='背面朝下；侧窗为45度自承拱顶；需要≥215 mm的打印平台。')
    export_part('02_front','实心刻度面板及防脱导向唇',faceplate(),orientation=((1,0,0),180),note='正面朝热床，内侧导向唇朝上。')
    export_part('03_pinion_74T','直驱74齿齿轮',pinion(),group='rotary',note='背面舵盘槽朝下。')
    export_part('04_horn_keeper','原装舵盘压盖',keeper(),group='rotary',note='平放，4颗M2x6从背面拧入齿轮。')
    export_part('05_rack_slider','齿条与滑块（100 mm）',rack(),group='linear',note='背面凸缘朝热床，指针颈朝上。')
    export_part('06_arrow','大箭头',arrow(),orientation=((1,0,0),180),group='linear',note='箭头正面朝下；M2x6。')
    export_part('07_pod_base','ESP32背仓底座',pod_base(),orientation=((1,0,0),180),note='贴壳面朝热床，立柱朝上。')
    export_part('08_pod_lid','ESP32背仓盖板',pod_lid(),note='平放。')
    section=box(GL-.1,GY-8,25.3,W-GL,16,14)
    export_part('T1_guide_sample','导轨试配片',housing().intersect(section).clean(),main=False)
    export_part('T2_slider_sample','滑块试配片',rack().intersect(box(PX-2,RB+20,27.9,15,14,8)).clean(),main=False)
    coupon=cut(box(0,0,0,34,18,5),cylinder(8,8,-.1,.85,5.2),cylinder(25,8,-.1,P['cover_journal_bore']/2,5.2))
    export_part('T3_pilot_and_journal','M2底孔与前导向孔试配片',coupon,main=False)
    # Horn fit coupon: the exact gear pocket and keeper screw holes, 10 min print.
    hc=cut(cylinder(GX,GY,GZ,19,3.4),horn_outline(HORN['clearance'],GZ-.1,P['horn_pocket_depth']+.1),
           cylinder(GX,GY,GZ-.1,4.2,P['horn_pocket_depth']+.1),cylinder(GX,GY,GZ-.1,2.8,3.6),
           *[cylinder(GX+d,GY+d,GZ-.1,.85,3.6) for d in (-7,7)])
    export_part('T5_horn_fit','十字舵盘槽试配片',hc,main=False)
    lip=faceplate().intersect(box(PX+7.25,GY-8,30.8,6,16,11)).clean()
    export_part('T4_front_lip_sample','前面板防脱唇试配片',lip,orientation=((1,0,0),180),main=False)
    for thick in (.4,.8):
        cq.exporters.export(box(0,0,0,6.4,7,thick),str(STL/f'optional_horn_spacer_{thick:.1f}mm.stl'))
    for thick in P['servo_shim_options']:
        if thick<=0:continue
        s=ear_shim(thick,EAR_Y[1]);b=s.BoundingBox()
        cq.exporters.export(s.translate((-b.xmin,-b.ymin,-b.zmin)),str(STL/f'S_servo_ear_shim_{thick:.1f}mm_print2.stl'))
    hardware={n:s.translate((0,0,DZ)) for n,s in refs().items()}
    assy=cq.Assembly(name='MechanicalGaugeV5')
    for n,o in PARTS.items():
        if o['main']:assy.add(o['shape'],name=n,color=cq.Color(.78,.79,.78))
    for n,s in hardware.items():
        assy.add(s,name=n,color=cq.Color(.42,.45,.43))
        cq.exporters.export(s,str(CACHE/(n+'_assembly.stl')),tolerance=.1,angularTolerance=.2)
    assy.export(str(CAD/'V5_full_assembly.step'))
    report=[]
    for n,o in PARTS.items():
        mesh=trimesh.load(STL/(n+'.stl'),force='mesh')
        r={k:v for k,v in o.items() if k!='shape'}
        r.update({'id':n,'watertight':bool(mesh.is_watertight),'consistent_winding':bool(mesh.is_winding_consistent),'connected_bodies':len(mesh.split()),'volume_mm3':float(mesh.volume),'sha256':hashlib.sha256((STL/(n+'.stl')).read_bytes()).hexdigest()})
        r['pass']=r['watertight'] and r['consistent_winding'] and r['connected_bodies']==1 and r['volume_mm3']>0
        assert r['pass'],r
        report.append(r)
    (CHECK/'mesh_report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print('PRINTED VOLUME',sum(r['volume_mm3'] for r in report if r['main']),flush=True)

def verify_profiles():
    gp=Polygon(gear_points(N));rp=Polygon(rack_profile()[0]);worst=0.
    for q in np.linspace(0,100,501):
        dy=(q-50)*T/100
        a=translate(rotate(gp,dy/R,origin=(0,0),use_radians=True),GX,GY)
        b=translate(rp,0,dy);worst=max(worst,a.intersection(b).area)
    half=math.degrees(T/R)/2;center=P['servo_nominal_center_deg'];avail=P['servo_available_travel_deg']
    r={'samples':501,'max_tooth_overlap_mm2':worst,'pass':worst<1e-5,'stroke_mm':T,
       'servo_sweep_deg':math.degrees(T/R),'servo_working_angles_nominal_deg':[center-half,center+half],
       'servo_end_reserve_nominal_deg':[center-half,avail-center-half],
       'pointer_y_range_mm':[GY-T/2,GY+T/2],'rack_swept_y_mm':[RB-T/2,RB+L+T/2],'rail_y_mm':[RAIL_Y0,RAIL_Y1],
       'rack_end_margin_mm':(RB-T/2)-(RAIL_Y0+.8),'external_case_mm':[W,H,P['case_depth']],
       'with_arrow_mm':[W,H,P['case_depth']+4.8],'with_pod_mm':[W,H,P['case_depth']+4.8+(B-WALL_TOP)],
       'pod_depth_behind_case_mm':B-WALL_TOP,'gear_tip_to_left_wall_mm':GX-R-M-WALL,
       'notes':['Nominal geometric checks; ESP32 header row position along the board is assumed, slots leave margin.']}
    assert min(r['servo_end_reserve_nominal_deg'])>0 and r['rack_end_margin_mm']>1
    (CHECK/'kinematics.json').write_text(json.dumps(r,ensure_ascii=False,indent=2));print('KINEMATICS',json.dumps(r),flush=True)
    assert r['pass']

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--skip-profiles',action='store_true');args=ap.parse_args()
    build()
    if not args.skip_profiles:verify_profiles()
