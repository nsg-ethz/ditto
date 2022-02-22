/* -*- P4_14 -*- */

/**
 * This is the data-plane implementation of ditto as presented in this paper:
 * 
 * Roland Meier, Vincent Lenders, Laurent Vanbever. 
 * ditto: WAN Traffic Obfuscation at Line Rate.
 * NDSS 2022.
 *
 * The code is intended to run on Intel Tofino switches and it was developed and tested with SDE 8.9.
 * 
 * In case of problems or questions contact Roland Meier (meierrol@ethz.ch)
 */

#ifdef __TARGET_TOFINO__
#include <tofino/constants.p4>
#include <tofino/intrinsic_metadata.p4>
#include <tofino/primitives.p4>
#include <tofino/stateful_alu_blackbox.p4>
#else
#error This program is intended to compile for Tofino P4 architecture only
#endif

#define IN_SECTION_TOP

/**
 * include constants from the custom file and the auto-generated code
 */
#include "include/device_constants.c"
#include "include/preprocessor_macros_tofino.c"
#include "include/generated/add_padding.p4"


#undef IN_SECTION_TOP
/******************************************************************************
 ***********************  H E A D E R S  **************************************
 ******************************************************************************/
#define IN_SECTION_HEADERS

/**
 * include header definitions from the custom file and the auto-generated code
 */
#include "include/headers.p4"
#include "include/generated/add_padding.p4"


#undef IN_SECTION_HEADERS
/******************************************************************************
 ***********************  M E T A D A T A  ************************************
 ******************************************************************************/
#define IN_SECTION_METADATA


header_type custom_metadata_t {
    fields {
        needs_obfuscation:      1;  // 1 if the packet needs to be obfuscated
                                    // otherwise just forward it 
                                    // (e.g. for circulated chaff traffic)

        needs_deobfuscation:    1;  // 1 if the packet needs to be de-obfuscated

        traffic_type:           4;  // 1 = real traffic; 2 = chaff traffic 

        target_size:           16;  // target size of the obfuscated packet in B

        bytes_to_add:          12;  // number of padding bytes to add

        tmp_add_bytes:         16;  // temporary value for workaround
                                    // to check if the packt is too big

        packet_iterator:        8;  // number each packet according to a
                                    // cyclic pattern for load balancing
    }
}
metadata custom_metadata_t custom_metadata;

header_type clone_metadata_t {
    fields {
        mirror_session_id: 32;
    }
}
metadata clone_metadata_t clone_metadata;

#include "include/generated/add_padding.p4"


#undef IN_SECTION_METADATA
/******************************************************************************
 ***********************  P A R S E R  ****************************************
 ******************************************************************************/
#define IN_SECTION_PARSER

#include "include/generated/add_padding.p4"


#undef IN_SECTION_PARSER
/******************************************************************************
 **************  R E G I S T E R S                     ************************
 ******************************************************************************/
#define IN_SECTION_REGISTERS

/*=============  queue distribution  =========================================*/
register reg_packet_iterator {
    width:           32;
    instance_count : 16;
}

blackbox stateful_alu packet_iterator {
    reg:                    reg_packet_iterator;
    condition_lo:           register_lo < NUM_QUEUES_MINUS_1;

    update_lo_1_predicate:  condition_lo;
    update_lo_1_value:      register_lo + 1;

    update_lo_2_predicate:  not condition_lo;
    update_lo_2_value:      0;

    output_value:           alu_lo;
    output_dst:             custom_metadata.packet_iterator;
}


#undef IN_SECTION_REGISTERS
/******************************************************************************
 **************  T A B L E S  A N D  A C T I O N S   **************************
 ******************************************************************************/
#define IN_SECTION_ACTIONS

/*=============  Init  =======================================================*/

/**
 * set prototype / dummy parameters for tests
 * this action should be empty in the end
 */
// action set_prototype_parameters() {
// }
// TABLE_WITH_SINGLE_DO_ACTION(set_prototype_parameters)

