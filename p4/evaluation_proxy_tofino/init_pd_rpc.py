# import os

# from mirror_test.p4_pd_rpc.ttypes import *

# from conn_mgr_pd_rpc.ttypes import *
# from mirror_pd_rpc.ttypes import *
# from mc_pd_rpc.ttypes import *
# from devport_mgr_pd_rpc.ttypes import *
# from res_pd_rpc.ttypes import *
# from ptf_port import *

dev_id = 0
# swports = [1,2,3,4,5]
# sids = [1,2,3,4,5]

import socket
device_name = socket.gethostname()

print "device name %s" % device_name

# -------------------------- cloning ----------------------

if device_name == "tofino3":
    swports = [144, 152, 160, 168, 176, 184]
else:
    print "invalid device name"

sids = swports

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
# shdl = conn_mgr.client_init()
shdl = sess_hdl

for port,sid in zip(swports, sids):
    info = mirror_session(  mirror.MirrorType_e.PD_MIRROR_TYPE_NORM,
                            mirror.Direction_e.PD_DIR_INGRESS,
                            sid,
                            port,
                            True)
    mirror.session_create(shdl, dt, info)
    print "created mirroring session %i for port %i" % (sid,port)

# -------------------------- traffic shaping ----------------------

# for port in swports:
#     tm.thrift.tm_set_port_shaping_rate(0, port, pps=False, rate=8000000, burstsize=1000)
#     tm.thrift.tm_enable_port_shaping(dev_id, port)
#     print "enable traffic shaping for port %i" % port