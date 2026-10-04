#!/usr/bin/env python3
"""Actual CLI/PTY plus terminal-grid reflow before the application receives new dimensions."""
import argparse,ast,copy,fcntl,json,os,pathlib,pty,re,select,signal,struct,subprocess,tempfile,termios,time,traceback,unicodedata
p=argparse.ArgumentParser();p.add_argument('--bin',default='zig-out/bin/doin');p.add_argument('--artifacts',default='artifacts/reflow-e2e');args=p.parse_args();binary=str(pathlib.Path(args.bin).resolve());artifacts=pathlib.Path(args.artifacts);artifacts.mkdir(parents=True,exist_ok=True)
# Use the existing ANSI renderer, with explicit carried cells/history and ED2.
source=pathlib.Path('tests/tui_e2e.py').read_text();tree=ast.parse(source);node=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='screen');renderer=ast.get_source_segment(source,node)
renderer=renderer.replace('def screen(raw, cols, rows):','def screen(raw, cols, rows, initial=None, previous_history=None):')
needle="    x = y = 0;"
renderer=renderer.replace(needle,"    if initial is not None: cells=copy.deepcopy(initial)\n    history=list(previous_history or [])\n    def scroll():\n        if top==0: history.append(''.join(c[0] for c in cells[top]))\n        cells.pop(top); cells.insert(bottom, [(' ', color, bold, background) for _ in range(cols)])\n"+needle)
renderer=renderer.replace("cells.pop(top); cells.insert(bottom, [(' ', color, bold, background) for _ in range(cols)])","scroll()",2)
# The replacement above includes the helper itself; restore its actual scroll operation.
renderer=renderer.replace('        scroll()\n    x = y',"        cells.pop(top); cells.insert(bottom, [(' ', color, bold, background) for _ in range(cols)])\n    x = y")
renderer=renderer.replace("cells.pop(top); cells.insert(bottom,[(' ',color,bold,background) for _ in range(cols)])","scroll()")
renderer=renderer.replace("                elif command == 'K':","                elif command == 'J' and numbers[0]==2:\n                    cells=[[(' ',color,bold,background) for _ in range(cols)] for _ in range(rows)]\n                elif command == 'K':")
renderer=renderer.replace('    return cells','    return cells,history');exec(renderer)
receipts=[];failure=None;process=None;master=slave=None;raw=bytearray()
def reflow(grid,cols,rows,history):
    wrapped=[]
    for row in grid:
        end=len(row)
        while end and not row[end-1][0].strip():end-=1
        parts=[row[i:i+cols] for i in range(0,end,cols)] or [[]]
        for part in parts:wrapped.append(part+[(' ','#eeeeee',False,'#111111')]*(cols-len(part)))
    lost=max(0,len(wrapped)-rows);history=history+[''.join(c[0] for c in row) for row in wrapped[:lost]]
    visible=wrapped[lost:];visible += [[(' ','#eeeeee',False,'#111111')]*cols for _ in range(rows-len(visible))]
    return visible,history
