#!/usr/bin/env python3
"""Verify Shift conversions through the built AppModel audit runner. No Command wheel."""
import argparse, csv, hashlib, json, os, pathlib, plistlib, subprocess, zipfile, struct, zlib
ROOT=pathlib.Path(__file__).resolve().parent.parent
OUT=ROOT/'build/conversion-audit'; FIX=OUT/'fixtures'; RUN=OUT/'runner'
MARKER='Citrus conversion audit 48271'
def package(path, files, mimetype=None):
    with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED) as z:
        if mimetype: z.writestr('mimetype',mimetype,compress_type=zipfile.ZIP_STORED)
        for n,s in files.items(): z.writestr(n,s)
def extras():
    if (FIX/'sample.gzip').exists(): (FIX/'sample.gzip').rename(FIX/'sample.tar.gz')
    package(FIX/'sample.ods',{
        'META-INF/manifest.xml':'<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>',
        'content.xml':f'<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:spreadsheet><table:table table:name="Sheet1"><table:table-row><table:table-cell office:value-type="string"><text:p>{MARKER}</text:p></table:table-cell><table:table-cell office:value-type="float" office:value="42"><text:p>42</text:p></table:table-cell></table:table-row></table:table></office:spreadsheet></office:body></office:document-content>'
    },'application/vnd.oasis.opendocument.spreadsheet')
    package(FIX/'sample.pptx',{
        '[Content_Types].xml':'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/></Types>',
        '_rels/.rels':'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>',
        'ppt/presentation.xml':'<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst><p:sldSz cx="9144000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>',
        'ppt/_rels/presentation.xml.rels':'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/></Relationships>',
        'ppt/slides/slide1.xml':f'<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="Audit text"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="9144000" cy="6858000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>{MARKER}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'
    })
    # Optional installed fixtures are never required to run the rest of the audit.
    penguin=pathlib.Path('/System/Library/Templates/Data/Library/User Pictures/Animals/Penguin.heic')
    if not (FIX/'sample.heic').exists() and penguin.is_file():
        (FIX/'sample.heic').write_bytes(penguin.read_bytes())
    workbook=pathlib.Path('/Applications/Numbers.app/Contents/Resources/BlankDelimited.xls')
    if workbook.is_file() and not (FIX/'sample.xls').exists():
        (FIX/'sample.xls').write_bytes(workbook.read_bytes())
    (FIX/'sample.textclipping').write_bytes(plistlib.dumps({'UTI-Data':{'public.utf8-plain-text':MARKER+'\n'}},fmt=plistlib.FMT_BINARY))
    def header(kind, flags, payload):
        body=struct.pack('<BHH',kind,flags,7+len(payload))+payload
        return struct.pack('<H',zlib.crc32(body)&65535)+body
    content=(MARKER+'\n').encode(); name=b'sample.txt'
    rar=b'Rar!\x1a\x07\x00'+header(0x73,0,b'\0'*6)
    fields=struct.pack('<IIBIIBBHI',len(content),len(content),3,zlib.crc32(content),0,20,0x30,len(name),0o100644)+name
    rar+=header(0x74,0x8000,fields)+content+header(0x7b,0,b'')
    (FIX/'sample.rar').write_bytes(rar)
    subprocess.run(['/usr/bin/tar','-tf',str(FIX/'sample.rar')],check=True,capture_output=True)
