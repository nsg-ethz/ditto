import os, sys, time
import argparse
import math
import json
import bisect
import logging

sys.path.append("/".join(os.path.abspath(os.getcwd()).split("/")[:-2])) # append root directory to path

from labsetup_public.src.get_config import get_config

def setup_logging(loglevel="DEBUG"):
    """Setup basic logging

    Args:
      loglevel (int): minimum loglevel for emitting messages
    """
    logformat = "[%(asctime)s] %(levelname)s:%(name)s:%(message)s"
    logging.basicConfig(level=loglevel, stream=sys.stdout,
                        format=logformat, datefmt="%Y-%m-%d %H:%M:%S")

log = logging.getLogger(__name__)

class PatternCodeGenerator(object):
    
    # traffic types
    T_TYPE_PROD = 1
    T_TYPE_FAKE = 2

    def __init__(self,target,device_configuration, device):

        if target in "device model".split():
            self.target=target
        else:
            print "unsupported target"
            exit(1)
        
        self.port_configuration = device_configuration

        self.lab_config = get_config("../../labsetup_public/config/")

        self.code_parts = "CLI TOP HEADERS METADATA PARSER REGISTERS ACTIONS INGRESS EGRESS".split()
        self.code = {part: [] for part in self.code_parts}

        self.config = {
            "pads"                  : [32,16,8,4,2,1],
            "pattern_sequence"      : device_configuration["pattern"],
            "obfuscation_device"    : device,
        }

        self.constants = {
            # Number of pads of different sizes. Need to fit in PHV.
            # (reduce numbers for faster compile time)
            "NUM_32B_PADS"              : 4,
            "NUM_16B_PADS"              : 6,
            "NUM_8B_PADS"               : 2,
            "NUM_4B_PADS"               : 2,
            "NUM_2B_PADS"               : 2,
            "NUM_1B_PADS"               : 2,
    
            # ethertypes to identify padding headers
            "ETHERTYPE_IPV4"            : 0x0800,
            "ETHERTYPE_PADDING_META"    : 0x0888,
            "ETHERTYPE_EVALUATION_META" : 0x0887,
            "ETHERTYPE_QUEUEINFO"       : 0x0123,
            "ETHERTYPE_32B_PADS"        : 0x0801,
            "ETHERTYPE_16B_PADS"        : 0x0802,
            "ETHERTYPE_8B_PADS"         : 0x0803,
            "ETHERTYPE_4B_PADS"         : 0x0804,
            "ETHERTYPE_2B_PADS"         : 0x0805,
            "ETHERTYPE_1B_PADS"         : 0x09,

            # 8bit padding headers only have 8bits for the ethertype field
            "ETHERTYPE_IPV4_8BIT"       : 0x80,
            "ETHERTYPE_1B_PADS_8BIT"    : 0x09,
            
            # instance types for the packet when it passes through the switch multiple times
            "INSTANCE_FIRSTPASS"        : 0x1,
            "INSTANCE_SECONDPASS"       : 0x2,
            "INSTANCE_DONE"             : 0x3,
    
            # length of the padding_meta header
            "PADDING_META_LEN"          : 18,
    
            # network settings
            "MTU"                       : 1600, # B
            # "MTU"                       : 1500,
            "TARGET_BW"                 : 100, # Gbps
        }

        self.constants["PATTERN_LENGTH"] = len(self.config["pattern_sequence"])
        self.constants["NUM_QUEUES"] = len(self.config["pattern_sequence"])
        self.constants["NUM_QUEUES_MINUS_1"] = len(self.config["pattern_sequence"])-1
        self.constants["MAX_PACKET_SIZE"] = max(self.config["pattern_sequence"])
        self.constants["MAX_PADDING_BYTES"] = sum([p*self.constants["NUM_%iB_PADS"%p] for p in self.config["pads"]])
        self.constants["MAX_PADDING_BYTES_PLUS_1"] = self.constants["MAX_PADDING_BYTES"] + 1
        
        for instance_type in [self.constants["INSTANCE_FIRSTPASS"], self.constants["INSTANCE_SECONDPASS"], self.constants["INSTANCE_DONE"]]:
            for ethertype in "IPV4 QUEUEINFO 32B_PADS 16B_PADS 8B_PADS 4B_PADS 2B_PADS 1B_PADS".split():
                self.constants["ETHERTYPE_%s_INSTANCETYPE_%i" % (ethertype, instance_type)] = (self.constants["ETHERTYPE_%s"%ethertype]<<4)+instance_type

        self.state_index_to_port = {}
        self.generated_files = []
        
        self.__init_priorityqueuing_ports()

    def make_list(self,items):
        if not isinstance(items,list):
            items = [items]
        return items

    def get_ports(self,categories):
        """returns the union of all ports in given categories

        Args:
            categories (string or list of strings): categories to merge
        """
        categories = self.make_list(categories)
        
        ports = []
        for c in categories:
            ports += self.make_list(self.port_configuration[c])
        return ports

    def phys_port_to_str(self,phys_port):
        """
        returns the port string for a given physical port. 
        The physical port can be an int (e.g. 1 -> function returns "1/-") 
        or a string (e.g. 1/0 -> function returns "1/0")
        """
        port_str = str(phys_port)

        if len(port_str.split("/")) == 1:
            return "%s/-"%(port_str)
        elif len(port_str.split("/")) == 2:
            return port_str
        else:
            return None

    def phys_port_to_speed(self,phys_port):
        """
        returns 100G if the port is used as x/- and 10G otherwise
        """
        port_str = str(phys_port)

        if len(port_str.split("/")) == 1:
            return "100G"
        elif len(port_str.split("/")) == 2:
            return "10G"
        else:
            return None

    def get_internal_ports(self,phys_ports):
        """returns the internal port number(s) for given physical port(s)

        Args:
            phys_ports (int or list): integer or list of integers

        Returns:
            int or list: internal port number(s)
        """
        if self.target == "device":
            if isinstance(phys_ports,list):
                # return [self.lab_config["devices"][self.config["obfuscation_device"]]["ports"]["%i/-"%(phys_port)]["internal"] for phys_port in phys_ports]
                return [self.lab_config["devices"][self.config["obfuscation_device"]]["ports"][self.phys_port_to_str(phys_port)]["internal"] for phys_port in phys_ports]
            else:
                # return self.lab_config["devices"][self.config["obfuscation_device"]]["ports"]["%i/-"%(phys_ports)]["internal"]
                return self.lab_config["devices"][self.config["obfuscation_device"]]["ports"][self.phys_port_to_str(phys_ports)]["internal"]
        else:
            return phys_ports

    def __init_priorityqueuing_ports(self):
        """
        initializes the ports that are used for priority queuing
        """
        log.warn("using 100Gb links for all ports")
        # available_bws = [10, 25, 40, 50, 100]
        available_bws = [10, 100]
        
        self.constants["BW_PER_QUEUE"] = available_bws[bisect.bisect_right(available_bws, self.constants["TARGET_BW"] * 1./self.constants["PATTERN_LENGTH"] - 1)]
        
        available_queues_per_port = {
            "device": {
                10: 4,
                25: 4,
                40: 2,
                50: 2,
                100: 1
            },
            "model": {
                10: 1,
                25: 1,
                40: 1,
                50: 1,
                100: 1
            }
        }[self.target]
        
        num_needed_ports = self.constants["PATTERN_LENGTH"] * 1./ available_queues_per_port[self.constants["BW_PER_QUEUE"]]
        
        assert num_needed_ports <= len( self.port_configuration["priorityqueuing_out"]), \
            "not enough queueing ports available: have %i, need %i" \
                % (len( self.port_configuration["priorityqueuing_out"]), num_needed_ports)

        available_pipes_for_num_pipes = {
            4: [0, 1, 2, 3],
            2: [0, 2],
            1: [0],
        }
        
        available_port_ids = []
        
        if self.target == "device":
            for phys_port in  self.port_configuration["priorityqueuing_out"]:
                available_port_ids += [
                    self.lab_config["devices"][self.config["obfuscation_device"]]["ports"]["%i/%i"%(phys_port,i)]["internal"] \
                        for i in available_pipes_for_num_pipes[available_queues_per_port[self.constants["BW_PER_QUEUE"]]]
                ]
        elif self.target == "model":
            available_port_ids = list( self.port_configuration["priorityqueuing_out"])
                
        self.state_index_to_port = {i: available_port_ids[i] for i in range(self.constants["PATTERN_LENGTH"])}
        
        log.info("state to port index: %s" % str(self.state_index_to_port)) 
        
        # self.constants["RECIRCULATION_PORT"] = self.get_internal_ports(self.port_configuration["recirculation"])

    def add_to_part(self,part,code):
        """
        adds code to the specified part of the program
        """
        self.code[part].append(code+"\n")
    
    def dump_code(self):
        """
        print the entire generated code
        """
        for p in self.code_parts:
            print p
            print "\n".join(self.code[p])
    
    def write_code_to_file(self,filepath):
        """
        writes the generated code to a file
        """
        f = open(filepath, "w")
        f.write("// AUTOMATICALLY GENERATED FILE -- DO NOT EDIT MANUALLY\n")
        f.write("// generated: %s\n\n\n" % time.strftime("%Y-%m-%d %H:%M:%S"))

        for p in self.code_parts:
            f.write("\n\n#ifdef IN_SECTION_%s" % (p))
            f.write("\n// ************************** %s *********************\n\n" % (p))
            f.write("\n".join(self.code[p]))
            f.write("\n#endif")
        f.close()
        self.generated_files.append(filepath)
    
    def write_cli_to_file(self,filepath):
        """
        writes only the CLI input to a file
        """
        f = open(filepath, "w")
        p = "CLI"
        f.write("\n".join(self.code[p]))
        f.close()
        self.generated_files.append(filepath)
    
    def write_device_specific_info_to_file(self,filepath):
        info_dict = {
            "config": self.config,
            "constants": self.constants,
            "state_index_to_port": self.state_index_to_port,
            "ports_cloning": self.get_internal_ports(self.get_ports("fake_traffic".split())),
            "ports_priorityqueues": self.state_index_to_port.values(),
            "ports_rrqueues": self.get_internal_ports(self.get_ports("output".split())),
            
            # "port_configuration": self.port_configuration,
            # "lab_config": self.lab_config,
        }
        
        with open(filepath, 'w') as outfile:
            json.dump(info_dict, outfile)
            self.generated_files.append(filepath)
    
    def write_general_info_to_file(self,filepath):
        info_dict = {
            "config": self.config,
            "constants": self.constants,
        }
        
        with open(filepath, 'w') as outfile:
            json.dump(info_dict, outfile)
            self.generated_files.append(filepath)

    def generate_code_constants(self):
        part = "TOP"
        code = "// constants"

        for (k,v) in self.constants.items():
            code += "\n#define %s %s" % (k,str(v))

        self.add_to_part(part,code)

    def generate_code_parsers(self):
        part = "PARSER"

        code = "// header declarations"
        code += "\nheader ethernet_t  ethernet; \n\
header ipv4_t      ipv4;\n\
//header tcp_t       tcp;\n\
//header udp_t       udp;\n\
// header queue_info_t queue_info;\n\
header padding_meta_t padding_meta;\n\
header evaluation_meta_t evaluation_meta;"

        for p in self.config["pads"]:
            num_pads = self.constants["NUM_%iB_PADS"%p]
            for i in range(num_pads):
                code += "\nheader padding%i_t padding%i_%i;" % (p,p,i)
        self.add_to_part(part,code)

        code = "\n\n// parsers\n"
        code += "parser start { \n\
    extract(ethernet);\n\
    return select(ethernet.etherType) {\n\
         ETHERTYPE_IPV4     : parse_ipv4;\n\
         ETHERTYPE_PADDING_META: parse_padding_meta;\n\
         ETHERTYPE_QUEUEINFO: parse_queue_info;\n\
         ETHERTYPE_EVALUATION_META: parse_evaluation_meta;"

        for p in self.config["pads"]:
            if self.constants["NUM_%iB_PADS"%p] > 0:
                code += "\n         ETHERTYPE_%iB_PADS : parse_padding%i_0;" % (p,p,)
        
        code += "\n         default: ingress;\n \
    }\n\
}"
        self.add_to_part(part,code)

        code = "parser parse_evaluation_meta { \n\
    extract(evaluation_meta);\n\
    return select(evaluation_meta.next_etherType) {\n\
         ETHERTYPE_IPV4     : parse_ipv4;\n\
         ETHERTYPE_QUEUEINFO: parse_queue_info;\n\
         ETHERTYPE_PADDING_META: parse_padding_meta;"

        for p in self.config["pads"]:
            if self.constants["NUM_%iB_PADS"%p] > 0:
                code += "\n         ETHERTYPE_%iB_PADS : parse_padding%i_0;" % (p,p,)
        
        code += "\n         default: ingress;\n \
    }\n\
}"
        self.add_to_part(part,code)

        code = "parser parse_padding_meta { \n\
    extract(padding_meta);\n\
    return select(padding_meta.next_etherType, padding_meta.instance_type) {"

        # for instance_type in [self.constants["INSTANCE_DONE"]]:
        for instance_type in [3]:

            code += "\n         ETHERTYPE_QUEUEINFO_INSTANCETYPE_%i: parse_queue_info;" % instance_type

            for p in self.config["pads"]:
                if self.constants["NUM_%iB_PADS"%p] > 0:
                    code += "\n         ETHERTYPE_%iB_PADS_INSTANCETYPE_%i : parse_padding%i_0;" % (p,instance_type,p,)
            
        code += "\n         default: ingress;\n \
        }\n\
    }"
        self.add_to_part(part,code)

        code = "parser parse_queue_info {\n\
    return ingress;\n\
}"
        self.add_to_part(part,code)

        for p in self.config["pads"]:
            num_pads = self.constants["NUM_%iB_PADS"%p]
            smallEtherType = "_8BIT" if p==1 else ""
            
            for i in range(num_pads):
                code = "\n"
                code += "parser parse_padding%i_%i { \n\
    extract(padding%i_%i); \n\
    return select(padding%i_%i.next_etherType) { \n\
        ETHERTYPE_IPV4%s     : parse_ipv4;" % (p,i,p,i,p,i,smallEtherType,)

                if num_pads > i+1:
                    code += "\n        ETHERTYPE_%iB_PADS%s : parse_padding%i_%i;" % (p,smallEtherType,p,i+1,)
                

                for pp in filter(lambda pp: pp<p, self.config["pads"]):
                    if self.constants["NUM_%iB_PADS"%pp] > 0:
                        code += "\n         ETHERTYPE_%iB_PADS%s : parse_padding%i_0;" % (pp,smallEtherType,pp,)

                code += "\n         default: ingress;\n \
    }\n\
}"
                self.add_to_part(part,code)
            
        code = "\n\n parser parse_ipv4 {\n\
    extract(ipv4);\n\
    return select(ipv4.protocol) {\n\
        // NUM_TCP: parse_tcp;\n\
        // NUM_ICMP: parse_icmp;\n\
        // NUM_UDP: parse_udp;\n\
        default: ingress;\n\
    }\n\
}"
        self.add_to_part(part,code)
    
    def generate_code_padding_actions_and_tables(self):
        part = "ACTIONS"
        code = ""

        for p in self.config["pads"]:
            num_pads = self.constants["NUM_%iB_PADS"%p]

            for i in range(num_pads):
                code += "\n// pad with %i blocks of %iB" % (i+1,p)
                code += "\naction add_padding%i_%i(next_etherType) {" % (p,i+1)
                for j in range(i+1):
                    code += "\n    add_header(padding%i_%i);" % (p,j)
                    if j < i:
                        code += "\n    modify_field(padding%i_%i.next_etherType,ETHERTYPE_%iB_PADS);" % (p,j,p)
                    if p>=4:
                        code += "\n    modify_field(padding%i_%i.padding,%s);" % (p,j, hex(2**(p-2)-1))
                code += "\n    modify_field(padding%i_%i.next_etherType,next_etherType);" % (p,j)
                    
                
                code += "\n    subtract_from_field(custom_metadata.bytes_to_add,%i);" % ((i+1)*p)
                code += "\n    add_to_field(padding_meta.totalLen,%i);" % ((i+1)*p)
                code += "\n}\n"
        self.add_to_part(part,code)

        for p in self.config["pads"]:
            code = ""
            num_pads = self.constants["NUM_%iB_PADS"%p]
            table_size = int(2**math.ceil(math.log(num_pads,2))) * len(self.config["pads"])

            code += "\n// padding with %iB blocks" % (p)
            code += "\ntable add_padding_%i {" % (p)
            code += "\n    reads {\n\
        custom_metadata.bytes_to_add: range;\n\
    } \n\
    actions {\n\
        _NoAction;"


            for i in range(num_pads):
                code += "\n        add_padding%i_%i;" % (p,i+1)

            code += "\n    }\n\
    default_action: _NoAction;\n\
    size: %i;\n\
}" % (table_size,)
            self.add_to_part(part,code)
        
    def generate_code_remove_padding_actions_and_tables(self):
        part = "ACTIONS"
        code = ""

        code += "\naction remove_padding_headers() {"
        # code += "\n    remove_header(padding_meta);"
        # code += "\n    remove_header(evaluation_meta);"

        for p in self.config["pads"]:
            num_pads = self.constants["NUM_%iB_PADS"%p]

            for i in range(num_pads):
                code += "\n    remove_header(padding%i_%i);" % (p,i)

        code += "\n}\n"
        self.add_to_part(part,code)

        code = "TABLE_WITH_SINGLE_DO_ACTION(remove_padding_headers)"
        self.add_to_part(part,code)
    
    def generate_code_apply_padding_tables(self):
        part = "EGRESS"
        code = ""

        for p in self.config["pads"]:
            code = "apply(add_padding_%i);" % (p,)
            self.add_to_part(part,code)
    
    def generate_cli_forwarding(self):
        part = "CLI"
        code = ""
        
        output_port = self.get_internal_ports(self.port_configuration["output"])
        
        for port in self.get_internal_ports(self.get_ports("priorityqueuing_in".split())):
            code += "pd fwd_port add_entry forward_and_obfuscate ig_intr_md_ingress_port %s action_egress_port %s \n" % (hex(port),hex(output_port))
        
        output_port = self.get_internal_ports(self.port_configuration["obf_output"])
        for port in self.get_internal_ports(self.get_ports("obf_input".split())):
            code += "pd fwd_port add_entry forward_and_deobfuscate ig_intr_md_ingress_port %s action_egress_port %s \n" % (hex(port),hex(output_port))
        
        code += "\n"
        self.add_to_part(part,code)
    
    def generate_cli_cloning(self):
        part = "CLI"
        code = ""
        
        output_port = self.port_configuration["output"]
        
        for port in self.get_internal_ports(self.get_ports("fake_traffic".split())):
            code += "pd clone_port add_entry clone_to_port ig_intr_md_ingress_port %s action_session_id %s \n" % (hex(port),hex(port))
                
        code += "\n"
        self.add_to_part(part,code)
        
    def generate_ucli_ports(self):
        part = "CLI"
        code = ""
        
        if self.target == "device":
            # code += "ucli \n\n"
            
            # normal ports
            for phys_port in self.get_ports("input output fake_traffic recirculation obf_input obf_output".split()):


                code += "pm port-add %s %s NONE \n" % (self.phys_port_to_str(phys_port),self.phys_port_to_speed(phys_port))
                code += "pm port-enb %s \n" % (self.phys_port_to_str(phys_port))
            
            # ports for priority queueing
            for phys_port in  self.get_ports("priorityqueuing_out".split()):
                code += "pm port-add %i/- %iG NONE \n" % (phys_port,self.constants["BW_PER_QUEUE"])
                code += "pm port-enb %i/- \n" % (phys_port)
            
            code += "pm show\n"
            # code += "end\n"
        
        self.add_to_part(part,code)
        
    def generate_ucli_rate_monitor(self):
        part = "CLI"
        code = ""
        
        if self.target == "device":
            # code += "ucli \n"
            code += "pm rate-period 1\n"
            code += "pm rate-show\n"
            # code += "end\n"
        
        self.add_to_part(part,code)
        
    
    def generate_cli_assign_queue(self):
        part = "CLI"
        code = ""
        priority = 0
        
        state_to_iterators = {k:{"size":self.config["pattern_sequence"][k], "iterators":[]} for k in range(len(self.config["pattern_sequence"]))}
        for p in set(self.config["pattern_sequence"]):
            indices = [k for (k,v) in filter(lambda (k,v): v["size"]==p, state_to_iterators.items())]
            for i in range(len(self.config["pattern_sequence"])):
                state_to_iterators[indices[i%len(indices)]]["iterators"].append(i)
        
        # priority queues
        traffictypes = [1]
        qid = 1
        for (k,v) in state_to_iterators.items():
            lower_bound = max(max(filter(lambda x: x<v["size"], self.config["pattern_sequence"]+[0]))- self.constants["PADDING_META_LEN"],0)
            upper_bound = max(v["size"] - self.constants["PADDING_META_LEN"],0)
            for traffictype in traffictypes:
                # for iterator in v["iterators"]:
                for iterator in [0]:
                    
                    code += "pd assign_to_queue add_entry set_state_properties_priority padding_meta_traffic_type %s "\
                            "padding_meta_instance_type %s padding_meta_totalLen_start %s padding_meta_totalLen_end %s "\
                            "custom_metadata_packet_iterator %s priority %s "\
                            "action_egress_port %s action_state_index %s action_qid %s action_target_size %s \n" % \
                            (hex(traffictype), hex(self.constants["INSTANCE_FIRSTPASS"]), hex(lower_bound), hex(upper_bound), \
                            hex(iterator), hex(priority), hex(self.state_index_to_port[k]), hex(k), hex(qid), hex(v["size"]))
                            
                    priority += 1
        
        traffictype = 2
        qid = 0
        for (k,v) in state_to_iterators.items():
            for iterator in [0]:
                size = v["size"]
                lower_bound = max(max(filter(lambda x: x<v["size"], self.config["pattern_sequence"]+[0]))- self.constants["PADDING_META_LEN"],0)
                upper_bound = max(v["size"] - self.constants["PADDING_META_LEN"],0)
                        
                code += "pd assign_to_queue add_entry set_state_properties_priority padding_meta_traffic_type %s "\
                        "padding_meta_instance_type %s padding_meta_totalLen_start %s padding_meta_totalLen_end %s "\
                        "custom_metadata_packet_iterator %s priority %s "\
                        "action_egress_port %s action_state_index %s action_qid %s action_target_size %s \n" % \
                        (hex(traffictype), hex(self.constants["INSTANCE_FIRSTPASS"]), hex(lower_bound), hex(upper_bound), \
                        hex(iterator), hex(priority), hex(self.state_index_to_port[k]), hex(k), hex(qid), hex(size))
                priority += 1
        
        # round robin queues
        traffictypes = [1, 2]
        for traffictype in traffictypes:
            output_port = self.get_internal_ports(self.port_configuration["output"])
            
            for iterator in [0]:
                for state_index in range(len(self.config["pattern_sequence"])):
                    size = self.config["pattern_sequence"][state_index]
                    lower_bound = max(size-self.constants["MAX_PADDING_BYTES"],0)
                    
                    code += "pd assign_to_queue add_entry set_state_properties_roundrobin padding_meta_traffic_type %s " \
                            "padding_meta_instance_type %s padding_meta_totalLen_start %s padding_meta_totalLen_end %s "\
                            "custom_metadata_packet_iterator %s priority %s action_egress_port %s action_qid %s \n" % \
                            (hex(traffictype), hex(self.constants["INSTANCE_SECONDPASS"]), hex(lower_bound), hex(size), \
                            hex(iterator), hex(priority), hex(output_port), hex(state_index))
                    priority += 1
        
        self.add_to_part(part,code)
    
    def generate_cli_type(self):
        part = "CLI"
        code = ""
        
        for port in self.get_internal_ports(self.get_ports("input".split())):
            code += "pd traffic_type add_entry set_traffic_type ig_intr_md_ingress_port %s action_traffic_type %s action_instance_type %s action_needs_obfuscation %s \n" % (hex(port),hex(self.T_TYPE_PROD), hex(self.constants["INSTANCE_FIRSTPASS"]), hex(1))     
        
        for port in self.get_internal_ports(self.get_ports("priorityqueuing_in".split())):
            code += "pd traffic_type add_entry set_instance_type ig_intr_md_ingress_port %s action_instance_type %s action_needs_obfuscation %s \n" % (hex(port), hex(self.constants["INSTANCE_SECONDPASS"]), hex(1))     
            
        for port in self.get_internal_ports(self.get_ports("fake_traffic".split())):
            code += "pd traffic_type add_entry set_traffic_type ig_intr_md_ingress_port %s action_traffic_type %s action_instance_type %s action_needs_obfuscation %s \n" % (hex(port),hex(self.T_TYPE_FAKE), hex(self.constants["INSTANCE_FIRSTPASS"]), hex(1))     
            
        self.add_to_part(part,code)
    
    def generate_cli_padding_meta_next_etherType(self):
        part = "CLI"
        code = ""

        priority = 0

        for p in self.config["pads"]:
            bytes_start = p

            code += "\npd set_padding_meta_next_etherType add_entry padding_meta_set_next_etherType custom_metadata_bytes_to_add_start %s custom_metadata_bytes_to_add_end %s priority %s action_next_etherType %s" \
                    % (hex(bytes_start), hex(self.constants["MTU"]), hex(priority), hex(self.constants["ETHERTYPE_%iB_PADS"%p]))
            priority += 1
        
        self.add_to_part(part,code)
    
    def generate_cli_padding_tables(self):
        part = "CLI"
        code = ""

        for p in self.config["pads"]:
            num_pads = self.constants["NUM_%iB_PADS"%p]
            priority = num_pads*len(self.config["pads"])

            for i in range(num_pads):

                bytes_start = (i+1)*p

                code += "\npd add_padding_%i add_entry add_padding%i_%i custom_metadata_bytes_to_add_start %s custom_metadata_bytes_to_add_end %s priority %s action_next_etherType 0x0" \
                        % (p, p, i+1, hex(bytes_start), hex(self.constants["MTU"]), hex(priority))
                priority -= 1

                for pp in sorted(self.config["pads"], reverse=False): # possible next pad
                    if pp>=p:
                        continue
                    bytes_end = self.constants["MTU"]
                    code += "\npd add_padding_%i add_entry add_padding%i_%i custom_metadata_bytes_to_add_start %s custom_metadata_bytes_to_add_end %s priority %s action_next_etherType %s" \
                            % (p, p, i+1, hex(bytes_start+pp), hex(bytes_end), hex(priority), hex(self.constants["ETHERTYPE_%iB_PADS"%pp]))
                    priority -= 1

            code += "\n"
        
        self.add_to_part(part,code)
    
    def generate_cli_recirculation(self):
        part = "CLI"
        code = "\npd recirculation_decision add_entry _NoAction custom_metadata_bytes_to_add_start 0x0 custom_metadata_bytes_to_add_end %s priority 0x1" % (hex(self.constants["MAX_PADDING_BYTES"]))
        code += "\n"
        
        self.add_to_part(part,code)
    
    def generate_cli_toobig(self):
        part = "CLI"
        code = "\npd ignore_toobigpackets add_entry _NoAction padding_meta_origLen_start 0 padding_meta_origLen_end %s priority 0x1" % (hex(self.constants["MAX_PACKET_SIZE"]-14-1))
        code += "\n"
        
        self.add_to_part(part,code)
    
    def generate_cli_packet_iterator(self):
        part = "CLI"
        code = ""
        
        for port in self.get_internal_ports(self.get_ports("input fake_traffic priorityqueuing_in".split())):
            code += "\npd packet_iterator add_entry update_packet_iterator ig_intr_md_ingress_port %s" % (hex(port))
        code += "\n"
        
        self.add_to_part(part,code)
    
    def generate_cli_deobf_blocklist(self):
        part = "CLI"
        code = ""
        
        traffictypes = [2]
        for traffictype in traffictypes:
            code += "\npd deobfuscation_blocklist add_entry droppacket padding_meta_traffic_type %s" % (hex(traffictype))
        code += "\n"
        
        self.add_to_part(part,code)
    
    def generate_cli_deobf_determine_ethertype(self):
        part = "CLI"
        code = ""

        bytes_start = 1

        for pad in sorted(self.config["pads"]):
            next_pad = min(filter(lambda x: x>pad, self.config["pads"]+[self.constants["MTU"]]))
            ethertype = self.constants["ETHERTYPE_%iB_PADS" % pad]
            code += "\npd deobfuscation_determine_next_ethertype add_entry set_padding_meta_next_etherType custom_metadata_bytes_to_add_start %i custom_metadata_bytes_to_add_end %i priority %i action_etherType %s" % (bytes_start, next_pad-1, pad, hex(ethertype))
            bytes_start = next_pad
        code += "\n"
        
        self.add_to_part(part,code)
    
    def generate_cli_addlines(self,code):
        part = "CLI"
        self.add_to_part(part,code)
    
    
    def git_add_generated_files(self):
        for file in self.generated_files:
            os.system("git add %s" % file)

    def git_commit(self):
        os.system("git commit -m \"generated files\"")
    
    def generate_everything(self):
        self.generate_code_constants()

        self.generate_code_parsers()
        self.generate_code_padding_actions_and_tables()
        self.generate_code_remove_padding_actions_and_tables()
        self.generate_code_apply_padding_tables()

        # ucli input
        self.generate_cli_addlines("ucli")
        self.generate_ucli_ports()
        self.generate_ucli_rate_monitor()
        self.generate_cli_addlines("end")
        
        # bfshell input
        self.generate_cli_addlines("pd-traffic-pattern-tofino")

        self.generate_cli_forwarding()
        self.generate_cli_cloning()
        self.generate_cli_assign_queue()
        self.generate_cli_type()
        self.generate_cli_packet_iterator()
        self.generate_cli_padding_meta_next_etherType()
        self.generate_cli_padding_tables()
        self.generate_cli_recirculation()
        self.generate_cli_toobig()
        self.generate_cli_deobf_determine_ethertype()
        self.generate_cli_deobf_blocklist()
                
        self.generate_cli_addlines("end")