/**
 * initialize custom metadata with default values
 */
action set_default_values() { 
    modify_field(custom_metadata.bytes_to_add,0);
    modify_field(custom_metadata.needs_deobfuscation,0);
}
TABLE_WITH_SINGLE_DO_ACTION(set_default_values)


/*=============  General actions   ===========================================*/

action _NoAction() {
}

/**
 * drop a packet by setting the metadata and a custom metadata field
 */
action droppacket() {
    modify_field(ig_intr_md_for_tm.drop_ctl, 1);
}
TABLE_WITH_SINGLE_DO_ACTION(droppacket)

/**
 * set ethertype to IPv4
 */
action set_ethertype_ipv4() {
    modify_field(ethernet.etherType, 0x0800);
}
TABLE_WITH_SINGLE_DO_ACTION(set_ethertype_ipv4)


/*=============  Forwarding   ================================================*/

/**
 * forward a packet directly to a specific egress port
 * _without obfuscating it_
 */
action forward(egress_port) {
    modify_field(ig_intr_md_for_tm.ucast_egress_port, egress_port);
    modify_field(custom_metadata.needs_obfuscation, 0);
}

/**
 * forward a packet to a specific egress port
 * after obfuscating it
 */
action forward_and_obfuscate(egress_port) {
    modify_field(ig_intr_md_for_tm.ucast_egress_port, egress_port);
    modify_field(custom_metadata.needs_obfuscation, 1);
}

/**
 * forward a packet to a specific egress port
 * after removing the obfuscation
 */
action forward_and_deobfuscate(egress_port) {
    modify_field(ig_intr_md_for_tm.ucast_egress_port, egress_port);
    modify_field(custom_metadata.needs_obfuscation, 0);
    modify_field(custom_metadata.needs_deobfuscation, 1);
}

/**
 * forward based on the destination MAC address
 */
table fwd_dmac {
    reads {
        ethernet.dstAddr: exact;
    }
    actions {
        forward;
        forward_and_obfuscate;
        forward_and_deobfuscate;
        droppacket;
        _NoAction;
    }
    size: 256;
}

/**
 * forward based on the ingress port
 */
table fwd_port {
    reads {
        ig_intr_md.ingress_port: exact;
    }
    actions {
        forward;
        forward_and_obfuscate;
        forward_and_deobfuscate;
        droppacket;
        _NoAction;
    }
    size: 64;
}

/*=============  Add padding_meta header   ===================================*/

/**
 * add the padding_meta header after the ethernet header
 * (i.e. in case there is no evaluation_meta header)
 * need to split this in two actions because it cannot run in parallel
 */
action add_padding_meta_1_eth() {
    add_header(padding_meta);
    add(padding_meta.totalLen, ipv4.totalLen, 14); // IP size + 14 bytes from ethernet
    modify_field(padding_meta.timestamp_in, ig_intr_md_from_parser_aux.ingress_global_tstamp);
    modify_field(padding_meta.recirculations,0);
    modify_field(padding_meta.next_etherType, ethernet.etherType);
}
TABLE_WITH_SINGLE_DO_ACTION(add_padding_meta_1_eth)

action add_padding_meta_2_eth() { 
    add(padding_meta.origLen, ipv4.totalLen, 14); //IP size + 14 bytes from ethernet
    modify_field(ethernet.etherType, ETHERTYPE_PADDING_META);
}
TABLE_WITH_SINGLE_DO_ACTION(add_padding_meta_2_eth)

/**
 * add the padding_meta header after the evaluation_meta header
 * (i.e. in case there is an evaluation_meta header)
 * need to split this in two actions because it cannot run in parallel
 */
