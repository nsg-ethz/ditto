header ethernet_t  ethernet;
header ipv4_t      ipv4;
header tcp_t       tcp;
header udp_t       udp;

// header padding32_t padding32[NUM_32B_PADS];
header padding32_t padding32_1;
header padding32_t padding32_2;
header padding32_t padding32_3;
header padding32_t padding32_4;


header padding16_t padding16[NUM_16B_PADS];
header padding8_t  padding8[NUM_8B_PADS];
header padding4_t  padding4[NUM_4B_PADS];
header padding2_t  padding2[NUM_2B_PADS];
header padding1_t  padding1[NUM_1B_PADS];


parser start {
    extract(ethernet);
    return select(ethernet.etherType) {
        ETHERTYPE_IPV4     : parse_ipv4;
        ETHERTYPE_32B_PADS : parse_padding32_1;
        ETHERTYPE_16B_PADS : parse_padding16;
        ETHERTYPE_8B_PADS  : parse_padding8;
        ETHERTYPE_4B_PADS  : parse_padding4;
        ETHERTYPE_2B_PADS  : parse_padding2;
        ETHERTYPE_1B_PADS  : parse_padding1;
        default: ingress; 
    }
}



parser parse_padding32_1 {
    extract(padding32_1);
    return select(padding32_1.next_etherType) {
        ETHERTYPE_IPV4     : parse_ipv4;
        ETHERTYPE_32B_PADS : parse_padding32_2;
        ETHERTYPE_16B_PADS : parse_padding16;
        ETHERTYPE_8B_PADS  : parse_padding8;
        ETHERTYPE_4B_PADS  : parse_padding4;
        ETHERTYPE_2B_PADS  : parse_padding2;
        ETHERTYPE_1B_PADS  : parse_padding1;
        default: ingress;
    }
}

parser parse_padding32_2 {
    extract(padding32_2);
    return select(padding32_2.next_etherType) {
        ETHERTYPE_IPV4     : parse_ipv4;
        ETHERTYPE_32B_PADS : parse_padding32_3;
        ETHERTYPE_16B_PADS : parse_padding16;
        ETHERTYPE_8B_PADS  : parse_padding8;
        ETHERTYPE_4B_PADS  : parse_padding4;
        ETHERTYPE_2B_PADS  : parse_padding2;
        ETHERTYPE_1B_PADS  : parse_padding1;
        default: ingress;
    }
}

parser parse_padding32_3 {
    extract(padding32_3);
    return select(padding32_3.next_etherType) {
        ETHERTYPE_IPV4     : parse_ipv4;
        ETHERTYPE_32B_PADS : parse_padding32_4;
        ETHERTYPE_16B_PADS : parse_padding16;
        ETHERTYPE_8B_PADS  : parse_padding8;
        ETHERTYPE_4B_PADS  : parse_padding4;
        ETHERTYPE_2B_PADS  : parse_padding2;
        ETHERTYPE_1B_PADS  : parse_padding1;
        default: ingress;
    }
}

parser parse_padding32_4 {
    extract(padding32_4);
    return select(padding32_4.next_etherType) {
        ETHERTYPE_IPV4     : parse_ipv4;
        // ETHERTYPE_32B_PADS : parse_padding32_2;
        ETHERTYPE_16B_PADS : parse_padding16;
        ETHERTYPE_8B_PADS  : parse_padding8;
        ETHERTYPE_4B_PADS  : parse_padding4;
        ETHERTYPE_2B_PADS  : parse_padding2;
        ETHERTYPE_1B_PADS  : parse_padding1;
        default: ingress;
    }
}

parser parse_padding16 {
    extract(padding16[next]);
    return select(padding16[last].next_etherType) {
        ETHERTYPE_IPV4     : parse_ipv4;
        // ETHERTYPE_32B_PADS : parse_padding32;
        ETHERTYPE_16B_PADS : parse_padding16;
        ETHERTYPE_8B_PADS  : parse_padding8;
        ETHERTYPE_4B_PADS  : parse_padding4;
        ETHERTYPE_2B_PADS  : parse_padding2;
        ETHERTYPE_1B_PADS  : parse_padding1;
        default: ingress;
    }
}

parser parse_padding8 {
    extract(padding8[next]);
    return select(padding8[last].next_etherType) {
        ETHERTYPE_IPV4     : parse_ipv4;
        // ETHERTYPE_32B_PADS : parse_padding32;
        // ETHERTYPE_16B_PADS : parse_padding16;
        ETHERTYPE_8B_PADS  : parse_padding8;
        ETHERTYPE_4B_PADS  : parse_padding4;
        ETHERTYPE_2B_PADS  : parse_padding2;
        ETHERTYPE_1B_PADS  : parse_padding1;
        default: ingress;
    }
}

parser parse_padding4 {
    extract(padding4[next]);
    return select(padding4[last].next_etherType) {
        ETHERTYPE_IPV4     : parse_ipv4;
        // ETHERTYPE_32B_PADS : parse_padding32;
        // ETHERTYPE_16B_PADS : parse_padding16;
        // ETHERTYPE_8B_PADS  : parse_padding8;
        ETHERTYPE_4B_PADS  : parse_padding4;
        ETHERTYPE_2B_PADS  : parse_padding2;
        ETHERTYPE_1B_PADS  : parse_padding1;
        default: ingress;
    }
}

parser parse_padding2 {
    extract(padding2[next]);
    return select(padding2[last].next_etherType) {
        ETHERTYPE_IPV4     : parse_ipv4;
        // ETHERTYPE_32B_PADS : parse_padding32;
        // ETHERTYPE_16B_PADS : parse_padding16;
        // ETHERTYPE_8B_PADS  : parse_padding8;
        // ETHERTYPE_4B_PADS  : parse_padding4;
        ETHERTYPE_2B_PADS  : parse_padding2;
        ETHERTYPE_1B_PADS  : parse_padding1;
        default: ingress;
    }
}

parser parse_padding1 {
    extract(padding1[next]);
    return select(padding1[last].next_etherType) {
        ETHERTYPE_IPV4_8BIT   : parse_ipv4;
        // ETHERTYPE_32B_PADS : parse_padding32;
        // ETHERTYPE_16B_PADS : parse_padding16;
        // ETHERTYPE_8B_PADS  : parse_padding8;
        // ETHERTYPE_4B_PADS  : parse_padding4;
        // ETHERTYPE_2B_PADS  : parse_padding2;
        ETHERTYPE_1B_PADS  : parse_padding1;
        default: ingress;
    }
}

parser parse_ipv4 {
    extract(ipv4);
    return select(ipv4.protocol) {
        // NUM_TCP: parse_tcp;
        // NUM_ICMP: parse_icmp;
        // NUM_UDP: parse_udp;
        default: ingress;
    }
}

// parser parse_tcp {
//     extract(tcp);
//     return ingress;
// }

// parser parse_udp {
//     extract(udp);
//     return ingress;
// }