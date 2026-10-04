"""Extend existing runway light rows; preserve taxi lights and endpoint insets."""
import math
from statistics import median

from runway_patch_core import world_to_local


ROWS={'Cole main 11/29':[35269,35425],'Cole secondary':[35290],
      'Sakhet 08/26':[83493],'Mantaruun':[86211,86244]}


def extend_lights(field,patch,row,sign):
    def project(p):
        return [sum((p[i]-row['center'][i])*row[k][i] for i in range(2)) for k in ('u','v')]
    def text(primitive,p):
        pos=primitive['pos']
        x,z=world_to_local(pos[0],pos[2],pos[3],*p)
        return f'VER {x:.6f} {z:.6f}'
    primitives={p['draw_line']:p for p in field.primitives}
    if row['name']=='Dirt Strip':
        p=primitives[87222]
        points=[[q[i]+(sign*row['u'][i]*200 if sign*project(q)[0]>0 else 0)
                 for i in range(2)] for q in p['points']]
        lines=[n for n in range(p['draw_line'],p['draw_end']) if patch.lines[n-1].startswith('VER ')]
        for n,q in zip(lines,points):patch.replace(n,text(p,q))
        patch.expected_points[p['draw_line']]=points
        return dict(endpoint_points_moved=2,added_edge_points=0)
    if row['name'] not in ROWS:
        return dict(endpoint_points_moved=0,added_edge_points=0)
    groups=[primitives[n] for n in ROWS[row['name']]]
    records=[]
    for p in groups:
        lines=[n for n in range(p['draw_line'],p['draw_end']) if patch.lines[n-1].startswith('VER ')]
        for index,(line,q) in enumerate(zip(lines,p['points'])):
            s,t=project(q)
            if abs(abs(t)-row['safe_width']/2)<3:
                records.append((s,t,q,p,line,index))
    added=moved=0
    expected={p['draw_line']:[list(q) for q in p['points']] for p in groups}
    for side in (-1,1):
        points=sorted([r for r in records if side*r[1]>0],key=lambda r:sign*r[0])
        if len(points)<2:raise ValueError('Insufficient light row')
        distances=[sign*(b[0]-a[0]) for a,b in zip(points,points[1:])]
        pitch=median(d for d in distances if d>40)
        endpoint=points[-1]
        # Mantaruun's south last light is at its retained taxi junction, not an end bar.
        movable=row['name']!='Mantaruun' or sign*endpoint[0]>row['safe_length']/2-5
        limit=sign*endpoint[0]+200 if movable else row['safe_length']/2+200
        start=points[-2] if movable else endpoint
        if movable:
            q=[endpoint[2][i]+sign*row['u'][i]*200 for i in range(2)]
            patch.replace(endpoint[4],text(endpoint[3],q))
            expected[endpoint[3]['draw_line']][endpoint[5]]=q
            moved+=1
        count=math.ceil((limit-sign*start[0])/pitch)
        # Equal intervals keep the endpoint light and avoid an unusually short last gap.
        for k in range(1,count+(0 if movable else 1)):
            distance=(limit-sign*start[0])*k/count
            q=[start[2][i]+sign*row['u'][i]*distance for i in range(2)]
            patch.insert(start[3]['draw_end']-1,[text(start[3],q)])
            added+=1
    patch.expected_points.update(expected)
    return dict(endpoint_points_moved=moved,added_edge_points=added)