try:
    with tempfile.TemporaryDirectory(prefix='doin-reflow-') as tmp:
        base=pathlib.Path(tmp).resolve();store=base/'Tasks';config=base/'config';env=dict(os.environ,DOIN_CONFIG_DIR=str(config),TERM='xterm-256color',DOIN_NO_ANIMATION='1');env.pop('NO_COLOR',None)
        for argv in [('init','--storage',str(store),'--provider','manual'),('add','Before resize café 東京'),('add','Keep this second task')]:
            r=subprocess.run([binary,*argv],env=env,capture_output=True,text=True,timeout=10);assert r.returncode==0,r.stderr
        before=(store/'tasks.md').read_bytes();master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',30,126,0,0));process=subprocess.Popen([binary],env=env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True)
        def pump(seconds=.15):
            end=time.monotonic()+seconds
            while time.monotonic()<end:
                if select.select([master],[],[],.02)[0]:
                    try:raw.extend(os.read(master,65536))
                    except OSError:break
        def wait(marker,start=0):
            end=time.monotonic()+8
            while marker.encode() not in raw[start:]:
                pump();assert process.poll() is None and time.monotonic()<end,(marker,bytes(raw[-1000:]))
            pump()
        wait('Enter submit');offset=len(raw);os.write(master,b'/help\r');wait('Slash commands work there too',offset);wait('Enter submit',offset)
        os.write(master,'draft café 東京 remains editable'.encode()+b'\x1b[D'*9);pump(.3)
        grid,history=screen(bytes(raw),126,30);assert any('Before resize café' in row for row in history+[''.join(c[0] for c in row) for row in grid])
        for name,cols,rows in [('narrow',58,26),('grow',110,36)]+[(f'drag-{i}',60+i%5*8,25+i%4) for i in range(12)]:
            grid,history=reflow(grid,cols,rows,history);native_history_rows=len(history);offset=len(raw)
            (artifacts/(name+'-before.txt')).write_text('\n'.join(''.join(c[0] for c in row) for row in grid))
            fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',rows,cols,0,0));wait('Enter submit',offset)
            emitted=bytes(raw[offset:]);grid,history=screen(emitted,cols,rows,grid,history);lines=[''.join(c[0] for c in row).rstrip() for row in grid];text='\n'.join(lines)
            (artifacts/(name+'-after.txt')).write_text(text+'\n');(artifacts/(name+'.ansi')).write_bytes(emitted)
            receipts.append({'resize':name,'columns':cols,'rows':rows,'top_frames':text.count('╭'),'bottom_frames':text.count('╰'),'screen':text,'history_rows':len(history)})
            assert text.count('╭')==1 and text.count('╰')==1,'Reflowed composer remains in viewport'
            assert not any('─' in line or '│' in line for line in lines[:-4]),'Old composer fragments remain above footer'
            assert 'draft café 東京 remains editable' in lines[-3]
            assert 'Slash commands work there too' in text,'Last output displaced from viewport by resize'
            assert len(history)==native_history_rows,'Resize added synthetic lines to native scrollback'
            idle_offset=len(raw);pump(.3);assert len(raw)==idle_offset,'Unchanged-size input redraws forever'
            assert any('Before resize café' in row for row in history+lines),'Task context lost after resize'
            assert any('Slash commands work there too' in row for row in history+lines),'Prior help transcript lost'
            assert (store/'tasks.md').read_bytes()==before
        for i in range(20):
            fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',22+i%6,55+i%7*5,0,0));pump(.01)
        offset=len(raw);fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',28,80,0,0));wait('Enter submit',offset)
        grid,history=screen(bytes(raw[offset:]),80,28);text='\n'.join(''.join(c[0] for c in row).rstrip() for row in grid)
        (artifacts/'rapid-drag.txt').write_text(text+'\n')
        assert text.count('╭')==1 and 'Slash commands work there too' in text,'Rapid resize left duplicate input or displaced output'
        idle_offset=len(raw);pump(.3);assert len(raw)==idle_offset,'Rapid resize continued scrolling after drag ended'
        fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',11,23,0,0));pump(.3)
        offset=len(raw);fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',28,80,0,0));wait('Enter submit',offset)
        grid,history=screen(bytes(raw[offset:]),80,28);text='\n'.join(''.join(c[0] for c in row).rstrip() for row in grid)
        (artifacts/'short-grow-without-enter.txt').write_text(text+'\n')
        assert text.count('╭')==1 and 'Slash commands work there too' in text,'Growing after short resize lost last output'
        assert 'draft café 東京 remains editable' in text,'Growing after short resize lost draft'
        os.write(master,b' final\r');wait('Saved.');assert 'draft café 東京 remains final editable' in (store/'tasks.md').read_text(),'Resize moved the editing cursor'
        os.write(master,b'\x04');end=time.monotonic()+5
        while process.poll() is None and time.monotonic()<end:pump()
        assert process.wait(timeout=1)==0
        fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',11,23,0,0));offset=len(raw)
        process=subprocess.Popen([binary],env=env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True);wait('› ',offset)
        offset=len(raw);fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',28,80,0,0));wait('Enter submit',offset)
        grid,history=screen(bytes(raw[offset:]),80,28);text='\n'.join(''.join(c[0] for c in row).rstrip() for row in grid)
        (artifacts/'initial-short-grow.txt').write_text(text+'\n');assert text.count('╭')==1 and 'Before resize café 東京' in text,'Initially short terminal failed to recover without input'
        os.write(master,b'\x04');process.wait(timeout=5);pump()
except BaseException:
    failure=traceback.format_exc();raise
finally:
    if process is not None and process.poll() is None:
        os.killpg(process.pid,signal.SIGTERM)
        try:process.wait(timeout=3)
        except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=3)
    for fd in (master,slave):
        if fd is not None:os.close(fd)
    (artifacts/'transcript.ansi').write_bytes(raw)
    (artifacts/'results.json').write_text(json.dumps({'command':'python3 tests/reflow_e2e.py --bin '+binary,'failure':failure,'receipts':receipts},indent=2)+'\n')
print('Real PTY reflow, draft preservation, transcript retention and single footer passed.')
