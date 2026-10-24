#!/usr/bin/env python3
import json,subprocess
from pathlib import Path
R=Path(__file__).resolve().parent.parent
cases=[('/Users/zonz/Library/Fonts/ThemeX Hiragino Sans.ttc','邊'),('/Users/zonz/Library/Fonts/LucidaSubmono.otf','Objective-C'),('/System/Library/Fonts/Supplemental/Zapfino.ttf','ffi fi st'),(str(R/'Tests/Fixtures/plain.ttf'),'abcdefghijklmnopqrstuvwxyz')]
report=[]
for font,text in cases:
 if not Path(font).exists():continue
 old=json.loads(subprocess.check_output([str(R/'.build/legacy-scan-cli'),font,text],timeout=60))
 new=json.loads(subprocess.check_output([str(R/'.build/gsub-cli'),'--font',font,'--text',text,'--model'],timeout=60))
 lost=[];gained=0
 for i,(a,b) in enumerate(zip(old['groups'],new['groups'])):
  key=lambda v:(tuple(v['glyphs']),v['ligature'],tuple(v['range']) if v['ligature'] else ())
  x={key(v) for v in a['variants']};y={key(v) for v in b['variants']}
  lost += [(i,k) for k in x-y];gained+=len(y-x)
 report.append({'font':font,'text':text,'old_tasks':old['tasks'],'new_tasks':new['tasks'],'old_ms':old['milliseconds'],'new_ms':new['milliseconds'],'lost':lost,'added':gained})
 print(Path(font).name,'tasks',old['tasks'],'->',new['tasks'],'lost',len(lost),'added',gained,flush=True)
 assert not lost,report[-1]
(R/'.build/legacy-comparison.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
