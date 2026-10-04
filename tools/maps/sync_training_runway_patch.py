"""Apply only reviewed PC2/RGN edits to the independently customised stock map.

Never replace the training map with the game's map: training has extra ground
objects and different IFFs. Packed drawing bodies and region lines are matched
independently, then edited using the same PCK-aware line buffer as the patch.
"""
import argparse
import hashlib
import json
from pathlib import Path

from fld_geometry import FieldGeometry
from runway_patch_core import FldPatcher, pck_ancestors


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def sync(before, after, training, output):
    if output.resolve() in {before.resolve(),after.resolve(),training.resolve()}:
        raise ValueError('Generate into scratch; do not overwrite a live source map')
    original, updated, stock = [FieldGeometry(p) for p in (before,after,training)]
    for attr in ('regions','primitives'):
        a,b=getattr(original,attr),getattr(stock,attr)
        if len(a)!=len(b):
            raise ValueError('Training geometry is not the same baseline')
        for x,y in zip(a,b):
            keys=('are','pos') if attr=='regions' else ('local','pos','color')
            if any(x[k]!=y[k] for k in keys):
                raise ValueError('Training geometry differs; review before synchronising')
    raw=training.read_bytes().decode('latin-1').splitlines(keepends=True)
    newline='\r\n' if any(l.endswith('\r\n') for l in raw) else '\n'
    patcher=FldPatcher(raw)
    operations=[]
    changed=[]
    for name, old_body in original.packs.items():
        old=[l for _,l in old_body]
        new=[l for _,l in updated.packs[name]]
        if old==new:
            continue
        stock_body=stock.packs[name]
        if name.endswith('.pc2'):
            if old!=[l for _,l in stock_body] or len(new)<len(old):
                raise ValueError(f'Unexpected training drawing or deleted geometry: {name}')
            entry=patcher.pck_map[name]
            ancestors=[name]+[p.name for p in pck_ancestors(patcher.pck_map,name)]
            operations.append((entry.header_idx,'drawing',entry,new,ancestors))
            changed.append(dict(file=name,added_lines=len(new)-len(old)))
        elif name.endswith('.fld'):
            if len(old)!=len(new) or len(old)!=len(stock_body):
                raise ValueError(f'Unexpected owned field changes: {name}')
            for i,(a,b) in enumerate(zip(old,new)):
                if a==b:
                    continue
                if not a.startswith(('ARE ','POS ')) or stock_body[i][1]!=a:
                    raise ValueError(f'Unexpected non-region change: {name}:{i}')
                operations.append((stock_body[i][0]-1,'line',b,None,None))
                changed.append(dict(file=name,stock_line=stock_body[i][0],before=a,after=b))
        else:
            raise ValueError(f'Unexpected changed pack: {name}')
    # Descending physical indices keep every yet-to-be-edited source index stable.
    for idx,kind,value,new,ancestors in sorted(operations,key=lambda x:x[0],reverse=True):
        if kind=='line':
            patcher.replace_line(idx,value+newline)
        else:
            entry=value
            body=[l+newline for l in new]
            for offset in range(entry.count):
                patcher.replace_line(entry.start_idx+offset,body[offset])
            extra=body[entry.count:]
            if extra:
                patcher.insert_after(entry.end_idx,extra,ancestors)
    output.parent.mkdir(parents=True,exist_ok=True)
    patcher.write(str(output))
    result=FieldGeometry(output)
    if stock.objects!=result.objects:
        # Line numbers/ancestor line references change; compare semantic contents.
        key=lambda o:(o['source'],o['name'],o['iff'],o['tag'],o['pos'])
        if [key(o) for o in stock.objects]!=[key(o) for o in result.objects]:
            raise ValueError('Training ground objects changed')
    if len(result.regions)!=len(updated.regions) or any(
        a['are']!=b['are'] or a['pos']!=b['pos'] for a,b in zip(result.regions,updated.regions)):
        raise ValueError('Synced runway regions differ from reviewed game map')
    key=lambda p:(p['source'],p['file'],p['primitive'],p['local'],p['pos'],p['color'])
    if [key(p) for p in result.primitives]!=[key(p) for p in updated.primitives]:
        raise ValueError('Synced drawing geometry differs from reviewed game map')
    return dict(input_hash=sha(training),output_hash=sha(output),
                ground_objects_retained=len(stock.objects),changes=changed)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('before','after','training','output','manifest'):
        parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    result=sync(args.before,args.after,args.training,args.output)
    args.manifest.parent.mkdir(parents=True,exist_ok=True)
    args.manifest.write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(f'Synchronised pavement/regions; retained {result["ground_objects_retained"]} training objects')


if __name__=='__main__':
    main()
