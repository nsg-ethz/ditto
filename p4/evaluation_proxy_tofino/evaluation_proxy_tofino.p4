/* -*- P4_14 -*- */

/**
adds the ingress timestamp to the src mac field of the src mac address, 
(optionally) changes dst mac and does L2 forwarding
*/

#ifdef __TARGET_TOFINO__
#include <tofino/constants.p4>
#include <tofino/intrinsic_metadata.p4>
#include <tofino/primitives.p4>
#include <tofino/stateful_alu_blackbox.p4>
#else
#error This program is intended to compile for Tofino P4 architecture only
#endif

#define ETHERTYPE_EVALUATION_META 0x0887
#define ETHERTYPE_PADDING_META 2184
#define ETHERTYPE_IPV4 2048

#define NUM_LB_LINKS_MINUS_1 1

/*************************************************************************
 ***********************  H E A D E R S  *********************************
 *************************************************************************/

header_type ethernet_t {
    fields {
        dstAddr   : 48;
        srcAddr   : 48;
        etherType : 16;
    }
}

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
        instance_type  :  4;    // firstpass / recirculated / done
        recirculations :  8;    // number of recirculations
        state_index    :  8;    // pattern state index
        est_qdepth     : 24;    // estimated queue occupancy
        next_etherType : 16;
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



/******************************************************************************
 ***********************  M E T A D A T A  ************************************
 ******************************************************************************/

header_type custom_metadata_t {
    fields {
        original_etherType:     16;
        drop:                   1;
        port_iterator:          8;
        packet_limit_exceeded:  1;
        packetsize_limit:      32;
        count_packetsize:       1;
        current_ts:            32;
        packetsize:            16;
    }
}
metadata custom_metadata_t custom_metadata;

header_type clone_metadata_t {
    fields {
        mirror_session_id:      8;
        // egress_port1:           8;
        // egress_port2:           8;
    }
}
metadata clone_metadata_t clone_metadata;

/******************************************************************************
 ***********************  P A R S E R  ****************************************
 ******************************************************************************/
header ethernet_t ethernet;
header evaluation_meta_t evaluation_meta;
header padding_meta_t padding_meta;
header ipv4_t ipv4;

parser start { 
    extract(ethernet);
    return select(ethernet.etherType) {
        ETHERTYPE_EVALUATION_META: parse_evaluation_meta;
        ETHERTYPE_IPV4     : parse_ipv4;
        default: ingress;
     }
}

parser parse_evaluation_meta { 
    extract(evaluation_meta);
    return select(evaluation_meta.next_etherType) {
         ETHERTYPE_PADDING_META: parse_padding_meta;
         ETHERTYPE_IPV4     : parse_ipv4;
         default: ingress;
     }
}

parser parse_padding_meta { 
    extract(padding_meta);
    return select(padding_meta.next_etherType) {
         ETHERTYPE_IPV4     : parse_ipv4;
         default: ingress;
     }
}

parser parse_ipv4 {
    extract(ipv4);
    return ingress;
}

/*************************************************************************
 **************  I N G R E S S   P R O C E S S I N G   *******************
 *************************************************************************/

register reg_sequence_before {
    width:          32;
    instance_count : 1;
}

blackbox stateful_alu update_sequence_before {
    reg:                reg_sequence_before;
    update_lo_1_value:  register_lo + 1;
    output_value:       alu_lo;
    output_dst:         evaluation_meta.sequence_before;
}

register reg_sequence_after {
    width:          32;
    instance_count : 1;
}

blackbox stateful_alu update_sequence_after {
    reg:                reg_sequence_after;
    update_lo_1_value:  register_lo + 1;
    output_value:       alu_lo;
    output_dst:         evaluation_meta.sequence_after;
}

register reg_port_iterator {
    width:          32;
    instance_count : 1;
}

blackbox stateful_alu port_iterator {
    reg:                    reg_port_iterator;
    condition_lo:           register_lo < NUM_LB_LINKS_MINUS_1;

    update_lo_1_predicate:  condition_lo;
    update_lo_1_value:      register_lo + 1;

    update_lo_2_predicate:  not condition_lo;
    update_lo_2_value:      0;

    output_value:           alu_lo;
    output_dst:             custom_metadata.port_iterator;
}

action update_port_iterator() {
    port_iterator.execute_stateful_alu(0);
}

table do_update_port_iterator {
    actions { update_port_iterator; }
    default_action: update_port_iterator;
    size: 0;
}


register reg_packet_limit {
    width:          32;
    instance_count : 1;
}

blackbox stateful_alu packet_limit {
    reg:                    reg_packet_limit;
    condition_lo:           register_lo > 0;

    update_lo_1_predicate:  condition_lo;
    update_lo_1_value:      register_lo - 1;

    update_lo_2_predicate:  not condition_lo;
    update_lo_2_value:      0;

    update_hi_1_predicate:  condition_lo;
    update_hi_1_value:      0;

    update_hi_2_predicate:  not condition_lo;
    update_hi_2_value:      1;

    output_value:           alu_hi;
    output_dst:             custom_metadata.packet_limit_exceeded;
}

