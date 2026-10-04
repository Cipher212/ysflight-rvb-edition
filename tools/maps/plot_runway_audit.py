"""Offline top-down reference drawings, not simulator screenshots."""
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import PolyCollection
from shapely.geometry import box

from fld_geometry import polygons


def outlines(ax, shape, **kwargs):
    if hasattr(shape, 'geoms'):
        for g in shape.geoms:
            outlines(ax, g, **kwargs)
    elif shape.geom_type == 'Polygon':
        xs, ys = shape.exterior.xy
        ax.plot(xs, ys, **kwargs)


def base(ax, field, bounds, ground, terrain):
    window = box(*bounds)
    faces, colors = [], []
    for d in sorted(field.primitives, key=lambda d: (d['pos'][1], d['draw_line'])):
        for p in polygons(d):
            if box(min(v[0] for v in p), min(v[1] for v in p),
                   max(v[0] for v in p), max(v[1] for v in p)).intersects(window):
                faces.append(p)
                colors.append([c/255 for c in d['color']])
    ax.add_collection(PolyCollection(faces, facecolors=colors, edgecolors='none', zorder=1))
    for d in field.primitives:
        if d['primitive'] in {'PST','APL'}:
            pts=[p for p in d['points'] if bounds[0]<p[0]<bounds[2] and bounds[1]<p[1]<bounds[3]]
            if pts:
                ax.scatter(*zip(*pts),s=2,c=[[c/255 for c in d['color']]],zorder=3)
    tf = [t['points'] for t in terrain if t['shape'].intersects(window)]
    if tf:
        ax.add_collection(PolyCollection(tf, facecolors='#719654', edgecolors='#719654',
                                        alpha=.5, linewidths=.1, zorder=2))
    for g in ground:
        if g['shape'].intersects(window):
            outlines(ax, g['shape'], color='#a52c35', linewidth=.65, alpha=.7, zorder=5)
    pts = [(o['pos'][0], o['pos'][2]) for o in field.objects
           if bounds[0]<o['pos'][0]<bounds[2] and bounds[1]<o['pos'][2]<bounds[3]]
    if pts:
        ax.scatter(*zip(*pts), s=5, c='#b52a34', zorder=6)
    ax.set(xlim=(bounds[0],bounds[2]), ylim=(bounds[1],bounds[3]),
           xlabel='YS world X (m)', ylabel='YS world Z (m; north up)')
    ax.set_aspect('equal')
    ax.ticklabel_format(style='plain', useOffset=False)
    ax.grid(alpha=.15)
    ax.set_facecolor('#4b6b7e')