action add_padding_meta_1_eval() {
    add_header(padding_meta);
    add(padding_meta.totalLen, ipv4.totalLen, 14); //IP size + 14 bytes from ethernet
    modify_field(padding_meta.timestamp_in, ig_intr_md_from_parser_aux.ingress_global_tstamp);
    modify_field(padding_meta.instance_type, INSTANCE_FIRSTPASS);
    modify_field(padding_meta.recirculations,0);
    modify_field(padding_meta.next_etherType, evaluation_meta.next_etherType);
}
TABLE_WITH_SINGLE_DO_ACTION(add_padding_meta_1_eval)

action add_padding_meta_2_eval() {   
    add(padding_meta.origLen, ipv4.totalLen, 14); //IP size + 14 bytes from ethernet
    modify_field(evaluation_meta.next_etherType, ETHERTYPE_PADDING_META);
}
TABLE_WITH_SINGLE_DO_ACTION(add_padding_meta_2_eval)

/**
 * remove padding_meta header
 * attention: this does not reset the ethertype field
 */
action remove_padding_meta() {
    remove_header(padding_meta);
}
TABLE_WITH_SINGLE_DO_ACTION(remove_padding_meta)

/**
 * set next_etherType in padding meta header 
 * depending on how many bytes of padding need to be added
 */
action padding_meta_set_next_etherType(next_etherType) {
    modify_field(padding_meta.next_etherType,next_etherType);
}

table set_padding_meta_next_etherType {
    reads {
        custom_metadata.bytes_to_add: range;
    } 
    actions {
        _NoAction;
        padding_meta_set_next_etherType;
    }
    default_action: _NoAction;
    size: 12;
}

/*=============  Cloning   ===================================================*/

/**
 * list with metadata which gets passed when the packet is cloned
 */
field_list clone_metadata_list {
    clone_metadata.mirror_session_id;
}

/**
 * clone the packet with a given session_id and the above clone_metadata_list
 * we will set the session id eqal to the egress port to which the mirroring
 * session is attached.
 */
action clone_to_port(session_id) {
    modify_field(clone_metadata.mirror_session_id,session_id);
    clone_ingress_pkt_to_egress(session_id,clone_metadata_list);
}

/**
 * clone packets from one port to another
 */
table clone_port {
    reads {
        ig_intr_md.ingress_port: exact;
    }
    actions {
        clone_to_port;
        _NoAction;
    }
    size: 64;
}

/*=============  Packet iterator   ===========================================*/

/**
 * assigns each packet a number between 0 and NUM_QUEUES_MINUS_1
 */
action update_packet_iterator() {
    // packet_iterator.execute_stateful_alu(padding_meta.traffic_type);
    modify_field(custom_metadata.packet_iterator, 0);
}

table packet_iterator {
    reads {
        ig_intr_md.ingress_port: exact;
    }
    actions {
        update_packet_iterator;
        _NoAction;
    }
    size: 32;
}

/*=============  Priority queues   ===========================================*/

/**
 * set the qid metadata field for priority queueing
 * each queue will have a priority
 * currently: 2 queues (quid 0 and 1)
 * higher qid has higher priority
 */
action set_priority(priority) {
    modify_field(ig_intr_md_for_tm.qid, priority); 
}

/**
 * set priority based on ingress port
 */
table priority {
    reads {
        ig_intr_md.ingress_port: exact;
    }
    actions {
        set_priority;
        _NoAction;
    }
    size: 16;
}

/**
 * set priority based on ingress port and packet iterator
 */
table distribute_to_queues {
    reads {
        ig_intr_md.ingress_port: exact;
        custom_metadata.packet_iterator: exact;
    }
    actions {
        set_priority;
        _NoAction;
    }
    size: 64;
}

/*=============  Setting traffic types   =====================================*/

/**
 * set traffic type field in metadata
 */
action set_traffic_type(traffic_type, instance_type, needs_obfuscation) {
    modify_field(padding_meta.traffic_type, traffic_type);
    modify_field(padding_meta.instance_type, instance_type);
    modify_field(custom_metadata.needs_obfuscation, needs_obfuscation);
}

