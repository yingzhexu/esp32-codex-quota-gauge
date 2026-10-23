#!/usr/bin/env python3
"""Assembly-path test for V5: each step pulls the moving parts out along their
insertion direction (0.3..40 mm) and checks them against everything already
installed. A clean step means the part can be put in by a straight push.
"""
import json
import numpy as np
import build_v5 as m

def main():
    p={'01':m.housing(),'02':m.faceplate(),'03':m.pinion(),'04':m.keeper(),'05':m.rack(),
       '06':m.arrow(),'07':m.pod_base(),'08':m.pod_lid()}
    p.update(m.refs())
    board=['REF_PCB','REF_HEADERS','REF_COMPONENTS','REF_USB','REF_DUPONT_ENVELOPE']
    # (step, moving parts, direction, installed parts, start offset, max travel)
    Z=(0,0,0)
    steps=[
        ('舵机放入安装座（从正面放入）',['REF_SG90'],(0,0,1),['01','REF_EAR_SHIMS'],Z,40),
        ('背仓底座贴到后壳背面',['07'],(0,0,-1),['01','REF_SG90'],Z,40),
        ('ESP32 插好杜邦线后，排针穿过长槽装进背仓',board,(0,0,-1),['01','07','REF_SG90'],Z,40),
        ('背仓盖板沿导槽从天线端推入',['08'],(1,0,0),['01','07']+board,Z,70),
        ('齿条从正面放进导轨',['05'],(0,0,1),['01','REF_SG90']+board,Z,40),
        ('齿轮+舵盘+压盖套上舵机轴',['03','04','REF_HORN'],(0,0,1),['01','05','REF_SG90','REF_EAR_SHIMS']+board,Z,40),
        ('面板抬高 3.5 mm 放下（挂钩避开卡槽）',['02'],(0,0,1),['01','03','04','05','REF_SG90','REF_HORN']+board,(0,m.FACE_SLIDE,0),40),
        ('面板向下推 3.5 mm，挂钩卡进卡槽',['02'],(0,1,0),['01','03','04','05','REF_SG90','REF_HORN']+board,Z,m.FACE_SLIDE),
        ('箭头压到指针颈上',['06'],(0,0,1),['01','02','05'],Z,40),
    ]
    out=[];ok=True
    for name,moving,d,fixed,start,travel in steps:
        hits=[]
        for off in np.linspace(.3,travel,9):
            for a in moving:
                s=p[a].translate(tuple(np.array(start)+off*np.array(d)))
                for b in fixed:
                    v=s.intersect(p[b]).Volume()
                    if v>1e-3:hits.append({'offset_mm':round(float(off),1),'moving':a,'hits':b,'mm3':round(v,3)})
        out.append({'step':name,'direction':d,'start_offset':start,'pass':not hits,'collisions':hits[:10]})
        ok&=not hits
        print(('✅ ' if not hits else '❌ ')+name,(hits[:3] if hits else ''),flush=True)
    res={'steps':out,'pass':ok,'method':'Exact B-rep Boolean volume at 9 offsets per step along the insertion direction.'}
    (m.CHECK/'V5_assembly_path.json').write_text(json.dumps(res,ensure_ascii=False,indent=2))

if __name__=='__main__':main()
