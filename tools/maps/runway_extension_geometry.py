"""Move runway endpoints and hand-drawn end packages in their actual world frame."""
import math
from statistics import median

from runway_patch_core import world_to_local
from runway_extension_lights import extend_lights


CENTRELINES={'Cole main 11/29':32344,'Cole secondary':32967,'Baluut':36639,
             'Sakhet 08/26':82155,'Mantaruun':85767}
MARK_PACKS={'Cole main 11/29':['00000033.pc2','00000034.pc2'],
            'Cole secondary':['00000027.pc2','00000028.pc2'],
            'Baluut':['00000038.pc2','00000041.pc2'],
            'Mantaruun':['00000094.pc2','00000095.pc2']}
EXPLICIT={'Cole main 11/29':[32487,32494,33232,33241,33250,33259,33268,33277,33284,33323,33370],
          'Cole secondary':[31720,32540,33377],
          'Baluut':[36414,36714,36783], 'Dirt Strip':[87125]}
HALF_PACK={'Sakhet 08/26':'00000087.pc2','Mantaruun':'00000098.pc2'}


def project(row, point):
    return [sum((point[i]-row['center'][i])*row[k][i] for i in range(2)) for k in ('u','v')]


def vertex_lines(patch, primitive):
    return [n for n in range(primitive['draw_line'],primitive['draw_end'])
            if patch.lines[n-1].startswith('VER ')]


def local_text(primitive, point):
    pos=primitive['pos']
    x,z=world_to_local(pos[0],pos[2],pos[3],*point)
    return f'VER {x:.6f} {z:.6f}'


def edit_points(patch, primitive, points):
    for line,point in zip(vertex_lines(patch,primitive),points):
        patch.replace(line,local_text(primitive,point))
    patch.expected_points[primitive['draw_line']]=points


def move_primitive(patch, primitive, delta):
    edit_points(patch,primitive,[[p[i]+delta[i] for i in range(2)] for p in primitive['points']])


def extend_region(field, patch, row, delta):
    r=next(r for r in field.regions if r['line']==row['region_line'])
    lines=range(r['line']+1,r['line']+15)
    are_line=next(n for n in lines if patch.lines[n-1].startswith('ARE '))
    pos_line=next(n for n in lines if patch.lines[n-1].startswith('POS '))
    a=list(r['are'])
    axis=0 if a[2]-a[0]>a[3]-a[1] else 1
    a[axis]-=100
    a[axis+2]+=100
    patch.replace(are_line,'ARE '+' '.join(f'{v:.6f}' for v in a))
    # RGN POS is in the parent field frame; its own heading only rotates ARE.
    parent=next(p for p in field.instances if p['kind']=='FLD' and p['file']==r['source'])
    h=parent['pos'][3]*math.tau/65536
    dx=(math.cos(h)*delta[0]+math.sin(h)*delta[1])/2
    dz=(-math.sin(h)*delta[0]+math.cos(h)*delta[1])/2
    parts=patch.lines[pos_line-1].split()
    parts[1]=f'{float(parts[1])+dx:.6f}'
    parts[3]=f'{float(parts[3])+dz:.6f}'
    patch.replace(pos_line,' '.join(parts))


def add_dashes(patch, primitive, row, sign):
    quads=[primitive['points'][i:i+4] for i in range(0,len(primitive['points']),4)]
    ordered=sorted(quads,key=lambda q:sign*sum(project(row,p)[0] for p in q)/4)
    centers=[sign*sum(project(row,p)[0] for p in q)/4 for q in ordered]
    pitch=median(b-a for a,b in zip(centers,centers[1:]))
    template=ordered[-1]
    # Preserve the original number-to-last-dash clearance. The added end moves 200 m.
    new_end=centers[-1]+200
    added=[]
    for k in range(1,math.floor(200/pitch)+1):
        if centers[-1]+k*pitch>new_end+.001:
            break
        delta=[sign*x*k*pitch for x in row['u']]
        added.extend(local_text(primitive,[p[i]+delta[i] for i in range(2)]) for p in template)
    patch.insert(primitive['draw_end']-1,added)
    return dict(added_dashes=len(added)//4,pitch_m=pitch)


def extend_strip(field,patch,row,sign):
    delta=[sign*x*200 for x in row['u']]
    primitives={p['draw_line']:p for p in field.primitives}
    core=primitives[row['drawing_line']]
    edit_points(patch,core,[[p[i]+(delta[i] if sign*project(row,p)[0]>0 else 0)
                           for i in range(2)] for p in core['points']])
    if row['name']=='Sakhet 08/26':
        # Two gradient strips shade the pavement; stretch their selected end too.
        for line in (82116,82126):
            p=primitives[line]
            edit_points(patch,p,[[q[i]+(delta[i] if sign*project(row,q)[0]>0 else 0)
                                 for i in range(2)] for q in p['points']])
    extend_region(field,patch,row,delta)
    chosen=set(EXPLICIT.get(row['name'],[]))
    for p in field.primitives:
        if p['file'] in MARK_PACKS.get(row['name'],[]):
            chosen.add(p['draw_line'])
        if p['file']==HALF_PACK.get(row['name']) and p['draw_line']!=CENTRELINES.get(row['name']):
            if min(sign*project(row,q)[0] for q in p['points'])>0:
                chosen.add(p['draw_line'])
    for line in sorted(chosen):
        move_primitive(patch,primitives[line],delta)
    dashes={}
    if row['name'] in CENTRELINES:
        dashes=add_dashes(patch,primitives[CENTRELINES[row['name']]],row,sign)
    lights=extend_lights(field,patch,row,sign)
    return dict(name=row['name'],delta=delta,end_drawings_moved=sorted(chosen),
                centreline=dashes,lights=lights)