/**
 * set instance type field in metadata
 * (do not modify traffic type because this was set in the first pass)
 */
action set_instance_type(instance_type, needs_obfuscation) {
    modify_field(padding_meta.instance_type, instance_type);
    modify_field(custom_metadata.needs_obfuscation, needs_obfuscation);
}

/**
 * set traffic type based on ingress port
 */
table traffic_type {
    reads {
        ig_intr_md.ingress_port: exact;
    }
    actions {
        set_traffic_type;
        set_instance_type;
        _NoAction;
    }
    size: 32;
}

/**
 * table to check if the packet needs to be recirculated.
 * range match: if bytes_to_add between 0 and MAX_PADDING_BYTES -> _NoAction (via table entry)
 * else: mark_packet_for_recirculation (via default action)
 */
table ignore_toobigpackets {
    reads {
        padding_meta.origLen: range;
    }
    actions {
        _NoAction;
    }
    default_action: droppacket;
    size: 1;
}

/*=============  Pattern state machine and padding   =========================*/

/**
 * set the target size in the metadata according to the state properties
 */
action set_state_properties_priority(egress_port,state_index,qid,target_size) {
    modify_field(custom_metadata.target_size, target_size);
    modify_field(padding_meta.state_index, state_index);
    modify_field(ig_intr_md_for_tm.qid, qid);
    modify_field(ig_intr_md_for_tm.ucast_egress_port, egress_port);
    subtract(custom_metadata.bytes_to_add, target_size, padding_meta.totalLen);
}

action set_state_properties_roundrobin(egress_port,qid) {
    modify_field(ig_intr_md_for_tm.qid, qid);
    modify_field(ig_intr_md_for_tm.ucast_egress_port, egress_port);
}

table assign_to_queue {
    reads {
        padding_meta.traffic_type: exact;
        padding_meta.instance_type: exact;
        padding_meta.totalLen: range;
        custom_metadata.packet_iterator: exact;
    }
    actions {
        set_state_properties_priority;
        set_state_properties_roundrobin;
        droppacket;
    }
    default_action: droppacket; // drop the packet if it doesn't fit in a queue
    size: 1024;
}

/**
 * prepare workaround for `if custom_metadata.target_size >= padding_meta.totalLen)`:
 * 1. tmp_add_bytes = max(target_size, totalLen)
 * 2. check if tmp_add_bytes == target_size
 */
action prepare_packettoobig_decision() {
    max(custom_metadata.tmp_add_bytes, custom_metadata.target_size, padding_meta.totalLen);
}
TABLE_WITH_SINGLE_DO_ACTION(prepare_packettoobig_decision)

/**
 * compute the number of bytes that need to be added as padding
 * bytes_to_add = target_size - totalLen
 */
action compute_bytes_to_add() {
    subtract(custom_metadata.bytes_to_add, custom_metadata.target_size, padding_meta.totalLen);
}
TABLE_WITH_SINGLE_DO_ACTION(compute_bytes_to_add)

/**
 * compute the number of bytes that were added (for deobfuscation)
 * bytes_to_add = target_size - totalLen
 */
action compute_bytes_added() {
    subtract(custom_metadata.bytes_to_add, padding_meta.totalLen, padding_meta.origLen);
}
TABLE_WITH_SINGLE_DO_ACTION(compute_bytes_added)

/**
 * subtract the length of the padding_meta header from the number of bytes
 * bytes_to_add -= PADDING_META_LEN
 */
action subtract_padding_meta_size() {
    subtract_from_field(custom_metadata.bytes_to_add, PADDING_META_LEN);
}
TABLE_WITH_SINGLE_DO_ACTION(subtract_padding_meta_size)

/**
 * table to check if the packet needs to be recirculated.
 * range match: if bytes_to_add between 0 and MAX_PADDING_BYTES -> _NoAction (via table entry)
 * else: mark_packet_for_recirculation (via default action)
 */