action update_packet_limit() {
    packet_limit.execute_stateful_alu(0);
}

table check_packet_limit {
    reads {
        ig_intr_md.ingress_port: exact;
    }
    actions {
        update_packet_limit;
        droppacket;
        NoAction;
    }
    size: 64;
}


register reg_packetsize_limit {
    width:          32;
    instance_count : 1;
}

blackbox stateful_alu packetsize_limit {
    reg:                    reg_packetsize_limit;
    condition_lo:           register_lo > 0;

    update_lo_1_predicate:  condition_lo;
    update_lo_1_value:      register_lo - 1;

    update_lo_2_predicate:  not condition_lo;
    update_lo_2_value:      0;

    update_hi_1_predicate:  condition_lo;
    update_hi_1_value:      0;

    update_hi_2_predicate:  not condition_lo;
    update_hi_2_value:      1;

    output_value:           alu_lo;
    output_dst:             custom_metadata.packetsize_limit;
}

action update_packetsize_limit() {
    packetsize_limit.execute_stateful_alu(0);
    modify_field(custom_metadata.count_packetsize, 1);
}

table packetsize_limit {
    reads {
        ig_intr_md.ingress_port: exact;
    }
    actions {
        update_packetsize_limit;
        droppacket;
        NoAction;
    }
    size: 64;
}


register reg_packetsize_first_ts {
    width:           32;
    instance_count : 1;
}

blackbox stateful_alu packetsize_first_ts {
    reg:                reg_packetsize_first_ts;
    update_lo_1_value:  custom_metadata.current_ts;
    // output_value:       register_lo;
    // output_dst:         custom_metadata.last_ts;
}

action update_packetsize_first_ts() {
    packetsize_first_ts.execute_stateful_alu(0);
}
table do_update_packetsize_first_ts {
    actions { update_packetsize_first_ts; }
    default_action: update_packetsize_first_ts;
    size: 0;
}


register reg_packetsize_last_ts {
    width:           32;
    instance_count : 1;
}

blackbox stateful_alu packetsize_last_ts {
    reg:                reg_packetsize_last_ts;
    update_lo_1_value:  custom_metadata.current_ts;
    // output_value:       register_lo;
    // output_dst:         custom_metadata.last_ts;
}

action update_packetsize_last_ts() {
    packetsize_last_ts.execute_stateful_alu(0);
}
table do_update_packetsize_last_ts {
    actions { update_packetsize_last_ts; }
    default_action: update_packetsize_last_ts;
    size: 0;
}

register reg_packetsize_sum {
    width:           32;
    instance_count : 1;
}

blackbox stateful_alu packetsize_sum {
    reg:                reg_packetsize_sum;
    condition_lo:       (custom_metadata.packetsize_limit > 0);
    update_lo_1_predicate: condition_lo;
    update_lo_1_value:  register_lo + custom_metadata.packetsize;
    // update_lo_1_value:  register_lo + 1;
    // output_value:       register_lo;
    // output_dst:         custom_metadata.last_ts;
}

action update_packetsize_sum() {
    packetsize_sum.execute_stateful_alu(0);
}
table do_update_packetsize_sum {
    actions { update_packetsize_sum; }
    default_action: update_packetsize_sum;
    size: 0;
}


action NoAction() { }

action droppacket() {
    modify_field(ig_intr_md_for_tm.drop_ctl, 1);
    modify_field(custom_metadata.drop, 1);
}
action init_metadata() {
    modify_field(custom_metadata.drop, 0);
    modify_field(custom_metadata.packet_limit_exceeded, 0);
    modify_field(custom_metadata.count_packetsize, 0);
    modify_field(custom_metadata.current_ts, ig_intr_md_from_parser_aux.ingress_global_tstamp);
    add(custom_metadata.packetsize, padding_meta.totalLen, 44);
}

action read_ethertype_eval() {
    modify_field(custom_metadata.original_etherType, evaluation_meta.next_etherType);
}

action read_ethertype_eth() {
    modify_field(custom_metadata.original_etherType, ethernet.etherType);
}

action forward(egress_port) {
    modify_field(ig_intr_md_for_tm.ucast_egress_port, egress_port);
}

action set_evaluation_meta_before() {
    modify_field(ethernet.etherType,ETHERTYPE_EVALUATION_META);

    add_header(evaluation_meta);
    modify_field(evaluation_meta.timestamp_before, ig_intr_md_from_parser_aux.ingress_global_tstamp);
    update_sequence_before.execute_stateful_alu(0);
    modify_field(evaluation_meta.size_before,0);
    // modify_field(evaluation_meta.size_before,eg_intr_md.pkt_length);
    modify_field(evaluation_meta.next_etherType,custom_metadata.original_etherType);
}

