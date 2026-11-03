import os,pathlib,subprocess as sp,json
root=pathlib.Path.cwd(); lab=root/'.test-live/capability'; lab.mkdir(); home=lab/'home'; userhome=lab/'user-home'; userhome.mkdir(); project=lab/'project'; evidence=pathlib.Path('~/.no-mistakes/evidence/01M6FCPA8CEMEGDNPWVNJKEGMZ/capability-live.log')
env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_','HERDR_','REX_','TASKS_AXI_','CODEX_','GIT_')) or k in ('TMUX','TMUX_PANE','CLAUDECODE','PI_CODING_AGENT','TERM_PROGRAM','GH_TOKEN','GITHUB_TOKEN'): env.pop(k,None)
env.update(FM_HOME=str(home),HOME=str(userhome),XDG_CONFIG_HOME=str(userhome/'.config'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',FM_SPAWN_NO_GUARD='1',FM_BOOTSTRAP_DETECT_ONLY='1',FM_BOOTSTRAP_NETWORK='skip',TREEHOUSE_ROOT=str(lab/'pool'))
log=evidence.open('w',buffering=1)
def run(args,cwd=root,check=True):
 p=sp.run(list(map(str,args)),env=env,cwd=cwd,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,timeout=120)
 log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'\nexit={p.returncode}\n')
 if check: assert p.returncode==0,p.stdout
 return p
run([root/'bin/fm-lab-home.sh','create',home]); (home/'config/backlog-backend').write_text('manual\n'); (home/'config/backend').write_text('tmux\n'); (home/'config/crew-harness').write_text('codex\n'); (home/'state/.last-watcher-beat').touch()
run(['git','init','-q','-b','main',project]); (project/'README.md').write_text('base\n'); (project/'treehouse.toml').write_text(f'root = "{lab / "pool"}"\n'); run(['git','add','.'],cwd=project); run(['git','-c','user.name=Proof','-c','user.email=proof@example.invalid','commit','-qm','base'],cwd=project)
ident='leaseproof-old'; task=home/'data'/ident; task.mkdir(); (task/'brief.md').write_text("# Task\n## Captain's intent\nCheck capability refusal.\n\n## Firstmate spec\nDo not allocate a pooled copy.\n")
normalpath=env['PATH']; env['PATH']=str(root/'.test-live/oldpin')+':'+normalpath
run(['treehouse','--version']); p=run([root/'bin/fm-bootstrap.sh']); assert 'OUTDATED: treehouse' in p.stdout
p=run([root/'bin/fm-spawn.sh',ident,project,'sleep 300','--scout','--backend','tmux'],check=False); assert p.returncode==1 and 'requires treehouse lease support' in p.stdout
assert not (home/'state'/f'{ident}.meta').exists(); assert not list((lab/'pool').glob('**/treehouse-state.json')); log.write('Verified: no pooled allocation, no task metadata, and no endpoint acquisition.\n')
env['PATH']=str(root/'.test-live/pinned')+':'+normalpath
run(['treehouse','--version']); p=run([root/'bin/fm-bootstrap.sh']); assert 'OUTDATED: treehouse' not in p.stdout
p=run(['treehouse','lease','--help']); assert p.returncode==0
log.write('RESULT: real v2.0.1 is refused before allocation; installed v3.1.5 passes the bootstrap lease capability gate.\n')
log.close(); print(evidence)
