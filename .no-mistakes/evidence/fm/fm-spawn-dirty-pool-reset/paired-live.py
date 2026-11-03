import os, pathlib, subprocess as sp, threading, time, json, shutil, traceback
ROOT=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M6FCPA8CEMEGDNPWVNJKEGMZ'); LAB=ROOT/'.test-live'; SOCK=ROOT/'.t'
base=os.environ.copy()
for k in list(base):
    if k.startswith(('FM_','HERDR_','REX_','TASKS_AXI_')) or k in ('TMUX','TMUX_PANE','CLAUDECODE','PI_CODING_AGENT','TERM_PROGRAM'): base.pop(k,None)
base.update(TMUX_TMPDIR=str(SOCK),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Lease proof',GIT_AUTHOR_EMAIL='proof@example.invalid',GIT_COMMITTER_NAME='Lease proof',GIT_COMMITTER_EMAIL='proof@example.invalid')
log=open(E/'paired-live.log','w',buffering=1)
def say(x): print(x,flush=True); log.write(str(x)+'\n')
def run(args,cwd=ROOT,env=None,check=True):
    p=sp.run(list(map(str,args)),cwd=cwd,env=env or base,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,timeout=120)
    if check and p.returncode: raise RuntimeError(f'{args}: {p.returncode}\n{p.stdout}')
    return p

def tm(*args,check=True): return run(['tmux','-L','fm-lab',*args],check=check)
def snapshot(label,wt,project,env):
    obj={'head':run(['git','-C',wt,'rev-parse','HEAD'],env=env).stdout.strip(),'status':run(['git','-C',wt,'status','--porcelain'],env=env).stdout,'content':(wt/'README.md').read_text(),'pool':json.loads(run(['treehouse','status','--json'],cwd=project,env=env).stdout)}
    say(label+' '+json.dumps(obj)); return obj
results=[]
try:
    say('Real installed '+run(['treehouse','--version']).stdout.strip()); say('Target af083db3dcbf09152bf72cc7ab9cb0847aa670a3; baseline 78c69df2b0b231d5cbe849dbc87fce9ea74ba219')
    tm('new-session','-d','-s','firstmate','-x','120','-y','35','-c',ROOT,'/bin/bash --noprofile --norc')
    # Every process is on this named private socket; no default server operations.
    tm('set-option','-g','default-shell','/bin/bash'); tm('set-option','-g','default-command','/bin/bash --noprofile --norc')
    socket=tm('display-message','-p','-t','firstmate','#{socket_path},#{pid},#{session_id}').stdout.strip().replace(',$',',')
    for patched in (False,True):
        name='patched' if patched else 'unpatched'; case=LAB/name; case.mkdir(); home=case/'home'; project=case/'project'; pool=case/'pool'; userhome=case/'user-home'; userhome.mkdir()
        run([ROOT/'bin/fm-lab-home.sh','create',home]); run(['git','init','-q','-b','main',project]); (project/'README.md').write_text('base\n'); (project/'treehouse.toml').write_text(f'root = "{pool}"\n')
        run(['git','add','.'],cwd=project); run(['git','commit','-qm','base'],cwd=project); run(['git','clone','-q','--bare',project,case/'origin.git']); run(['git','remote','add','origin',str(case/'origin.git')],cwd=project)
        env=base.copy(); env.update(FM_HOME=str(home),HOME=str(userhome),XDG_CONFIG_HOME=str(userhome/'.config'),TREEHOUSE_ROOT=str(pool),TMUX=socket,SHELL='/bin/bash',FM_SPAWN_NO_GUARD='1')
        (home/'config/backlog-backend').write_text('manual\n'); (home/'state/.last-watcher-beat').touch()
        ident='leaseproof-'+name; task=home/'data'/ident; task.mkdir(); (task/'brief.md').write_text("# Task\n## Captain's intent\nExercise disposable lease protection.\n\n## Firstmate spec\nNo agent work is requested.\n")
        # New endpoint shells inherit only the isolated environment, not operator state.
        for k,v in env.items():
            if k in ('FM_HOME','HOME','XDG_CONFIG_HOME','TREEHOUSE_ROOT','SHELL','PATH','GIT_CONFIG_GLOBAL','GIT_CONFIG_NOSYSTEM','TMUX_TMPDIR'): tm('set-environment','-g',k,v)
        script=(ROOT if patched else LAB)/'bin/fm-spawn.sh'; target='firstmate:fm-'+ident
        stop=threading.Event(); record={}
        def writer():
            while not stop.is_set():
                p=tm('display-message','-p','-t',target,'#{pane_current_path}',check=False)
                wt=pathlib.Path(p.stdout.strip())
                if p.returncode==0 and str(wt).startswith(str(pool)) and (wt/'README.md').is_file():
                    (wt/'README.md').write_text('base\noutside writer edit for '+name+'\n'); record['wt']=str(wt); return
                time.sleep(.025)
        thread=threading.Thread(target=writer); thread.start()
        say('\n=== '+name+' actual product refusal ===')
        try: p=run([script,ident,project,'sleep 300','--scout','--backend','tmux'],env=env,check=False)
        finally: stop.set(); thread.join()
        say(p.stdout); say('spawn_exit='+str(p.returncode)); assert p.returncode==1 and 'is not clean' in p.stdout, 'did not reach dirty-copy refusal'
        assert record, 'outside writer did not write'; wt=pathlib.Path(record['wt']); before=snapshot('BEFORE EXIT',wt,project,env)
        tm('send-keys','-t',target,'exit','Enter'); time.sleep(1)
        say('AFTER EXIT BEFORE EMPTY ENTER\n'+tm('capture-pane','-p','-S','-60','-t',target).stdout)
        tm('send-keys','-t',target,'Enter'); time.sleep(1)
        after=snapshot('AFTER EXIT PLUS ONE EMPTY ENTER',wt,project,env)
        say('PANE\n'+tm('capture-pane','-p','-S','-60','-t',target).stdout)
        assert before['head']==after['head']
        if patched:
            assert after['content']==before['content'] and after['status']==before['status']; assert after['pool'][0]['lease_holder']==ident
        else: assert after['content']=='base\n' and after['status']=='' and not after['pool'][0]['lease_holder']
        # Close outer project shell normally, then retry the identical public spawn.
        tm('send-keys','-t',target,'exit','Enter'); time.sleep(.5)
        p=run([script,ident,project,'sleep 300','--scout','--backend','tmux'],env=env,check=False); say('RETRY\n'+p.stdout); say('retry_exit='+str(p.returncode)); assert p.returncode==0
        meta=(home/'state'/f'{ident}.meta').read_text(); say('RETRY TASK RECORD\n'+meta); retry=next(line.split('=',1)[1] for line in meta.splitlines() if line.startswith('worktree='))
        final=snapshot('REFUSED COPY AFTER RETRY',wt,project,env)
        assert (retry!=str(wt))==patched
        if patched:
            assert final['content']==before['content'] and final['head']==before['head'] and final['status']==before['status']
            # A retry and prune cannot remove the refused edit. Only explicit release may do so.
            p=run(['treehouse','prune'],cwd=project,env=env); say('PRUNE\n'+p.stdout); kept=snapshot('AFTER PRUNE',wt,project,env); assert kept['content']==before['content']
            p=run(['treehouse','return','--force',wt],cwd=project,env=env); say('EXPLICIT PERSON-AUTHORIZED SCRATCH RELEASE\n'+p.stdout); released=snapshot('AFTER EXPLICIT RELEASE',wt,project,env); assert released['content']=='base\n' and released['status']==''; assert not released['pool'][0]['lease_holder']
            reacquired=run(['treehouse','get','--lease','--lease-holder','explicit-release-reuse'],cwd=project,env=env).stdout.strip(); say('AFTER EXPLICIT RELEASE REACQUIRED '+reacquired); assert reacquired.splitlines()[-1]==str(wt)
        results.append({'case':name,'result':'pass','refused':str(wt),'retry':retry})
        tm('kill-window','-t',target)
    say('RESULTS '+json.dumps(results))
finally:
    p=tm('kill-server',check=False); say('private tmux kill-server exit='+str(p.returncode)); log.close()
    for name in ('patched','unpatched'):
        shutil.rmtree('/tmp/fm-leaseproof-'+name,ignore_errors=True)
