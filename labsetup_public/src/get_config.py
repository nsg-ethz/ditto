import logging
import argparse
import sys
import logging
from os import listdir
from os.path import isfile, join
import yaml

from get_logger import setup_logging
log = logging.getLogger(__name__)
setup_logging()


def get_all_config_files(folder):
  """returns a list of all config files

  Args:
      folder (string): path to the config folder
  """
  
  return list(map(lambda f: join(folder,f), filter(lambda f: f.endswith(".yaml"), [f for f in listdir(folder) if isfile(join(folder, f))])))


def read_config_files(config_files):
  """reads all config files and returns dictionaries of devices and cables

  Args:
      config_files (list): list of config file paths

  Returns:
      config: dict{devices,cables}
  """
  
  config = {
    "devices": {},
    "cables": []
  }
  
  for config_file in config_files:
    log.debug("reading config file {}".format(config_file))
    
  
    with open(config_file) as file:
      # The FullLoader parameter handles the conversion from YAML
      # scalar values to Python the dictionary format
      config_entries = yaml.load(file, Loader=yaml.FullLoader)
      
      for (t,v) in config_entries.items():
        
        if t == "devices":
          config[t].update(v)
        if t == "cables":
          config[t] += (v)
          
  return config
          

def augment_lab_config(lab_config):
  """augment the configuration by
  - adding a "connected_to" attribute to each port which has a cable plugged in

  Args:
      lab_config (dict): [description]

  Returns:
      dict: lab_config
  """
  
  for cable in lab_config["cables"]:    
    lab_config["devices"][cable["source"]["device"]]["ports"][cable["source"]["port"]]["connected_to"] = cable["destination"]
    lab_config["devices"][cable["source"]["device"]]["ports"][cable["source"]["port"]]["cable"] = cable
    
    
    lab_config["devices"][cable["destination"]["device"]]["ports"][cable["destination"]["port"]]["connected_to"] = cable["source"]
    lab_config["devices"][cable["destination"]["device"]]["ports"][cable["destination"]["port"]]["cable"] = cable
  
  return lab_config

def device_ordering(lab_config, device_types = ["server","tofino"], reverse=False):
  if not isinstance(device_types,list):
    device_types = [device_types]
    
  ordering = []
    
  for t in device_types:
    dev_filtered = [k for (k,v) in lab_config["devices"].items() if v["type"]==t]    

    ordering += sorted(dev_filtered, reverse=reverse)
  
  return ordering

def get_config(folder):
    log.info("searching config files in {}".format(folder))
    all_config_files = get_all_config_files(folder)
    log.debug("all config files: {}".format(all_config_files))
    
    lab_config = read_config_files(all_config_files)
    log.info("lab configuration: {} devices and {} cables".format(len(lab_config["devices"]), len(lab_config["cables"])))
    
    lab_config = augment_lab_config(lab_config)
    
    return lab_config