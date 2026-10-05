#!/usr/bin/env python3
"""Real composer regression: literal argv, JSON remainder, AI approval and team requests."""
import argparse, fcntl, http.server, json, os, pathlib, pty, select, signal, struct, subprocess, sys, tempfile, termios, threading, time, traceback
from ai_tools_e2e import SERVER

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--bin',default='zig-out/bin/doin');args=parser.parse_args()
    binary=str(pathlib.Path(args.bin).resolve());receipts=[];requests=[];failure=None;process=None;master=None
    class Provider(http.server.BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def answer(self,value):
            data=json.dumps(value).encode();self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
        def do_GET(self):
            requests.append({'method':'GET','path':self.path})
            if self.path=='/v1/teams':self.answer({'teams':[{'id':'team-fixture','name':'Launch team'}]})
            elif self.path.endswith('/folders/root'):self.answer({'id':'root','name':'Home','parent_id':None})
            else:self.answer({'members':[],'folders':[{'id':'root','name':'Home','parent_id':None}]})
        def do_POST(self):
            body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))));requests.append({'method':'POST','path':self.path,'body':body})
            if self.path.endswith('/chat/completions'):
                if any(m.get('role')=='tool' for m in body['messages']):message={'role':'assistant','content':'ASSIST COMPLETE; no local tasks changed.'}
                else:message={'role':'assistant','content':None,'tool_calls':[{'id':'call_literal','type':'function','function':{'name':body['tools'][0]['function']['name'],'arguments':json.dumps({'item':'AI quoted café'})}}]}
                self.answer({'choices':[{'message':message,'finish_reason':'stop'}]})
            else:self.answer({'id':'created','name':body.get('name','')})
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Provider);server.daemon_threads=True
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='doin command quotes ') as tmp:
            base=pathlib.Path(tmp).resolve();config=base/'config';storage=base/'personal';fixture=base/'fixture with spaces.py';log=base/'mcp requests.jsonl';fixture.write_text(SERVER)
            env=dict(os.environ,DOIN_CONFIG_DIR=str(config),DOIN_API_KEY='fixture-key',NO_COLOR='1',TERM='dumb')
            endpoint=f'http://127.0.0.1:{server.server_port}'
            def cli(*argv):
                result=subprocess.run([binary,*argv],env=env,capture_output=True,text=True,timeout=15)
                receipts.append({'argv':argv,'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr});assert result.returncode==0,receipts[-1];return result.stdout
            cli('init','--storage',str(storage),'--provider','api','--model','fixture','--endpoint',endpoint+'/v1','--template','simple')
            token=config/'sync.json';token.write_text(json.dumps({'endpoint':endpoint,'token':'fixture-device'}));token.chmod(0o600)
            cli('mcp','add','fixture','--',sys.executable,str(fixture),str(log))
            cli('add','Review release 東京')
            cli('properties','add','Release stage','single_select','Draft,Ready')
            cli('properties','add','Ship date','date')
            cli('properties','add','Owner notes','text')
            rootid=json.loads((storage/'.doin-folder.json').read_text())['id'];before=(storage/'tasks.md').read_bytes()
            env.pop('NO_COLOR',None);env['TERM']='xterm-256color';env['DOIN_NO_ANIMATION']='1'
            master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',30,110,0,0));process=subprocess.Popen([binary],env=env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True);os.close(slave)
            transcript=bytearray()
            def wait(marker,timeout=15,start=0):
                deadline=time.monotonic()+timeout
                while marker.encode() not in transcript[start:]:
                    assert process.poll() is None,transcript.decode(errors='replace')
                    assert time.monotonic()<deadline,(marker,transcript.decode(errors='replace'))
                    if select.select([master],[],[],.1)[0]:transcript.extend(os.read(master,65536))
            def send(text,marker):
                transcript.clear();os.write(master,(text+'\n').encode())
                if text.startswith('/'):
                    submitted_echo='User  '+text;wait(submitted_echo);response_start=transcript.index(submitted_echo.encode())+len(submitted_echo.encode());wait(marker,start=response_start)
                else:wait(marker)
                receipts.append({'command':text,'terminal':transcript.decode(errors='replace')})
            wait('doin')
            send('/folder create '+rootid+' Release café','Folder created')
            child=storage/'Release café';assert child.is_dir();childid=json.loads((child/'.doin-folder.json').read_text())['id']
            send('/folder rename '+childid+' "Release quoted café"','Active folder')
            assert (storage/'Release quoted café').is_dir()
            send('/mcp call fixture lookup {"item":"literal \\"hello\\" café"}','result')
            calls=[r for r in map(json.loads,log.read_text().splitlines()) if r.get('method')=='tools/call'];assert calls[-1]['params']['arguments']=={'item':'literal "hello" café'}
            send('/assist fixture Tell me "quoted" facts','Run this integration tool?')
            send('yes','ASSIST COMPLETE')
            model=[r['body'] for r in requests if r['path'].endswith('/chat/completions')];assert any('Tell me "quoted" facts' in str(m) for m in model)
            send('/team switch team-fixture','Team selected')
            send('/team folder-create "Launch café quoted" root','"id": "created"')
            assert any(r.get('body',{}).get('name')=='Launch café quoted' for r in requests)
            assert (storage/'tasks.md').read_bytes()==before
            send('/team personal','Personal workspace selected')
            send('/set 1 "Owner notes" "literal \\\"quoted\\\" café"','Property saved')
            send('/set 1 "Ship date" 2028-02-29','Property saved')
            after=(storage/'tasks.md').read_bytes();undo=(storage/'.tasks.undo').read_bytes()
            send('/set 1 "Ship date" 2027-02-29','Invalid value')
            assert (storage/'tasks.md').read_bytes()==after and (storage/'.tasks.undo').read_bytes()==undo
            send('/set 1 "Release stage"','Choose · arrows')
            transcript.clear();os.write(master,b'\x1b[B\t');wait('Property saved')
            receipts.append({'picker':'single-select Down+Tab','terminal':transcript.decode(errors='replace')})
            send('/list','Release stage: Ready')
            assert 'Owner notes: literal "quoted" café' in transcript.decode(errors='replace')
            send('/filter property "Release stage" Ready','Review release')
            send('/unset 1 "Release stage"','Property saved')
            send('/undo','Restored previous change')
            assert 'Review release' in cli('filter','property','Release stage','Ready')
            send('/folder create '+rootid+' "unterminated','InvalidCommandArguments')
            assert not (storage/'unterminated').exists()
            final_message=transcript.index(b'InvalidCommandArguments')+len(b'InvalidCommandArguments')
            wait('Enter submit · ↑↓ history',start=final_message)
            receipts.append({'exit_before':{'canonical':bool(termios.tcgetattr(master)[3]&termios.ICANON)}})
            os.write(master,b'\x04')
            exit_tail=bytearray();deadline=time.monotonic()+5
            while process.poll() is None and time.monotonic()<deadline:
                if select.select([master],[],[],.05)[0]:
                    try:exit_tail.extend(os.read(master,65536))
                    except OSError:break
            receipts.append({'exit_tail':exit_tail.decode(errors='replace'),'exit_poll':process.poll()})
            process.wait(timeout=1)
            receipts.append({'exit':process.returncode,'mcp_calls':calls,'requests':requests})
    except BaseException:
        failure=traceback.format_exc();raise
    finally:
        if process is not None and process.poll() is None:
            os.killpg(process.pid,signal.SIGTERM)
            try:process.wait(timeout=3)
            except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=3)
        if master is not None:os.close(master)
        server.shutdown();server.server_close();thread.join(timeout=3)
        artifact=pathlib.Path('artifacts/commands-pty');artifact.mkdir(parents=True,exist_ok=True)
        (artifact/'results.json').write_text(json.dumps({'command':'python3 tests/commands_pty_e2e.py --bin '+binary,'failure':failure,'receipts':receipts,'requests':requests},indent=2)+'\n')
    print('Composer literal arguments and integrations passed.')
if __name__=='__main__':main()
