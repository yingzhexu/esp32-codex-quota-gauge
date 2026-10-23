#!/usr/bin/env python3
"""Rotation sweep: gear + horn + keeper (with its screw heads) turn through the
whole servo working range plus 5 degrees each side, the rack and arrow follow.
Every pose is checked against the servo (body, top boss, ear screw heads),
shims, housing, faceplate and the ESP32 envelopes.
"""
import json, math
import numpy as np
import build_v5 as m

def main():
    p={'01':m.housing(),'02':m.faceplate(),'03':m.pinion(),'04':m.keeper(),'05':m.rack(),'06':m.arrow()}
    p.update(m.refs())
    # Keeper screw heads (M2, 4 mm x 2 mm) on the servo side of the keeper.
    heads=m.join(*[m.cylinder(m.GX+d,m.GY+d,28.6-2,2.0,2.0) for d in (-7,7)])
    rotary={'03':p['03'],'04':p['04'],'REF_HORN':p['REF_HORN'],'REF_HORN_SCREW':p['REF_HORN_SCREW'],'KEEPER_SCREW_HEADS':heads}
    linear={'05':p['05'],'06':p['06']}
    fixed=['01','02','REF_SG90','REF_EAR_SHIMS','REF_PCB','REF_HEADERS','REF_DUPONT_ENVELOPE']
    half=math.degrees(m.T/m.R)/2+5
    hits=[];angles=np.linspace(-half,half,31)
    for ang in angles:
        dy=math.radians(ang)*m.R
        moving={n:s.rotate((m.GX,m.GY,0),(m.GX,m.GY,1),ang) for n,s in rotary.items()}
        # Rack and arrow only inside the working stroke; beyond it the end stops act.
        if abs(ang)<=half-5+1e-6:moving.update({n:s.translate((0,dy,0)) for n,s in linear.items()})
        for a,s in moving.items():
            for b in fixed:
                v=s.intersect(p[b]).Volume()
                if v>1e-3:hits.append({'deg':round(float(ang),1),'moving':a,'hits':b,'mm3':round(v,3)})
    # Minimum axial gaps around the rotating stack (nominal).
    head_vs_gear=p['REF_HORN_SCREW'].intersect(p['03']).Volume()
    if head_vs_gear>1e-3:hits.append({'deg':0,'moving':'REF_HORN_SCREW','hits':'03','mm3':round(head_vs_gear,3)})
    res={'angles_deg':[round(float(a),1) for a in angles],'checked_against':fixed,'collisions':hits,'pass':not hits,
         'keeper_screw_heads_above_servo_top_mm':round(26.6-(m.SERVO_SEAT+m.P['servo_nominal_shim']-m.SG['ear_bottom_from_base']+m.SG['case_height']+2.5),2),
         'keeper_screw_heads_above_ear_screw_heads_mm':round(26.6-(m.SERVO_SEAT+m.P['servo_nominal_shim']+m.SG['ear_thickness']+2.0),2),
         'horn_hub_above_servo_tower_mm':round((m.GZ-m.HORN['hub_below_arm'])-(m.GZ-m.SG['shaft_exposed']),2)}
    (m.CHECK/'V5_rotation_sweep.json').write_text(json.dumps(res,ensure_ascii=False,indent=2))
    print(json.dumps({k:v for k,v in res.items() if k!='angles_deg'},ensure_ascii=False,indent=1))

if __name__=='__main__':main()