table recirculation_decision {
    reads {
        custom_metadata.bytes_to_add: range;
    }
    actions {
        _NoAction;
    }
    default_action: mark_packet_for_recirculation(RECIRCULATION_PORT_1);
    size: 8;
}

/**
 * mark packet for recirculation:
 * - adjust info in padding_meta header
 * - set egress port to recirculation port
 */
action mark_packet_for_recirculation(recirculation_port){
    add_to_field(padding_meta.recirculations, 1);
    modify_field(ig_intr_md_for_tm.ucast_egress_port, recirculation_port); 
}
TABLE_WITH_SINGLE_DO_ACTION(mark_packet_for_recirculation)

/**
 * mark packet for recirculation:
 * - set egress port to recirculation port
 */
action mark_packet_for_recirculation_deobfuscation(){
    subtract_from_field(padding_meta.recirculations, 1);
    modify_field(ig_intr_md_for_tm.ucast_egress_port, RECIRCULATION_PORT_2);
}
TABLE_WITH_SINGLE_DO_ACTION(mark_packet_for_recirculation_deobfuscation)

/**
 * set field in the padding_meta header to mark packet as done
 */
action mark_packet_as_done(){
    modify_field(padding_meta.instance_type, INSTANCE_DONE);
}
TABLE_WITH_SINGLE_DO_ACTION(mark_packet_as_done)

/**
 * TODO
 */
action handle_spoofed_packet_size(){
    // drop()
}
TABLE_WITH_SINGLE_DO_ACTION(handle_spoofed_packet_size)


/**
 * table to drop chaff packets on de-obfuscation
 */
table deobfuscation_blocklist {
    reads {
        padding_meta.traffic_type: exact;
    }
    actions {
        _NoAction;
        droppacket;
    }
    size: 64;
}

action set_padding_meta_next_etherType(etherType) { 
    modify_field(padding_meta.next_etherType, etherType); 
}
table deobfuscation_determine_next_ethertype {
    reads {
        custom_metadata.bytes_to_add: range;
    }
    actions {
        _NoAction;
        set_padding_meta_next_etherType;
    }
    size: 16;
}


/**
 * auto-generated tables and actions to add padding
 */
#include "include/generated/add_padding.p4"

#undef IN_SECTION_ACTIONS


/******************************************************************************
 **************  I N G R E S S   P R O C E S S I N G   ************************
 ******************************************************************************/

