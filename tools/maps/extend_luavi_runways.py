"""Extend the six reviewed Luavi strips; generate into scratch before applying."""
import argparse
import hashlib
import json
import math
from pathlib import Path

from fld_geometry import FieldGeometry
from rebase_runway_references import SIGNS, resolve
from runway_patch_core import SourcePatch
from runway_extension_geometry import extend_strip

EXPECTED_LF_SHA256 = '3269b1df71d40846cdeb9a98ef9cc44af24299932c74b520b054202d03f02d7d'


def run(source, output, manifest):
    raw=source.read_bytes()
    input_hash=hashlib.sha256(raw).hexdigest()
    if hashlib.sha256(raw.replace(b'\r\n',b'\n')).hexdigest()!=EXPECTED_LF_SHA256:
        raise ValueError('Input is not the reviewed original Luavi map; refusing a double extension')
    if source.resolve()==output.resolve():
        raise ValueError('Write a scratch map before replacing a live map')
    baseline=json.loads(Path('planning/data/luavi_runways_3km.json').read_text())
    field=FieldGeometry(source)
    patch=SourcePatch(raw)
    changes=[]
    for row in baseline['runways']:
        if SIGNS[row['name']]:
            changes.append(extend_strip(field,patch,row,SIGNS[row['name']]))
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_bytes(patch.render())
    updated=FieldGeometry(output)
    anchors=resolve(updated,baseline)
    # Check each existing primitive independently of shifted source line numbers.
    by_line={p['draw_line']:p for p in updated.primitives}
    maximum_error=0
    for old in field.primitives:
        new=by_line[patch.new_line(old['draw_line'])]
        expected=patch.expected_points.get(old['draw_line'],old['points'])
        if len(new['points'])<len(expected):
            raise ValueError('Existing drawing vertices were deleted')
        for a,b in zip(expected,new['points']):
            maximum_error=max(maximum_error,math.dist(a,b))
        if new['color']!=old['color'] or new['primitive']!=old['primitive']:
            raise ValueError('Drawing style changed')
    if maximum_error>.002:
        raise ValueError(f'Vertex verification error {maximum_error}')
    semantic=lambda o:(o['source'],o['name'],o['iff'],o['tag'],o['pos'])
    if list(map(semantic,field.objects))!=list(map(semantic,updated.objects)):
        raise ValueError('Ground objects changed')
    for attr in ('terrain','areas','shells'):
        strip=lambda x:{k:v for k,v in x.items() if k not in ('line','chain')}
        if [strip(x) for x in getattr(field,attr)]!=[strip(x) for x in getattr(updated,attr)]:
            raise ValueError(f'Unrelated {attr} changed')
    changed_regions={r['region_line'] for r in baseline['runways'] if SIGNS[r['name']]}
    new_regions={r['line']:r for r in updated.regions}
    for r in field.regions:
        if r['line'] not in changed_regions:
            n=new_regions[patch.new_line(r['line'])]
            if r['are']!=n['are'] or r['pos']!=n['pos']:
                raise ValueError('Unrelated safe/taxi region changed')
    result=dict(input_hash=input_hash,output_hash=hashlib.sha256(output.read_bytes()).hexdigest(),
        output_lf_hash=hashlib.sha256(output.read_bytes().replace(b'\r\n',b'\n')).hexdigest(),
        extension_m=200,highway_unchanged=True,changes=changes,anchors=anchors,
        maximum_existing_vertex_error_m=maximum_error,ground_objects_retained=len(updated.objects),
        added_lines=len(patch.render().decode('latin-1').splitlines())-field.line_count)
    manifest.parent.mkdir(parents=True,exist_ok=True)
    manifest.write_text(json.dumps(result,indent=2),encoding='utf-8')
    for r in anchors:
        print(f"{r['name']}: {r['safe_length']:.2f} m x {r['safe_width']:.2f} m")
    print(f'Verified existing vertices, unchanged objects/terrain/taxi, and {result["added_lines"]} inserted lines')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('input','output','manifest'):
        parser.add_argument('--'+name,required=True,type=Path)
    args=parser.parse_args()
    run(args.input,args.output,args.manifest)


if __name__=='__main__':
    main()
