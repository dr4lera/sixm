#!/usr/bin/env python3
"""Assemble a bounded static cell from recovered world-space placements.
Uses separately built SixNG. No original game content is included in this source.
"""
import argparse, json, math, pathlib, re, subprocess


def select(placements, radius, maximum):
    if not 1<=maximum<=32 or not math.isfinite(radius) or not 0<radius<=250:
        raise ValueError('Use 1–32 models and a radius up to 250 metres.')
    for path in sorted(pathlib.Path(placements).glob('*.json')):
        if path.stat().st_size > 32*1024*1024:
            continue
        document = json.loads(path.read_text())
        if document.get('space') != 'world':
            continue
        candidates = [e for e in document.get('entities', []) if e.get('model_id') and e.get('name')
                      and e.get('render') is not False and 'gltf' in e
                      and re.fullmatch(r'[A-Za-z0-9_]+',e['name'])]
        anchors = [e for e in candidates if not any(x in e['name'].lower() for x in ['slod','_lod','proxy'])]
        if len(anchors) < 4:
            continue
        center = anchors[0]['gltf']['translation']
        chosen, models = [], set()
        for e in candidates:
            if len(chosen)>=2048:
                break
            t=e['gltf']['translation']
            if not all(math.isfinite(x) for x in t) or math.dist(center,t)>radius:
                continue
            if e['model_id'] not in models and len(models)>=maximum:
                continue
            chosen.append(e);models.add(e['model_id'])
        if len(models)>=min(3,maximum):
            return path,center,chosen
    raise ValueError('No suitable bounded world-space cell found.')


def build(helper,game,work,placements,out,radius=40,maximum=6):
    path,center,entities=select(placements,radius,maximum)
    out=pathlib.Path(out).resolve();out.mkdir(parents=True,exist_ok=True)
    unique={e['model_id']:e for e in entities};results={}; failures=[]
    for identifier,e in unique.items():
        archive,offset=identifier.rsplit('@',1)
        if not re.fullmatch(r'[0-9a-fA-F]+',offset) or not re.fullmatch(r'[A-Za-z0-9_.-]+\.rpf',archive):
            raise ValueError('Malformed source id')
        command=[str(helper),'--game',str(game),'--work',str(work),'extract',archive,'--id',identifier,'--out',str(out)]
        result=subprocess.run(command,capture_output=True,text=True,timeout=600)
        (out/(offset+'.log')).write_text(result.stdout+result.stderr)
        folder=out/'models'/archive.removesuffix('.rpf')/(e['name']+'_'+offset)
        glb=folder/'model.glb'
        if result.returncode or not glb.is_file():
            failures.append(identifier);continue
        results[identifier]=glb.relative_to(out).as_posix()
    instances=[]
    for e in entities:
        if e['model_id'] not in results:
            continue
        transform=e['gltf'];instances.append(dict(name=e['name'],model=results[e['model_id']],source_id=e['model_id'],
            translation=[a-b for a,b in zip(transform['translation'],center)],rotation=transform['rotation'],scale=transform['scale'],
            tint_row=e.get('tint_row',0)))
    manifest=dict(version=1,kind='sixm-static-cell',source_placement_file=path.name,world_origin=center,radius=radius,
                  instances=instances,unique_models=len(results),failed_models=failures,
                  limitations=['Static geometry only','No collision or gameplay','LOD relationships not interpreted','Specialized materials, tint rows and animations not reproduced'])
    (out/'cell.json').write_text(json.dumps(manifest,indent=2))
    return manifest

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for field in ['helper','game','work','placements','out']:p.add_argument('--'+field,required=True,type=pathlib.Path)
    p.add_argument('--radius',type=float,default=40);p.add_argument('--max-models',type=int,default=6)
    a=p.parse_args()
    if not 1<=a.max_models<=32 or not 0<a.radius<=250:p.error('Use 1–32 models and a radius up to 250 metres.')
    result=build(a.helper,a.game,a.work,a.placements,a.out,a.radius,a.max_models)
    print(json.dumps({'instances':len(result['instances']),'unique_models':result['unique_models'],'failed_models':result['failed_models'],'cell':str(a.out/'cell.json')}))
