import csv
import importlib.util
import math
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location('synapse_checks', Path(__file__).parents[2] / 'tests/synapse-performance/check_synapse.py')
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


def capture(tmp_path, current, returned):
    path = tmp_path / 'capture.csv'
    with path.open('w') as stream:
        writer = csv.writer(stream)
        writer.writerow(['cycle_id','synaptic_current_na','returned_current_na','telemetry_dropped_events'])
        for i,(a,b) in enumerate(zip(current,returned)):
            writer.writerow([i,a,b,0])
    return path


def test_accepts_delayed_transport_and_control(tmp_path):
    current = [.001 * math.sin(i/10) for i in range(1000)]
    path = capture(tmp_path,current,[0]+current[:-1])
    result = checks.check_capture(path,1000,.001)
    assert result['passed'] and result['lag_cycles'] == 1
    assert checks.check_capture(capture(tmp_path,[0]*1000,[.00001]*1000),1000,0)['passed']


@pytest.mark.parametrize('current,returned', [([0]*1000,[.00005]*1000),
    ([.001*math.sin(i/10) for i in range(1000)],[.00005]*1000),
    ([.01*math.sin(i/10) for i in range(1000)],[.01*math.sin(i/10) for i in range(1000)])])
def test_rejects_zero_current_flat_return_and_clipping(tmp_path,current,returned):
    assert not checks.check_capture(capture(tmp_path,current,returned),1000,.001)['passed']


def test_checks_graph_and_inverse_gain():
    edges=[(0,2,2,0),(1,2,3,0),(2,1,4,0),(2,2,4,1),(3,1,4,2),(3,2,4,3),
           (1,2,5,0),(0,2,5,1),(4,4,5,2),(4,5,5,3),(5,4,6,0),(6,10,1,0)]
    snapshot={'connections':[dict(zip(['connection_id','source_node_id','source_port_id',
        'destination_node_id','destination_port_id'],[i,*e])) for i,e in enumerate(edges)],
        'nodes':[{'node_id':n,'runtime_state':'process'} for n in range(7)],
        'param_values':[{'node_id':n,'param_id':p,'value':v} for n,p,v in
            [(0,3,3.2),(1,3,2.8),(5,0,.001),(6,1,1000),(6,3,.001),(6,19,0),(6,21,0)]]}
    assert checks.check_graph(snapshot,list(range(7)),1000,.001,3.2,2.8)['graph_verified']
    snapshot['param_values'][4]['value']=1
    with pytest.raises(ValueError,match='Parameter'):
        checks.check_graph(snapshot,list(range(7)),1000,.001,3.2,2.8)
    snapshot['connections'][1]['connection_id']=0
    with pytest.raises(ValueError,match='graph'):
        checks.check_graph(snapshot,list(range(7)),1000,.001,3.2,2.8)
