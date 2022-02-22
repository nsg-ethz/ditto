
"""
script to automatically inject chaff packets of the right size.
usage: 
sudo python inject_chaff_packets.py --interface ens785f0 -vv 
"""

import os, sys, time
import argparse
import math
import json
import bisect
import logging
import random
from scapy.all import *


def setup_logging(loglevel="DEBUG"):
    """Setup basic logging

    Args:
      loglevel (int): minimum loglevel for emitting messages
    """
    logformat = "[%(asctime)s] %(levelname)s:%(name)s:%(message)s"
    logging.basicConfig(level=loglevel, stream=sys.stdout,
                        format=logformat, datefmt="%Y-%m-%d %H:%M:%S")

log = logging.getLogger(__name__)

def send_packet(interface, size, fields):
    if size == 0:
        size = random.randint(50,1500)

    if size < 38:
        log.warning("minimum packet size is 38")
        size = 38

    log.info("send a packet of size %i and src MAC %s" % (size,fields.get("ETH_src","11:01:02:03:04:05")) )

    payload = "x"*(size-38-24+8)

    pkt = Ether(src=fields.get("ETH_src","11:01:02:03:04:05"), dst=fields.get("ETH_dst",'00:01:02:03:04:05')) \
        / IP(src=fields.get("IP_src","1.1.1.1"),dst=fields.get("IP_dst","1.1.1.2")) \
        / TCP(flags=fields.get("TCP_flags",0)) \
        / payload

    sendp(pkt, iface=interface, verbose=False)

def parse_args(args):
    """Parse command line parameters

    Args:
      args ([str]): command line parameters as list of strings

    Returns:
      :obj:`argparse.Namespace`: command line parameters namespace
    """
    parser = argparse.ArgumentParser(
        description="volume obfuscation chaff packet generator")

    parser.add_argument(
        "--interface",
        type=str,
        required=True,
        help="send packet over this interface")
    
    parser.add_argument(
        "-l",
        "--loop",
        dest="loop",
        help="send packets in an infinite loop",
        action="store_true")
    
    parser.add_argument(
        "-v",
        "--verbose",
        dest="loglevel",
        help="set loglevel to INFO",
        action="store_const",
        const=logging.INFO)
    
    parser.add_argument(
        "-vv",
        "--very-verbose",
        dest="loglevel",
        help="set loglevel to DEBUG",
        action="store_const",
        const=logging.DEBUG)
    
    return parser.parse_args(args)



def main(args):
    args = parse_args(args)
    setup_logging(args.loglevel)

    pattern = [533, 1066, 1600]

    while True:
        i = 0
        for size in pattern:
            send_packet(args.interface, min(size - 30, 1500), {"ETH_src": "2:0:0:0:0:%i" % i})
            send_packet(args.interface, min(size - 30, 1500), {"ETH_src": "3:0:0:0:0:%i" % i})
            i += 1
        
        if not args.loop:
            break
    

    
    log.info("done")
    


def run():
    """Entry point for console_scripts
    """
    main(sys.argv[1:])


if __name__ == "__main__":
    run()
