#!/usr/bin/env python3
"""Interference check of the V4 assembly at several pointer positions.
Run after build_v4.py; imports it to rebuild the shapes in mechanism frame.
"""
import json, math, itertools
import build_v5 as m

def main():
    parts={'01':m.housing(),'02':m.faceplate(),'03':m.pinion(),'04':m.keeper(),
           '05':m.rack(),'06':m.arrow(),'07':m.pod_base(),'08':m.pod_lid()}
    parts.update(m.refs())
    rotary={'03','04','REF_HORN'};linear={'05','06'}
    # Rack teeth vs gear teeth are checked as 2D profiles in verify_profiles().
    skip={frozenset(p) for p in [('03','05'),('REF_SG90','REF_HORN'),('03','REF_HORN'),
          ('04','REF_HORN'),('01','REF_EAR_SHIMS'),('REF_SG90','REF_EAR_SHIMS'),
          ('REF_PCB','REF_COMPONENTS'),('REF_PCB','REF_HEADERS'),('REF_HEADERS','REF_DUPONT_ENVELOPE'),
          ('REF_PCB','REF_USB'),('REF_HORN','REF_HORN_SCREW'),('REF_COMPONENTS','REF_USB'),('07','REF_PCB'),('07','REF_HEADERS'),('01','07')]}
    out={'poses_percent':[],'collisions':[],'skipped_pairs_contact_by_design':sorted('-'.join(sorted(p)) for p in skip)}
    for q in (0,25,50,75,100):
        dy=(q-50)*m.T/100;ang=math.degrees(dy/m.R)
        posed={}
        for n,s in parts.items():
            if n in rotary:s=s.rotate((m.GX,m.GY,0),(m.GX,m.GY,1),ang)
            elif n in linear:s=s.translate((0,dy,0))
            posed[n]=s
        for a,b in itertools.combinations(posed,2):
            if frozenset((a,b)) in skip:continue
            ba,bb=posed[a].BoundingBox(),posed[b].BoundingBox()
            if ba.xmax<bb.xmin or bb.xmax<ba.xmin or ba.ymax<bb.ymin or bb.ymax<ba.ymin or ba.zmax<bb.zmin or bb.zmax<ba.zmin:continue
            v=posed[a].intersect(posed[b]).Volume()
            if v>1e-3:out['collisions'].append({'pose':q,'a':a,'b':b,'mm3':round(v,4)})
        out['poses_percent'].append(q);print('pose',q,'done',flush=True)
    # Shaft-top-to-gear and hub-to-faceplate clearances for the nominal stack.
    out['gear_face_to_cover_boss_mm']=round(m.JZ0-(m.GZ+5),3)
    out['hub_end_to_bore_bottom_mm']=round(m.COVER_Z+.12-(35.55+m.P['gear_front_hub_length']),3)
    out['hub_radial_clearance_mm']=round((m.P['cover_journal_bore']-m.P['gear_front_journal_diameter'])/2,3)
    out['pass']=not out['collisions']
    (m.CHECK/'V5_interference.json').write_text(json.dumps(out,ensure_ascii=False,indent=2))
    print(json.dumps(out,ensure_ascii=False,indent=2))

if __name__=='__main__':main()
