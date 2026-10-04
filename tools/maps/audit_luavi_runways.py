"""Measure independent RGN/PC2 geometry and screen both runway ends.

Usage: python tools/maps/audit_luavi_runways.py --deps crashlog/runway_audit/deps
Dependencies: tools/maps/requirements-runway-audit.txt. Outputs are read-only
analysis artifacts; no FLD, STP, ILS or AI-plan data is changed.
"""
import argparse
import csv
import hashlib
import json
import math
import sys
from pathlib import Path


# Independently identified from runway starts/ILS, dimensions and drawings.
# Anchors are source lines in the inspected Luavi revision, never all ID-1 roads.
RUNWAYS = [
    ('Cole main 11/29',35636,32202),
    ('Cole secondary',35861,31706),
    ('Baluut',36863,36393),
    ('Sakhet 08/26',84092,81731),
    ('Mantaruun',86465,84825),
    ('Dirt Strip',87292,87118),
    ('Highway Strip',41392,3658),
]


def projected(points, center, u, v):
    return [[(p[0]-center[0])*u[0]+(p[1]-center[1])*u[1],
             (p[0]-center[0])*v[0]+(p[1]-center[1])*v[1]] for p in points]


def clean(value):
    if isinstance(value,dict):
        return {k:clean(v) for k,v in value.items() if not k.startswith('_')}
    if isinstance(value,list):
        return [clean(v) for v in value]
    return value


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fld',type=Path,default=Path('godot_project/user/RvB/ww3/Luavi.fld'))
    parser.add_argument('--out',type=Path,default=Path('crashlog/runway_audit'))
    parser.add_argument('--deps',type=Path)
    parser.add_argument('--corridor-length',type=float,default=1000)
    parser.add_argument('--no-plots',action='store_true')
    parser.add_argument('--anchors',type=Path,help='Runway source anchors after a reviewed map patch')
    args=parser.parse_args()
    if args.deps:
        sys.path.insert(0,str(args.deps.resolve()))
    from shapely.geometry import Point, Polygon
    from shapely.geometry import LineString
    from shapely.ops import unary_union
    from fld_geometry import FieldGeometry, polygons
    from runway_constraints import polygon, ground_footprints, terrain_faces, land_geometry, screen
    from plot_runway_audit import draw

    args.out.mkdir(parents=True,exist_ok=True)
    field=FieldGeometry(args.fld)
    ground, missing=ground_footprints(field,Path('godot_project'))
    terrain, land=terrain_faces(field),land_geometry(field)
    rows=[]
    runways=RUNWAYS
    patch_manifest=Path('planning/data/luavi_runway_extension.json')
    if not args.anchors and patch_manifest.exists():
        extension=json.loads(patch_manifest.read_text(encoding='utf-8'))
        raw=args.fld.read_bytes()
        matches=hashlib.sha256(raw).hexdigest()==extension['output_hash']
        if extension.get('output_lf_hash'):
            matches=matches or hashlib.sha256(raw.replace(b'\r\n',b'\n')).hexdigest()==extension['output_lf_hash']
        if matches:
            runways=[(r['name'],r['region_line'],r['drawing_line']) for r in extension['anchors']]
    if args.anchors:
        runways=[(r['name'],r['region_line'],r['drawing_line']) for r in
                 json.loads(args.anchors.read_text(encoding='utf-8'))]
    for name, rline, dline in runways:
        region=next(r for r in field.regions if r['line']==rline)
        drawing=next(d for d in field.primitives if d['draw_line']==dline)
        rp=polygon(region['points'])
        # Highway is one quad within a continuous road strip, not its whole PC2.
        vp=max((polygon(p) for p in polygons(drawing)),key=lambda p:p.intersection(rp).area)
        if vp.intersection(rp).area/rp.area<.8:
            raise ValueError(f'Runway source anchor no longer matches: {name}')
        verts=list(vp.exterior.coords)[:-1]
        edges=[(math.dist(a,b),a,b) for a,b in zip(verts,verts[1:]+verts[:1])]
        length,a,b=max(edges)
        u=[(b[i]-a[i])/length for i in range(2)]
        if u[0]<0:
            u=[-x for x in u]
        v=[-u[1],u[0]]
        c=[rp.centroid.x,rp.centroid.y]
        local=projected(verts,c,u,v)
        vl=[min(p[0] for p in local),max(p[0] for p in local)]
        vw=[min(p[1] for p in local),max(p[1] for p in local)]
        dims=sorted([region['are'][2]-region['are'][0],region['are'][3]-region['are'][1]],reverse=True)
        row=dict(name=name,source=region['source'],region_line=rline,pc2=drawing['file'],
            drawing_line=dline,primitive=drawing['primitive'],center=c,u=u,v=v,
            safe_length=dims[0],safe_width=dims[1],visual_length=length,
            visual_width=vw[1]-vw[0],visual_axis_extent=vl,
            length_difference=length-dims[0],lateral_offset=(vw[0]+vw[1])/2,
            safe_covered_percent=100*vp.intersection(rp).area/rp.area,
            visual_safe_percent=100*vp.intersection(rp).area/vp.area,
            outline_max_difference=vp.hausdorff_distance(rp),
            point_drawing_files=sorted({d['file'] for d in field.primitives
                if d['source']==region['source'] and d['primitive'] in {'PST','APL'}}),
            _region=rp,_paint=vp,ends=[],markings=[])
        composite=unary_union([polygon(face) for d in field.primitives
            if d['source']==region['source'] and d['color']==drawing['color']
            for face in polygons(d)])
        row['composite_safe_covered_percent']=100*composite.intersection(rp).area/rp.area
        centerline=LineString([[c[i]+u[i]*s for i in range(2)] for s in [-dims[0],dims[0]]])
        section=composite.intersection(centerline)
        row['composite_centerline_length']=section.length if name!='Highway Strip' else None
        row['composite_note']='Includes same-colour end pieces; highway continues as a road.'
        # White/light-grey primitives inside the strip: preserve source evidence.
        for d in field.primitives:
            if d['source']!=region['source'] or min(d['color'])<190:
                continue
            for face in polygons(d):
                p=polygon(face)
                if p.area>.2*vp.area or p.intersection(vp).area<.5*p.area:
                    continue
                pp=projected(face,c,u,v)
                s0,s1=min(p[0] for p in pp),max(p[0] for p in pp)
                t0,t1=min(p[1] for p in pp),max(p[1] for p in pp)
                kind='other marking (threshold/number/edge needs review)'
                if t1-t0<=3 and abs((t0+t1)/2)<3 and 4<s1-s0<70:
                    kind='centreline candidate'
                row['markings'].append(dict(draw_line=d['draw_line'],file=d['file'],
                    primitive=d['primitive'],s=[s0,s1],t=[t0,t1],kind=kind))
        external=[r for r in field.regions if r['id'] in {1,2} and r['source']!=region['source']]
        local_taxi=[r for r in field.regions if r['id'] in {1,2}
                    and r['source']==region['source'] and r['line']!=rline]
        for sign in [-1,1]:
            ss=vl[0] if sign<0 else vl[1]
            start=[c[i]+u[i]*ss for i in range(2)]
            direction=[sign*x for x in u]
            label=('W' if direction[0]<0 else 'E')+(' / N' if direction[1]>0 else ' / S')
            def corridor(halfwidth):
                return Polygon([[start[i]+direction[i]*dist+v[i]*side for i in range(2)]
                                for dist,side in [(0,-halfwidth),(args.corridor_length,-halfwidth),
                                    (args.corridor_length,halfwidth),(0,halfwidth)]])
            core=corridor(row['visual_width']/2)
            margin=corridor(row['visual_width']/2+30)
            hits=screen(core,start,direction,external,ground,terrain,land)
            surrounding=screen(margin,start,direction,external,ground,terrain,land)
            taxi=screen(core,start,direction,local_taxi,[],[],land)
            row['ends'].append(dict(label=label,center=start,direction=direction,
                core_hits=hits,margin_hits=surrounding,local_pavement_hits=taxi,
                unresolved_nearby=[dict(line=o['line'],name=o['name'],
                    distance_to_corridor=Point(o['pos'][0],o['pos'][2]).distance(margin))
                    for o in field.objects if o['line'] in missing and
                    Point(o['pos'][0],o['pos'][2]).distance(margin)<250],
                _core=core,_margin=margin))
        rows.append(row)
        print(f"{name}: safe {dims[0]:.2f} x {dims[1]:.2f}, visible {length:.2f} x {row['visual_width']:.2f}, "
              f"safe coverage {row['safe_covered_percent']:.2f}%, outline difference {row['outline_max_difference']:.2f} m")
        for end in row['ends']:
            print(' ',end['label'],[(h['type'],round(h['distance']),h.get('name',h.get('file','')))
                                    for h in end['core_hits'][:5]])
    data=dict(fld=str(args.fld.resolve()),sha256=hashlib.sha256(args.fld.read_bytes()).hexdigest(),
        line_count=field.line_count,pack_count=len(field.packs),region_count=len(field.regions),
        drawing_count=len(field.primitives),ground_count=len(field.objects),
        ground_envelope_count=len(ground),unresolved_ground_lines=missing,
        terrain_count=len(field.terrain),area_count=len(field.areas),
        corridor_length=args.corridor_length,corridor_side_margin=30,runways=clean(rows))
    (args.out/'runways.json').write_text(json.dumps(data,indent=2),encoding='utf-8')
    (args.out/'pack_ranges.json').write_text(json.dumps(field.pack_ranges,indent=2),encoding='utf-8')
    columns=['name','safe_length','visual_length','length_difference','safe_width','visual_width',
             'lateral_offset','safe_covered_percent','visual_safe_percent','outline_max_difference',
             'composite_centerline_length','composite_safe_covered_percent',
             'source','region_line','pc2','drawing_line']
    with (args.out/'runways.csv').open('w',newline='',encoding='utf-8') as f:
        writer=csv.DictWriter(f,fieldnames=columns)
        writer.writeheader()
        writer.writerows([{key:row[key] for key in columns} for row in rows])
    if not args.no_plots:
        draw(field,rows,ground,terrain,args.out,args.corridor_length)
    print(f'Wrote measurements, provenance and maps to {args.out}; unresolved ground models: {len(missing)}')


if __name__=='__main__':
    main()