control ingress {
    #define IN_SECTION_INGRESS

    /**
     * set default values for metadata and
     * prototype / dummy parameters for tests
     */
    apply(do_set_default_values);
    // apply(do_set_prototype_parameters);

    /**
     * forward packets based on dst mac or ingress port
     * table entries also specify whether a packet needs to be obfuscated
     */
    // apply(fwd_dmac);
    apply(fwd_port);

    /**
     * set traffic type based on ingress port
     */
    apply(traffic_type);

    /**
     * clone packets from one port to another (based on the ingress port)
     */
    apply(clone_port);

    if (custom_metadata.needs_deobfuscation == 1) {

        /**
         * stores the number of added bytes in custom_metadata.bytes_to_add
         */
        apply(do_compute_bytes_added);

        apply(do_remove_padding_headers);

        if (padding_meta.recirculations == 0) {
            apply(do_remove_padding_meta);
            apply(do_set_ethertype_ipv4);
        }
        else { // recirculations > 0
            apply(deobfuscation_determine_next_ethertype);
            apply(do_mark_packet_for_recirculation_deobfuscation); // recirculations --,  recirculate
        }

        apply(deobfuscation_blocklist);
    }

    else {
        /**
        * we only look at IPv4 packets.
        * if there is no padding_meta header, we add it here
        */
        if ((valid(ipv4)) and (not valid(padding_meta))) {

            /**
            * if there is an evaluation_meta header, we add the padding_meta header after it
            * otherwise, we add it after the ethernet header.
            * Adding the padding_meta header happens in 2 stages because some computations cannot be parallelized
            */
            if (valid(evaluation_meta)) {
                apply(do_add_padding_meta_1_eval);
                apply(do_add_padding_meta_2_eval); 
            }
            else {
                apply(do_add_padding_meta_1_eth);
                apply(do_add_padding_meta_2_eth);
            }
        }

        /**
        * if there is a padding_meta header (it was added above or the packet was recirculated)
        */
        if (valid(padding_meta)) {

            /**
            * drop packets which are too big to fit into the pattern at any time
            */
            if (custom_metadata.needs_obfuscation == 1) {
                apply(ignore_toobigpackets);
            }

            /**
            * check if the packet needs obfuscation.
            * If yes, we execute the state machine
            */
            if (custom_metadata.needs_obfuscation == 1) {

                /**
                * update packet iterator and
                * set priority based on ingress port and port iterator
                */
                apply(packet_iterator);
                apply(assign_to_queue);

                /**
                * if the packet passes for the first time, we add the padding
                * (and then put it into the priority queue)
                */
                if (padding_meta.instance_type == INSTANCE_FIRSTPASS) {
                    /**
                    * check if the packet is bigger than the one we need
                    * workaround for `if custom_metadata.target_size >= padding_meta.totalLen)`:
                    * 1. tmp_add_bytes = max(target_size, totalLen)
                    * 2. check if tmp_add_bytes == target_size
                    */
                    apply(do_prepare_packettoobig_decision);
                    if (custom_metadata.tmp_add_bytes == custom_metadata.target_size ) { // packet is smaller than target size
                        
                        /**
                        * compute the number of bytes that need to be added as padding
                        * and store it in custom_metadata.bytes_to_add
                        */
                        apply(do_compute_bytes_to_add);

                        /**
                        * subtract the length of the padding_meta header from the number of bytes
                        * custom_metadata.bytes_to_add -= PADDING_META_LEN
                        */
                        apply(do_subtract_padding_meta_size);
                    }
                    
                    /**
                    * check if we can add enough padding to the packet
                    * `if custom_metadata.bytes_to_add > MAX_PADDING_BYTES)`: recirculate
                    * (implemented through a range match in the table)
                    */
                    apply(recirculation_decision);

                    /**
                    * include auto-generated code (probably nothing at this point)
                    */
                    #include "include/generated/add_padding.p4"
                }


                /**
                * in the second pass, the packet will go into the RR queue
                * and we do not need to do anything here
                */
                else if (padding_meta.instance_type == INSTANCE_SECONDPASS) {
                }
            }
        }
    }

    #undef IN_SECTION_INGRESS
}


/******************************************************************************
 ****************  E G R E S S   P R O C E S S I N G   ************************
 ******************************************************************************/
 
control egress {
    #define IN_SECTION_EGRESS

    /**
     * make sure that the packet has a padding_meta header
     */
    if (valid(padding_meta)) {
        
        /**
         * TODO: Check if the packet size was correct.
         * since we know the actual packet size only after the TM, we used the IP length field before.
         * At this point, we can check if the IP length was set correclty.
         */
        // if (eg_intr_md.pkt_length != padding_meta.origLen) {
        //     apply(do_handle_spoofed_packet_size);
        // }

        /**
         * if the packet needs obufscation, 
         * apply the add_padding tables from the auto-generated code
         */
        if (custom_metadata.needs_obfuscation == 1) {

            /**
             * we add the padding in the first pass (and in the recirculations)
             */
            if (padding_meta.instance_type == INSTANCE_FIRSTPASS) {

                apply(set_padding_meta_next_etherType);

                #include "include/generated/add_padding.p4"
            }

            /**
             * mark packet as done if it passes the second time (i.e. through the round-robin queues)
             */
            if (padding_meta.instance_type == INSTANCE_SECONDPASS) {
                apply(do_mark_packet_as_done);
            }
        }
    }

    #undef IN_SECTION_EGRESS
}
