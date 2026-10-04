"""Render one before/after evidence pair from the actual packed runway drawings."""
import argparse
import json
import sys
from pathlib import Path


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('before','after','output','deps'):
        parser.add_argument('--'+name,required=True,type=Path)
    args=parser.parse_args()
    sys.path.insert(0,str(args.deps.resolve()))
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.collections import PolyCollection
    from fld_geometry import FieldGeometry, polygons
    from rebase_runway_references import SIGNS
    rows=json.loads(Path('planning/data/luavi_runways_3km.json').read_text())['runways'][:6]
    fields=[FieldGeometry(args.before),FieldGeometry(args.after)]
    fig,axes=plt.subplots(6,2,figsize=(15,13),layout='constrained')
    for index,row in enumerate(rows):
        sign=SIGNS[row['name']]
        def project(p):
            s=sum((p[i]-row['center'][i])*row['u'][i] for i in range(2))
            t=sum((p[i]-row['center'][i])*row['v'][i] for i in range(2))
            return [sign*s,t]
        half=row['safe_length']/2
        for col,field in enumerate(fields):
            ax=axes[index,col]
            faces,colors=[],[]
            for p in sorted(field.primitives,key=lambda p:(p['pos'][1],p['draw_line'])):
                if p['source']!=row['source']:continue
                for face in polygons(p):
                    projected=[project(q) for q in face]
                    if max(q[0] for q in projected)<half-450 or min(q[0] for q in projected)>half+240:continue
                    faces.append(projected)
                    colors.append([c/255 for c in p['color']])
                if p['primitive']=='PST':
                    points=[project(q) for q in p['points']]
                    ax.scatter(*zip(*points),c=[[c/255 for c in p['color']]],s=9,zorder=4)
            ax.add_collection(PolyCollection(faces,facecolors=colors,edgecolors='none',zorder=2))
            ax.axvline(half,color='#e62c93',ls='--',lw=1,zorder=5)
            if col:
                ax.axvline(half+200,color='#25dee6',lw=1,zorder=5)
                ax.annotate('+200 m',(half+100,25),ha='center',fontsize=10)
            ax.set(xlim=(half-450,half+240),ylim=(-32,32),
                   title=f"{row['name']} - {'after' if col else 'before'}")
            ax.set_facecolor('#6f8c55')
            ax.set_yticks([-20,0,20])
            ax.grid(alpha=.13,zorder=1)
            ax.tick_params(labelsize=8)
            if col==0:ax.set_ylabel('Across runway (m)')
            if index==5:ax.set_xlabel('Metres toward selected end from original runway centre')
    fig.suptitle('Luavi: selected runway ends before / after\n'
                 'Actual PC2 geometry; cross-axis magnified. Pink dashed = original safe endpoint; cyan = new endpoint.\n'
                 'Existing hand-drawn shapes and offsets preserved; Highway Strip unchanged.',fontsize=12)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    fig.savefig(args.output,dpi=130)
    plt.close(fig)


if __name__=='__main__':
    main()