def draw(field, rows, ground, terrain, out, corridor_length=1000):
    plt.rcParams.update({'font.size':10, 'figure.facecolor':'#f5f4ed'})
    fig, ax = plt.subplots(figsize=(16,10))
    base(ax, field, (-41000,-22000,44500,30500), [], terrain)
    for row in rows:
        c=row['center']
        ax.scatter(*c, c='#ffe365', s=38, edgecolor='black', zorder=8)
        offset = (6,28) if row['name'].startswith('Cole main') else (6,7)
        ax.annotate(row['name'], c, xytext=offset, textcoords='offset points',
                    fontweight='bold', bbox=dict(facecolor='white', alpha=.85, edgecolor='none'), zorder=9)
    ax.set_title('Luavi: both sides, all six named land fields + Cole secondary\n'
                 'Actual PC2 drawings and raised terrain; labels identify inspected strips')
    fig.tight_layout()
    fig.savefig(out/'luavi_overview.png', dpi=130)
    fig.savefig(out/'luavi_overview.svg')
    plt.close(fig)
    for row in rows:
        fig = plt.figure(figsize=(15,10))
        grid = fig.add_gridspec(2,1,height_ratios=[3,1])
        ax, detail = fig.add_subplot(grid[0]), fig.add_subplot(grid[1])
        c, u, v = row['center'], row['u'], row['v']
        radius=max(1900,row['safe_length']/2+1250)
        bounds=(c[0]-radius,c[1]-radius,c[0]+radius,c[1]+radius)
        base(ax,field,bounds,ground,terrain)
        outlines(ax,row['_region'],color='#e637d2',linestyle='--',linewidth=1.4,zorder=7)
        outlines(ax,row['_paint'],color='#00ebf2',linewidth=1.5,zorder=8)
        for index, end in enumerate(row['ends']):
            outlines(ax,end['_core'],color='#ffe62d',linestyle='--',linewidth=1.3,zorder=7)
            outlines(ax,end['_margin'],color='#ffe62d',linestyle=':',linewidth=.7,zorder=7)
            ax.annotate(end['label'],end['center'],xytext=(5,6),textcoords='offset points',
                        bbox=dict(facecolor='white',alpha=.85,edgecolor='none'),zorder=9)
        for r in field.regions:
            if r['id'] in {1,2} and r['source']!=row['source']:
                from runway_constraints import polygon
                p=polygon(r['points'])
                if p.intersects(box(*bounds)):
                    outlines(ax,p,color='#ff764a',linewidth=.6,alpha=.6,zorder=3)
        for o in field.objects:
            if o['tag'] and bounds[0]<o['pos'][0]<bounds[2] and bounds[1]<o['pos'][2]<bounds[3]:
                ax.annotate(o['tag'],(o['pos'][0],o['pos'][2]),fontsize=7,color='#672500',zorder=9)
        pfaces, colors = [], []
        for d in field.primitives:
            if d['source']!=row['source']:
                continue
            for pts in polygons(d):
                projected=[((p[0]-c[0])*u[0]+(p[1]-c[1])*u[1],
                            (p[0]-c[0])*v[0]+(p[1]-c[1])*v[1]) for p in pts]
                pfaces.append(projected)
                colors.append([x/255 for x in d['color']])
            if d['primitive'] in {'PST','APL'}:
                pts=[((p[0]-c[0])*u[0]+(p[1]-c[1])*u[1],
                      (p[0]-c[0])*v[0]+(p[1]-c[1])*v[1]) for p in d['points']]
                if pts:
                    detail.scatter(*zip(*pts),s=3,c=[[x/255 for x in d['color']]],zorder=3)
        detail.add_collection(PolyCollection(pfaces,facecolors=colors,edgecolors='none'))
        for shape,color,ls in [(row['_region'],'#e637d2','--'),(row['_paint'],'#00b7bf','-')]:
            pts=list(shape.exterior.coords)
            xs=[(p[0]-c[0])*u[0]+(p[1]-c[1])*u[1] for p in pts]
            ys=[(p[0]-c[0])*v[0]+(p[1]-c[1])*v[1] for p in pts]
            detail.plot(xs,ys,color=color,linestyle=ls,linewidth=1.5)
        half=row['safe_length']/2
        detail.set(xlim=(-half-40,half+40),ylim=(-35,35),
                   xlabel='Distance along runway from safe-region centre (m)',
                   ylabel='Across (m)',title='Alignment detail (cross-axis magnified; actual drawings, including markings)')
        detail.set_facecolor('#6f8c55')
        detail.grid(alpha=.15)
        fig.suptitle(f"{row['name']}: safe {row['safe_length']:.2f} m / visible {row['visual_length']:.2f} m\n"
            f'Cyan = visible straight strip; magenta = safe rectangle; yellow = {corridor_length/1000:g} km study corridor (+30 m each side dotted); '
            'orange = external road regions; red = ground collision envelopes',fontsize=11)
        fig.tight_layout(rect=(0,0,.999,.93))
        name=row['name'].lower().replace(' ','_').replace('/','_')
        fig.savefig(out/f'{name}.png',dpi=140)
        fig.savefig(out/f'{name}.svg')
        plt.close(fig)
