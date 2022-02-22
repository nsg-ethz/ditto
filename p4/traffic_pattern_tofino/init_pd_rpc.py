# import os

# from mirror_test.p4_pd_rpc.ttypes import *

# from conn_mgr_pd_rpc.ttypes import *
# from mirror_pd_rpc.ttypes import *
# from mc_pd_rpc.ttypes import *
# from devport_mgr_pd_rpc.ttypes import *
# from res_pd_rpc.ttypes import *
# from ptf_port import *

dev_id = 0

import json
import socket
device_name = socket.gethostname()

print "device name %s" % device_name


# -------------------------- read config ----------------------
script_path = "/home/tofino/ditto/p4/traffic_pattern_tofino/"

infodict_path = script_path+'pd_rpc_info_%s.json' % device_name

with open(infodict_path) as json_file:
    info_dict = json.load(json_file)
    # print info_dict
    print "use info in %s" % infodict_path


# -------------------------- cloning ----------------------

swports = info_dict["ports_cloning"]
sids = info_dict["ports_cloning"]

num_queues_faketraffic = 2
fake_queue_ids = range(num_queues_faketraffic)

def mirror_session(mir_type, mir_dir, sid, egr_port=0, egr_port_v=False,
                   egr_port_queue=0, packet_color=0, mcast_grp_a=0,
                   mcast_grp_a_v=False, mcast_grp_b=0, mcast_grp_b_v=False,
                   max_pkt_len=0, level1_mcast_hash=0, level2_mcast_hash=0,
                   mcast_l1_xid=0, mcast_l2_xid=0, mcast_rid=0, cos=0, c2c=0, extract_len=0, timeout=0,
                   int_hdr=[]):
  return mirror.MirrorSessionInfo_t(mir_type,
                             mir_dir,
                             sid,
                             egr_port,
                             egr_port_v,
                             egr_port_queue,
                             packet_color,
                             mcast_grp_a,
                             mcast_grp_a_v,
                             mcast_grp_b,
                             mcast_grp_b_v,
                             max_pkt_len,
                             level1_mcast_hash,
                             level2_mcast_hash,
                             mcast_l1_xid,
                             mcast_l2_xid,
                             mcast_rid,
                             cos,
                             c2c,
                             extract_len,
                             timeout,
                             int_hdr,
                             len(int_hdr))



dt = DevTarget_t(dev_id, hex_to_i16(0xFFFF))
shdl = sess_hdl


for port,sid in zip(swports, sids):
    print "create mirroring session %i for port %i" % (sid,port)
    
    info = mirror_session(  mirror.MirrorType_e.PD_MIRROR_TYPE_NORM,
                            mirror.Direction_e.PD_DIR_INGRESS,
                            sid,
                            port,
                            True,
                            egr_port_queue = 0)

    if device_name == "tofino1":
        mirror.session_create(info, sess_hdl=shdl, dev_tgt=dt)
    else:
        mirror.session_create(shdl, dt, info)





# -------------------------- priority queues ----------------------

ports = info_dict["ports_priorityqueues"]
num_queues = 2

#Queue identifiers
queue_id = {i:i for i in range(num_queues)}

for port in ports:
    print "configure priority queueing for port %i with %i queues" % (port, num_queues)
    mapping_default = tm.thrift.tm_get_port_q_mapping(dev_id, port)

    qmap = tm.q_map_t(*range(num_queues))

    tm.thrift.tm_set_port_q_mapping(dev_id, port, num_queues, qmap)

    for i in range(num_queues):
        tm.thrift.tm_set_q_sched_priority(dev_id, port, queue_id[i], i+1)

# -------------------------- round robin queues ----------------------

ports = info_dict["ports_rrqueues"]
pattern = info_dict["config"]["pattern_sequence"]
num_queues = len(pattern)

#Queue identifiers
queue_id = {i:i for i in range(num_queues)}

qmap = tm.q_map_t(*range(num_queues))

for port in ports:
    print "configure round-robin queueing for port %i with %i queues" % (port, num_queues)
    
    for i in range(num_queues):
        tm.thrift.tm_set_q_sched_priority(dev_id, port, queue_id[i], 1)
        
        dwrr_weight = 1
        tm.thrift.tm_set_q_dwrr_weight(dev_id, port, queue_id[i], dwrr_weight)




# -------------------------- traffic shaping ----------------------
for (state_index, port) in info_dict["state_index_to_port"].items():
    state_index = int(state_index)
    margin = .01 # safety margin for rate to avoid congesting the rr queues
    rate = 100000000. / sum(info_dict["config"]["pattern_sequence"]) * info_dict["config"]["pattern_sequence"][state_index] * (1-margin)

    print "configure rate %i for port %i" % (rate, port)
    tm.thrift.tm_enable_port_shaping(dev_id, port)
    tm.thrift.tm_set_port_shaping_rate(dev_id, port, pps=False, rate=rate, burstsize=10000)