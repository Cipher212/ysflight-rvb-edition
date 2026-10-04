"""Patch original FLD lines without reformatting unrelated geometry."""
import math
import re
from pathlib import Path


class SourcePatch:
    """Collect edits against original lines; serialize once with exact PCK counts."""
    def __init__(self, raw):
        self.lines=raw.decode('latin-1').splitlines(keepends=True)
        self.newline='\r\n' if b'\r\n' in raw else '\n'
        self.replacements={}
        self.insertions={}
        self.expected_points={}
        self.packs=build_pck_map(self.lines)

    def replace(self, line, text):
        value=text.rstrip('\r\n')+self.newline
        if line in self.replacements and self.replacements[line]!=value:
            raise ValueError(f'Conflicting edit at line {line}')
        self.replacements[line]=value

    def insert(self, after, lines):
        self.insertions.setdefault(after,[]).extend(t.rstrip('\r\n')+self.newline for t in lines)

    def new_line(self, old):
        return old+sum(len(v) for k,v in self.insertions.items() if k<old)

    def render(self):
        headers={}
        for entry in self.packs.values():
            extra=sum(len(v) for k,v in self.insertions.items()
                      if entry.start_idx<=k-1<=entry.end_idx)
            if extra:
                headers[entry.header_idx+1]=f'PCK "{entry.name}" {entry.count+extra}'+self.newline
        out=[]
        for n,line in enumerate(self.lines,1):
            out.append(headers.get(n,self.replacements.get(n,line)))
            out.extend(self.insertions.get(n,[]))
        return ''.join(out).encode('latin-1')



def world_to_local(pos_x, pos_z, heading, wx, wz):
    h=heading*math.tau/65536
    c,s=math.cos(h),math.sin(h)
    dx,dz=wx-pos_x,wz-pos_z
    return c*dx+s*dz,-s*dx+c*dz


class PckEntry:
    def __init__(self,name,header_idx,count):
        self.name,self.header_idx,self.count=name,header_idx,count
        self.start_idx,self.end_idx=header_idx+1,header_idx+count
        self.parent=None


def build_pck_map(lines):
    entries,stack={},[]
    for i,line in enumerate(lines):
        while stack and i>stack[-1].end_idx:
            stack.pop()
        match=re.fullmatch(r'PCK\s+"([^"]+)"\s+(\d+)\s*',line)
        if not match:continue
        name,count=match[1],int(match[2])
        if name in entries or i+count>=len(lines):
            raise ValueError(f'Duplicate or truncated pack {name}')
        entry=PckEntry(name,i,count)
        if stack:
            entry.parent=stack[-1]
            if entry.end_idx>entry.parent.end_idx:
                raise ValueError(f'Child pack extends beyond parent: {name}')
        entries[name]=entry
        stack.append(entry)
    return entries


def pck_ancestors(entries,name):
    result=[]
    entry=entries[name].parent
    while entry:
        result.append(entry)
        entry=entry.parent
    return result


class FldPatcher:
    """Small mutable buffer for transferring reviewed packs into a training copy.

    Callers edit from bottom to top. Snapshot containing headers BEFORE insertion;
    a reader cannot correctly infer nesting from stale counts after adding lines.
    """
    def __init__(self,lines):
        self.lines=list(lines)
        self._pck_map=None

    @property
    def pck_map(self):
        if self._pck_map is None:self._pck_map=build_pck_map(self.lines)
        return self._pck_map

    def replace_line(self,idx,text):
        self.lines[idx]=text

    def insert_after(self,idx,new_lines,pck_names):
        if not new_lines:return
        headers=[self.pck_map[name] for name in pck_names]
        self.lines[idx+1:idx+1]=new_lines
        for entry in headers:
            if entry.header_idx>idx:raise ValueError('Header after insertion point')
            newline='\r\n' if self.lines[entry.header_idx].endswith('\r\n') else '\n'
            self.lines[entry.header_idx]=f'PCK "{entry.name}" {entry.count+len(new_lines)}'+newline
        self._pck_map=None

    def write(self,path):
        Path(path).write_bytes(''.join(self.lines).encode('latin-1'))