action set_evaluation_meta_after() {
    // modify_field(ethernet.etherType,ETHERTYPE_EVALUATION_META);
    modify_field(ethernet.srcAddr,0x123321);

    add_header(evaluation_meta);
    modify_field(evaluation_meta.timestamp_after, ig_intr_md_from_parser_aux.ingress_global_tstamp);
    update_sequence_after.execute_stateful_alu(0);
    modify_field(evaluation_meta.size_after,0);
    // modify_field(evaluation_meta.size_after,eg_intr_md.pkt_length);
    modify_field(evaluation_meta.next_etherType,custom_metadata.original_etherType);
    
}

table do_read_ethertype_eval {
    actions { read_ethertype_eval; }
    default_action: read_ethertype_eval;
    size: 0;
}

table do_read_ethertype_eth {
    actions { read_ethertype_eth; }
    default_action: read_ethertype_eth;
    size: 0;
}

table do_init_metadata {
    actions { init_metadata; }
    default_action: init_metadata;
    size: 0;
}

table fwd_port {
    reads {
        ig_intr_md.ingress_port: exact;
    }
    actions {
        forward;
        droppacket;
        NoAction;
    }
    size: 64;
}

table fwd_ethertype_port {
    reads {
        ig_intr_md.ingress_port: exact;
        ethernet.etherType: exact;
    }
    actions {
        forward;
        droppacket;
        NoAction;
    }
    size: 64;
}

table fwd_port_lb {
    reads {
        ig_intr_md.ingress_port: exact;
        custom_metadata.port_iterator: exact;
    }
    actions {
        forward;
        droppacket;
        NoAction;
    }
    size: 128;
}

table fwd_srcmac_port {
    reads {
        ig_intr_md.ingress_port: exact;
        ethernet.srcAddr: exact;
    }
    actions {
        forward;
        droppacket;
        NoAction;
    }
    size: 256;
}

field_list clone_metadata_list {
    clone_metadata.mirror_session_id;
}

action clone_to_port(session_id) {
    modify_field(clone_metadata.mirror_session_id,session_id);
    clone_ingress_pkt_to_egress(session_id,clone_metadata_list);
}

table clone_port {
    reads {
        ig_intr_md.ingress_port: exact;
    }
    actions {
        clone_to_port;
        NoAction;
    }
    // size: 64;
}

table src_mac_whitelist {
    reads {
        ethernet.srcAddr: exact;
    }
    actions {
        droppacket;
        NoAction;
    }
    // size: 64;
    default_action: droppacket;
}

table traffic_type_port_blacklist {
    reads {
        ig_intr_md.ingress_port: exact;
        padding_meta.traffic_type: exact;
    }
    actions {
        droppacket;
        NoAction;
    }
    size: 128;
}

table set_evaluation_meta_before {
    reads {
        ig_intr_md.ingress_port: exact;
    }
    actions {
        set_evaluation_meta_before;
        NoAction;
    }
    size: 128;
}

table set_evaluation_meta_after {
    reads {
        ig_intr_md.ingress_port: exact;
    }
    actions {
        set_evaluation_meta_after;
        NoAction;
    }
    size: 128;
}



control ingress {
    apply(do_init_metadata);

    apply(do_update_port_iterator);

    // apply(src_mac_whitelist);

    if (valid(padding_meta)) {
        apply(traffic_type_port_blacklist);
    }


    // only if the packet will not be dropped
    // if (ig_intr_md_for_tm.drop_ctl == 0) {
    if (custom_metadata.drop == 0) {
        apply(check_packet_limit);

        if (custom_metadata.packet_limit_exceeded == 0) {
            apply(fwd_port);
            apply(fwd_ethertype_port);
            apply(fwd_port_lb);
            apply(fwd_srcmac_port);
            apply(clone_port);

            if (valid(evaluation_meta)) {
                apply(do_read_ethertype_eval);
            }
            else {
                apply(do_read_ethertype_eth);
            }
        }
    }
}

/*************************************************************************
 ****************  E G R E S S   P R O C E S S I N G   *******************
 *************************************************************************/
control egress {

    apply(packetsize_limit);

    if (custom_metadata.count_packetsize == 1) {
        if (custom_metadata.packetsize_limit == 10000001) {
            apply(do_update_packetsize_first_ts);
        }

        if (custom_metadata.packetsize_limit == 1) {
            apply(do_update_packetsize_last_ts);
        }

        // if (custom_metadata.packet_limit > 0) {
            apply(do_update_packetsize_sum);
        // }
    }

    if (custom_metadata.drop == 0) {
        apply(set_evaluation_meta_before);
        apply(set_evaluation_meta_after);
    }
}
