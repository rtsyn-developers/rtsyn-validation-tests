import glob, subprocess, pathlib, concurrent.futures, os, tempfile

# Requires the sibling RTSyn source repositories, clang, and libuv development files.
workspace = pathlib.Path(__file__).resolve().parents[3]
os.chdir(os.environ.get("RTSYN_WORKSPACE", str(workspace)))
temporary = tempfile.TemporaryDirectory(prefix="rtsyn-synapse-check-")
out=pathlib.Path(temporary.name)
mods=['rtsyn-runtime','rtsyn-node','rtsyn-port','rtsyn-value','rtsyn-collection','rtsyn-thread','rtsyn-abi','rtsyn-module-loader']
incs=[v for d in mods for v in ['-I'+d+'/include','-I'+d+'/src']]
incs+=['-I'+p for p in glob.glob('rtsyn-runtime/build/.packages/r/rtsyn-defaults/*/*/include')]
src=[f for d in mods for f in glob.glob(d+'/src/**/*.c',recursive=True) if not f.endswith(('xenomai.c','preempt_rt.c','main.c'))]
def compile(f):
 o=out/(f.replace('/','_')+'.o');subprocess.run(['clang','-D_GNU_SOURCE','-std=c2x',*incs,'-c',f,'-o',str(o)],check=True);return str(o)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool: objs=list(pool.map(compile,src))
subprocess.run(['clang','-std=c2x',*incs,'rtsyn-validation-tests/tests/synapse-performance/software_synapse.c',*objs,'-luv','-lm','-ldl','-lpthread','-o',str(out/'check')],check=True)
mods=['hindmarsh-rose-1984-neuron-v2','burst-analysis','amplitude-scale-offset','electrical-synapse']
subprocess.run([str(out/'check'),*['rtsyn-validation-tests/bin/librthybrid-'+m+'.so' for m in mods]],check=True)