def digest(path):
    if path.is_dir():
        return [(str(p.relative_to(path)),hashlib.sha256(p.read_bytes()).hexdigest()) for p in sorted(path.rglob('*')) if p.is_file()]
    return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sources',nargs='*',help='Source extensions to audit (default: all)')
    parser.add_argument('--target',action='append',default=[],help='Limit output format; may be repeated')
    parser.add_argument('--report-only',action='store_true',help='Rebuild report from saved results')
    args=parser.parse_args()
    if not RUN.is_file():
        parser.error('Missing runner. Run ./scripts/build-conversion-audit.sh first.')
    OUT.mkdir(parents=True,exist_ok=True)
    inventory=json.loads(subprocess.check_output([str(RUN),'inventory']))
    selected={source.lower() for source in args.sources}
    target_filter={target.lower() for target in args.target}
    unknown=selected-{entry['source'] for entry in inventory}
    if unknown: parser.error('Unknown source format(s): '+', '.join(sorted(unknown)))
    if args.report_only and not (OUT/'results.json').is_file():
        parser.error('No saved results. Run an audit before using --report-only.')
    if not args.report_only:
        if not (FIX/'sample.txt').exists():
            subprocess.run([str(RUN),'fixtures',str(FIX)],check=True)
        extras()
    (OUT/'inventory.json').write_text(json.dumps(inventory,indent=2))
    report_only=args.report_only
    def selected_pair(r): return (not selected or r['source'] in selected) and (not target_filter or r['target'] in target_filter)
    previous=json.loads((OUT/'results.json').read_text()) if (OUT/'results.json').is_file() else []
    rows=[r for r in previous if report_only or not selected_pair(r)]
    for entry in inventory:
        if report_only: continue
        if selected and entry["source"] not in selected: continue
        source=entry['source']; file=FIX/('sample.tar.gz' if source=='gzip' else 'sample.'+source)
        targets=list(dict.fromkeys(entry['offered']+entry['reference']))
        original=digest(file) if file.exists() else None
        for target in targets:
            if target_filter and target not in target_filter: continue
            row=dict(source=source,target=target,offered=target in entry['offered'],reference=target in entry['reference'])
            if not file.exists(): row.update(status='UNTESTED',detail='No genuine source fixture available; not counted as a pass')
            else:
                dest=OUT/'outputs'/source/target
                try:
                    env=os.environ.copy()
                    if source=='xls': env['CITRUS_AUDIT_BLANK_SOURCE']='1'
                    result=subprocess.run([str(RUN),'pair',str(file),target,str(dest)],capture_output=True,text=True,timeout=150 if target=='pages' else 32,env=env)
                    lines=[l for l in result.stdout.splitlines() if l.startswith('{')]
                    row.update(json.loads(lines[-1]) if lines else dict(status='FAIL',detail='Runner failed: '+result.stderr[-1000:]))
                except subprocess.TimeoutExpired: row.update(status='FAIL',detail='Timed out; conversion did not complete')
                if digest(file)!=original: row.update(status='FAIL',detail='SOURCE FILE CHANGED')
            rows.append(row)
            with (OUT/'results.json').open('w') as f: json.dump(rows,f,indent=2)
        offered=[r for r in rows if r['source']==source and r['offered']]
        print(source.upper(),len(offered),'offered:',{s:sum(r['status']==s for r in offered) for s in ['PASS','FAIL','UNTESTED']},flush=True)
    with (OUT/'results.csv').open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=['source','target','offered','reference','status','detail'],extrasaction='ignore');w.writeheader();w.writerows(rows)
    lines=['# Shift conversion audit','', 'Command/Tools and Control/Actions wheels were not tested. All outputs are temporary audit artifacts under build/conversion-audit/outputs.','', 'The audit submits each edge through AppModel.submitWheelDrop, including the current persisted format defaults. PASS means the sample produced output that an independent decoder/parser accepted and retained the checked content. It does not certify full layout, metadata, animation, or arbitrary-file fidelity. Native Finder gestures and live modifier interception are outside this headless check.','', '| Source | Offered pass | Offered fail | Untested | Missing reference options |','|---|---:|---:|---:|---|']
    for e in inventory:
        rs=[r for r in rows if r['source']==e['source'] and r['offered']]
        missing=[t.upper() for t in e['reference'] if t not in e['offered']]
        lines.append('| '+e['source'].upper()+' | '+' | '.join(str(sum(r['status']==s for r in rs)) for s in ['PASS','FAIL','UNTESTED'])+' | '+', '.join(missing)+' |')
    lines+=['','## Failed offered conversions','']
    for r in rows:
        if r['offered'] and r['status']=='FAIL': lines.append('- **'+r['source'].upper()+' → '+r['target'].upper()+'**: '+r.get('detail','').replace('\n',' ')[:350])
    lines+=['','## Missing wheel options','']
    for r in rows:
        if r['reference'] and not r['offered']: lines.append('- '+r['source'].upper()+' → '+r['target'].upper()+': backend probe '+r['status']+'. '+r.get('detail','').replace('\n',' ')[:180])
    lines+=['','## Source fixture limits','','PPT needs a genuine legacy sample and remains untested when absent. TEXTCLIPPING, PPTX, and ODS use generated plist/OOXML/ODF fixtures. The optional XLS fixture comes from installed Numbers; PAGES is generated by installed Pages when CITRUS_AUDIT_PAGES=1. Missing fixtures are UNTESTED. XLS is blank and checks format handling only, not populated cells. HEIC is generated by the application, with an optional installed Apple sample fallback. Other fixtures are generated locally. A pass checks the sampled content and readability, not arbitrary-file fidelity.','']
    (OUT/'report.md').write_text('\n'.join(lines))
    print('REPORT',OUT/'report.md',flush=True)
    return int(any(r['status']=='FAIL' and (report_only or selected_pair(r)) for r in rows))
if __name__=='__main__': raise SystemExit(main())
