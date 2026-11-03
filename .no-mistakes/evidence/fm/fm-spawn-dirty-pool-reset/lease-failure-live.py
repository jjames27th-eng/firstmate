import os,pathlib,subprocess as sp,threading,time,json,shutil
R=pathlib.Path.cwd(); L=R/'.test-live/lease-failure'; L.mkdir(); H=L/'home'; P=L/'project'; U=L/'user-home'; U.mkdir(); E=pathlib.Path('~/.no-mistakes/evidence/01M6FCPA8CEMEGDNPWVNJKEGMZ/lease-failure-live.log'); log=E.open('w',buffering=1)
env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_','HERDR_','REX_','TASKS_AXI_','GIT_')) or k in ('TMUX','TMUX_PANE','CLAUDECODE','PI_CODING_AGENT','TERM_PROGRAM'): env.pop(k,None)
env.update(TMUX_TMPDIR=str(R/'.t'),FM_HOME=str(H),HOME=str(U),XDG_CONFIG_HOME=str(U/'.config'),TREEHOUSE_ROOT=str(L/'pool'),FM_SPAWN_NO_GUARD='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',SHELL='/bin/bash')
def run(args,cwd=R,check=True):
 p=sp.run(list(map(str,args)),cwd=cwd,env=env,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,timeout=120)
 if check: assert p.returncode==0,(args,p.stdout)
 return p
def tm(*a,check=True): return run(['tmux','-L','fm-lab',*a],check=check)
def say(x): log.write(str(x)+'\n')
run([R/'bin/fm-lab-home.sh','create',H]); (H/'config/backlog-backend').write_text('manual\n'); (H/'state/.last-watcher-beat').touch(); ident='leaseproof-failure'; task=H/'data'/ident; task.mkdir(); (task/'brief.md').write_text("# Task\n## Captain's intent\nCheck lease failure reporting.\n\n## Firstmate spec\nDo not refresh or launch without a lease.\n")
run(['git','init','-q','-b','main',P]); (P/'README.md').write_text('base\n'); (P/'treehouse.toml').write_text(f'root = "{L / "pool"}"\n'); run(['git','add','.'],cwd=P); run(['git','-c','user.name=Proof','-c','user.email=proof@example.invalid','commit','-qm','base'],cwd=P)
stop=threading.Event(); record={}; thread=None
try:
 tm('new-session','-d','-s','firstmate','-x','120','-y','35','-c',R,'/bin/bash --noprofile --norc'); tm('set-option','-g','default-shell','/bin/bash'); tm('set-option','-g','default-command','/bin/bash --noprofile --norc')
 env['TMUX']=tm('display-message','-p','-t','firstmate','#{socket_path},#{pid},#{session_id}').stdout.strip().replace(',$',',')
 for k in ('FM_HOME','HOME','XDG_CONFIG_HOME','TREEHOUSE_ROOT','SHELL','PATH','GIT_CONFIG_GLOBAL','GIT_CONFIG_NOSYSTEM','TMUX_TMPDIR'): tm('set-environment','-g',k,env[k])
 target='firstmate:fm-'+ident
 def writer():
  try:
   while not stop.is_set():
    p=tm('display-message','-p','-t',target,'#{pane_current_path}',check=False); wt=pathlib.Path(p.stdout.strip())
    if str(wt).startswith(str(L/'pool')) and (wt/'README.md').is_file():
     (wt/'README.md').write_text('base\ncompeting writer edit\n'); p=run(['treehouse','lease',wt.parent.name,'--lease-holder','competing-writer'],cwd=P); record.update(wt=str(wt),lease=p.stdout); return
    time.sleep(.025)
  except Exception as exc: record['error']=str(exc)
 thread=threading.Thread(target=writer); thread.start(); p=run([R/'bin/fm-spawn.sh',ident,P,'sleep 300','--scout','--backend','tmux'],check=False); stop.set(); thread.join(); say(p.stdout); say('spawn_exit='+str(p.returncode)); say(json.dumps(record))
 assert p.returncode==1 and 'could not durably lease' in p.stdout; assert 'durable lease protection is unconfirmed' in p.stdout; assert 'was left in place' not in p.stdout; assert 'wt' in record
 wt=pathlib.Path(record['wt']); say('HEAD='+run(['git','rev-parse','HEAD'],cwd=wt).stdout); say('STATUS='+run(['git','status','--porcelain'],cwd=wt).stdout); say('CONTENT='+ (wt/'README.md').read_text()); say('POOL='+run(['treehouse','status','--json'],cwd=P).stdout)
 assert (wt/'README.md').read_text()=='base\ncompeting writer edit\n'; assert not (H/'state'/f'{ident}.meta').exists(); say('RESULT: no refresh or worker launch; failed protection is reported unconfirmed, with no false retained-lease claim.')
finally:
 stop.set()
 if thread: thread.join()
 say('private tmux kill-server exit='+str(tm('kill-server',check=False).returncode)); log.close()
print(E)
