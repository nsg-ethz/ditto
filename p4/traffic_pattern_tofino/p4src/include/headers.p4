

header_type ethernet_t {
    fields {
        dstAddr   : 48;
        srcAddr   : 48;
        etherType : 16;
    }
}

header_type ipv4_t {
    fields {
        version         :  4; 
        ihl             :  4; 
        diffserv        :  8; 
        totalLen        : 16; 
        identification  : 16; 
        flags           :  3; 
        fragOffset      : 13; 
        ttl             :  8; 
        protocol        :  8; 
        hdrChecksum     : 16; 
        srcAddr         : 32;
        dstAddr         : 32;
    }
}

// header_type tcp_t {
//     fields {
//         srcPort         : 16;
//         dstPort         : 16;
//         seqNo           : 32;
//         ackNo           : 32;
//         dataOffset      :  4;
//         reserved        :  3;
//         ns              :  1;
//         cwr             :  1;
//         ece             :  1;
//         urg             :  1;
//         ack             :  1;
//         psh             :  1;
//         rst             :  1;
//         syn             :  1;
//         fin             :  1;
//         window          : 16;
//         checksum        : 16;
//         urgentPointer   : 16;
//     }
// }

// header_type udp_t {
//     fields {
//         srcPort     : 16;
//         dstPort     : 16;
//         len         : 16;
//         checksum    : 16;
//     }
// }

// header_type icmp_t {
//     fields {
//         icmpType    :  8;
//         code        :  8;
//         checksum    : 16;
//         rest        : 32;
//     }
// }

header_type evaluation_meta_t {
    fields {
        timestamp_before    : 48;   // timestamp before obfuscation switch
        timestamp_after     : 48;   // timestamp after obfuscation switch
        sequence_before     : 32;   // seq number before obfuscation switch
        sequence_after      : 32;   // seq number after obfuscation switch
        size_before         : 16;   // size before padding
        size_after          : 16;   // size after padding
        next_etherType      : 16;
    }
}

header_type padding_meta_t {
    fields {   
        timestamp_in   : 48;    // ingress timestamp
        totalLen       : 16;    // total length of the packet
        origLen        : 16;    // original length of the packet
        traffic_type   :  4;    // real traffic or fake
        instance_type  :  4;    // 1: firstpass / 2: secondpass / 3: done
        recirculations :  8;    // number of recirculations
        state_index    :  8;    // pattern state index
        est_qdepth     : 24;    // estimated queue occupancy
        next_etherType : 16;
    }
}

header_type queue_info_t {
    fields {
        egress_port : 16;               // egress port id.
                                        // this field is passed to the deparser
        enq_qdepth : 24;                // queue depth at the packet enqueue
                                        // time.
        enq_congest_stat : 8;           // queue congestion status at the packet
                                        // enqueue time.
        deq_congest_stat : 8;           // queue congestion status at the packet
                                        // dequeue time.
        deflection_flag : 8;            // flag indicating whether a packet is
                                        // deflected due to deflect_on_drop.
        egress_cos : 8;                 // egress cos (eCoS) value.
                                        // this field is passed to the deparser

        enq_tstamp : 32;                // time snapshot taken when the packet
                                        // is enqueued (in nsec).
        deq_qdepth : 24;                // queue depth at the packet dequeue
                                        // time.
        app_pool_congest_stat : 8;      // dequeue-time application-pool
                                        // congestion status. 2bits per
                                        // pool.

        deq_timedelta : 32;             // time delta between the packet's
                                        // enqueue and dequeue time.
        egress_qid : 8;                 // egress (physical) queue id via which
                                        // this packet was served.
        pkt_length : 16;                // Packet length, in bytes


        timestamp_before    : 48;
        timestamp_after     : 48;
        sequence_before     : 32;
        sequence_after      : 32;

        next_etherType : 16;
    }
}

header_type padding1_t {
    fields {
        // padding      : 8;
        // next_etherType : 16;
        next_etherType : 8;
    }
}

header_type padding2_t {
    fields {
        next_etherType : 16;
    }
}

header_type padding4_t {
    fields {
        padding        : 16;
        next_etherType : 16;
    }
}

header_type padding8_t {
    fields {
        padding        : 48;
        next_etherType : 16;
    }
}

header_type padding16_t {
    fields {
        padding      : 112;
        next_etherType :   16;
    }
}

header_type padding32_t {
    fields {
        padding      : 240;
        next_etherType :   16;
    }
}