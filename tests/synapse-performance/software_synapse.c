// Software-only regression: real staged modules and runtime, no DAQ/daemon.
#include <assert.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <rtsyn/node.h>
#include <rtsyn/node/runtime/state.h>
#include <rtsyn/runtime.h>
#include <rtsyn/runtime/config.h>
#include <rtsyn/value.h>
static double value(rtsyn_runtime_t *r, unsigned n, unsigned p) {
    double v=0; assert(rtsyn_value_get(rtsyn_runtime_get_node_port_value(r,n,p,RTSYN_ABI_PORT_DIRECTION_OUT),&v)); return v;
}
int main(int argc, char **argv) {
    assert(argc==5);
    void *handles[4]; const rtsyn_abi_node_descriptor_t *descriptors[4];
    for(int i=0;i<4;i++) {
        handles[i]=dlopen(argv[i+1],RTLD_NOW|RTLD_LOCAL);
        if(!handles[i]) { fprintf(stderr,"%s\n",dlerror()); return 1; }
        const rtsyn_abi_node_descriptor_t *(*get)(void)=dlsym(handles[i],"rtsyn_module_get_descriptor");
        assert(get); descriptors[i]=get();
    }
    for(int mode=0;mode<3;mode++) {
        rtsyn_runtime_config_t cfg={.period_ns=100000};
        rtsyn_runtime_t *r=rtsyn_runtime_create(&cfg); assert(r);
        unsigned module[]={0,0,1,1,2,3};
        for(unsigned n=0;n<6;n++) assert(rtsyn_runtime_add_node(r,rtsyn_node_create(descriptors[module[n]],n)));
        for(unsigned n=0;n<6;n++) assert(rtsyn_runtime_transition_node(r,n,RTSYN_NODE_RUNTIME_STATE_START));
        double e=3.2; assert(rtsyn_runtime_set_node_param(r,0,3,&e));
        e=2.8; assert(rtsyn_runtime_set_node_param(r,1,3,&e));
        unsigned edges[][4]={{0,2,2,0},{1,2,3,0},{2,1,4,0},{2,2,4,1},{3,1,4,2},{3,2,4,3},{1,2,5,0},{0,2,5,1},{4,4,5,2},{4,5,5,3},{5,4,1,0}};
        for(unsigned i=0;i<11;i++) assert(rtsyn_runtime_add_connection_between(r,i,edges[i][0],edges[i][1],edges[i][2],edges[i][3]));
        for(int i=0;i<60000;i++) rtsyn_runtime_step(r);
        double g=mode==0?0.:mode==1?.001:-.001;
        assert(rtsyn_runtime_set_node_param(r,5,0,&g));
        double peak=0., range=value(r,4,4); assert(range>0 && isfinite(range));
        for(int i=0;i<60000;i++) {
            double expected=g*1000*(value(r,1,2)-(value(r,0,2)*value(r,4,4)+value(r,4,5)));
            rtsyn_runtime_step(r); double current=value(r,5,4);
            assert(fabs(current-expected)<1e-10);
            assert(isfinite(current)); peak=fmax(peak,fabs(current));
        }
        if(mode==0) assert(peak==0.); else assert(peak>.0001 && peak*1000<9.);
        printf("g=%g uS: peak current=%g nA, initial automatic scale=%g\n",g,peak,range);
        rtsyn_runtime_destroy(r);
    }
    for(int i=0;i<4;i++) dlclose(handles[i]);
}