def parse_args(args):
    """Parse command line parameters

    Args:
      args ([str]): command line parameters as list of strings

    Returns:
      :obj:`argparse.Namespace`: command line parameters namespace
    """
    parser = argparse.ArgumentParser(
        description="volume obfuscation code generator")
    
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


    labsetup_logger = logging.getLogger('labsetup_public.src.get_config')
    labsetup_logger.setLevel(level=logging.ERROR)

    pattern = [533, 1066, 1600] # unif, l3

    code_directory = "../../p4/traffic_pattern_tofino/"

    device_configuration = {
        "tofino1": { 
            #use physical port numbers
            "target"              : "device",
            "connected_server"    : "src",
            "pattern"             : pattern,
            "input"               : [1, 32],
            "output"              : 2,
            "obf_input"           : [2, 31], # obfuscated traffic input -> will be deobfuscated
            "obf_output"          : 1, # output port for deobfuscated traffic
            "priorityqueuing_out" : [27, 28, 29, 30],
            "priorityqueuing_in"  : [27, 28, 29, 30],
            "fake_traffic"        : [3, 4, 5],
            "recirculation"       : 31, 
        },
        "tofino2": { 
            #use physical port numbers
            "target"              : "device",
            "connected_server"    : "dst",
            "pattern"             : pattern,
            "input"               : [1, 32],
            "output"              : 2,
            "obf_input"           : [2, 31], # obfuscated traffic input -> will be deobfuscated
            "obf_output"          : 1, # output port for deobfuscated traffic
            "priorityqueuing_out" : [27, 28, 29, 30],
            "priorityqueuing_in"  : [27, 28, 29, 30],
            "fake_traffic"        : [3, 4, 5],
            "recirculation"       : 31, 
        },
    }

    for device in "tofino1 tofino2".split():
        log.info("generating code for %s" % device)
        configuration = device_configuration[device]

        pcg = PatternCodeGenerator(configuration["target"],configuration, device)
        pcg.generate_everything()

        pcg.write_code_to_file(os.path.join(code_directory,"p4src/include/generated/add_padding.p4"))
        pcg.write_device_specific_info_to_file(os.path.join(code_directory,"pd_rpc_info_%s.json" % device))

        # pcg.write_device_specific_info_to_file(os.path.join(code_directory,"server_info_%s.json" % configuration["connected_server"]))
        pcg.write_cli_to_file(os.path.join(code_directory,"bfshell_input_%s.txt" % device))

        log.info(pcg.generated_files)
        log.info("MAX_PADDING_BYTES: %i" % pcg.constants["MAX_PADDING_BYTES"])
        
        # pcg.git_add_generated_files()

    # pcg.git_commit()



def run():
    """Entry point for console_scripts
    """
    main(sys.argv[1:])


if __name__ == "__main__":
    run()
