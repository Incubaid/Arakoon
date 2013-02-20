"""
This file is part of Arakoon, a distributed key-value store. Copyright
(C) 2010 Incubaid BVBA

Licensees holding a valid Incubaid license may use this file in
accordance with Incubaid's Arakoon commercial license agreement. For
more information on how to enter into this agreement, please contact
Incubaid (contact details can be found on www.arakoon.org/licensing).

Alternatively, this file may be redistributed and/or modified under
the terms of the GNU Affero General Public License version 3, as
published by the Free Software Foundation. Under this license, this
file is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.

See the GNU Affero General Public License for more details.
You should have received a copy of the
GNU Affero General Public License along with this program (file "COPYING").
If not, see <http://www.gnu.org/licenses/>.
"""

import sys
import logging


from nose.tools import *
from functools import wraps
import traceback

import struct
import subprocess
import signal

import os
import random
import threading
import time
import arakoon.ArakoonProtocol  
import arakoon.Nursery
from arakoon.ArakoonExceptions import * 

from arakoon_ext.server import ArakoonManagement
from arakoon_ext.server import NurseryManagement
from arakoon_ext.client import ArakoonClient

from arakoon_1 import Arakoon as Ara1
from arakoon_1.ArakoonProtocol import ArakoonClientConfig as Ara1Cfg


test_failed = False 

from Compat import X

class Config:
    def __init__(self):
        self.lease_duration = 2.0
        self.tlog_entries_per_tlog = 1000
        self.node_names = [ "sturdy_0", "sturdy_1", "sturdy_2" ]
        self.cluster_id = 'sturdy'
        self.key_format_str = "key_%012d"
        self.value_format_str = "value_%012d"
        self.data_base_dir = None
        self.binary_full_path = ArakoonManagement.which_arakoon()
        self.nursery_nodes = {
            'nurse_0' : [ 'nurse_0_0', 'nurse_0_1', 'nurse_0_2'],
            'nurse_1' : [ 'nurse_1_0', 'nurse_1_1', 'nurse_1_2'],
            'nurse_2' : [ 'nurse_2_0', 'nurse_2_1', 'nurse_2_2']
            }
        self.nursery_cluster_ids = self.nursery_nodes.keys()
        self.node_client_base_port = 7080
        self.node_msg_base_port = 10000
        self.nursery_keeper_id = self.nursery_cluster_ids[0]
        self.node_ips = [ "127.0.0.1", "127.0.0.1", "127.0.0.1"]

CONFIG = Config()


def _getCluster( c_id = None):

    if c_id is None:
        c_id = CONFIG.cluster_id 
    mgmt = ArakoonManagement.ArakoonManagement()
    cluster = mgmt.getCluster(c_id)
    return cluster

class with_custom_setup ():
    
    def __init__ (self, setup, teardown):
        self.__setup = setup
        self.__teardown = teardown
    
    def __call__ (self, func ):
        @wraps(func)
        def decorate(*args,**kwargs):
            CONFIG.data_base_dir = '%s/%s/%s' % (X.tmpDir, 'arakoon_system_tests' , func.func_name )
            global test_failed
            test_failed = False
            fatal_ex = None
            if X.fileExists( CONFIG.data_base_dir):
                X.removeDirTree( CONFIG.data_base_dir )
            self.__setup( CONFIG.data_base_dir )
            try:
                func(*args,**kwargs)
            except Exception, outer :
                tb = traceback.format_exc()
                X.logging.fatal( tb )              
                fatal_ex = outer
            finally:
                self.__teardown( fatal_ex is None )
            
            if fatal_ex is not None:
                raise fatal_ex
        return decorate


def generate_lambda( f, *args, **kwargs ):
    return lambda: f( *args, **kwargs )

def dump_tlog (node_id, tlog_number) :
    cluster = _getCluster()
    node_home_dir = cluster.getNodeConfig(node_id ) ['home']
    tlog_full_path =  '/'.join ([node_home_dir, "%03d.tlog" % tlog_number])
    cmd = [CONFIG.binary_full_path, "--dump-tlog", tlog_full_path]
    X.logging.debug( "Dumping file %s" % tlog_full_path )
    X.logging.debug("Command is : '%s'" % cmd )
    output = X.subprocess.check_output(cmd)
    return output

def get_arakoon_binary() :
    return '/'.join([get_arakoon_bin_dir(), 'arakoon'])

def get_arakoon_bin_dir():
    return '/'.join([X.appDir, "arakoon", "bin" ])

def get_tcbmgr_path ():
    return '/'.join([get_arakoon_bin_dir(), "tcbmgr" ])

def get_diff_path():
    return "/usr/bin/diff"

def get_node_db_file( node_id ) :
    cluster = _getCluster()
    node_home_dir = cluster.getNodeConfig(node_id ) ['home']
    db_file = '/'.join( [node_home_dir, node_id + ".db" ])
    return db_file
    
def dump_store( node_id ):
    cluster = _getCluster()
    stat = cluster.getStatusOne(node_id )
    msg = "Can only dump the store of a node that is not running (status is %s)" % stat
    assert_equals( stat, X.AppStatusType.HALTED, msg)

    db_file = get_node_db_file ( node_id )
    dump_file = db_file + ".dump" 
    cmd = get_tcbmgr_path() + " list -pv " + db_file
    try:
        dump_fd = open( dump_file, 'w' )
        X.logging.debug( "Dumping store of %s to %s" % (node_id, dump_file) )
        (exit,stdout,stderr) = proc.run( cmd , captureOutput=True, stdout=dump_fd )
        dump_fd.close()
    except:
        X.logging.info("Unexpected error: %s" % sys.exc_info()[0])

    return dump_file

def compare_stores( node1_id, node2_id ):
    le1 = get_last_entries (node1_id)
    le2 = get_last_entries (node2_id)
    for (e1,e2) in zip(le1,le2):
        assert_equals(e1,e2, "Different entries found (e1: %s) (e2: %s)" % (e1, e2))
    return True
        
def get_tlog_count (node_id ):
    cluster = _getCluster()
    node_home_dir = cluster.getNodeConfig(node_id ) ['home']
    ls = X.listFilesInDir
    tlogs =      ls( node_home_dir, filter="*.tlog" )
    tlogs.extend(ls( node_home_dir, filter="*.tlc" ) )
    tlogs.extend(ls( node_home_dir, filter="*.tlf" ) )
    return len(tlogs)
    
def get_last_tlog_id ( node_id ):
    cluster = _getCluster()
    node_home_dir = cluster.getNodeConfig(node_id ) ['home']
    tlog_max_id = 0
    tlog_id = None
    tlogs_for_node = X.listFilesInDir( node_home_dir, filter="*.tlog" )
    for tlog in tlogs_for_node:
        tlog = tlog [ len(node_home_dir):]
        tlog = tlog.strip('/')
        tlog_id = tlog.split(".")[0]
        tlog_id = int( tlog_id )
        if tlog_id > tlog_max_id :
            tlog_max_id = tlog_id
    if tlog_id is not None:
        X.logging.debug("get_last_tlog_id('%s') => %s" % (node_id, tlog_id))
    else :
        raise Exception ("Not a single tlog found in %s" % node_home_dir )
        
    return tlog_max_id

def get_last_i_tlog2(node_id):
    """ should be way faster """
    number = get_last_tlog_id(node_id)
    cluster = _getCluster()
    home = cluster.getNodeConfig(node_id )['home']
    tlog_full_path =  '/'.join([home, "%03d.tlog" % number])
    f = open(tlog_full_path,'rb')
    data = f.read()
    f.close()
    index = 0
    dlen = len(data)
    sn = None
    while index < dlen:
        sn = struct.unpack_from("q", data, index)[0]
        index = index + 8
        index = index + 4 # skip crc32
        elen = struct.unpack_from("I", data,index)[0]
        index = index + 4 + elen 
    return sn
        
def last_entry_code(node_id):
    number = get_last_tlog_id(node_id)
    cluster = _getCluster()
    home = cluster.getNodeConfig(node_id )['home']
    tlog_full_path =  '/'.join([home, "%03d.tlog" % number])
    f = open(tlog_full_path,'rb')
    data = f.read()
    f.close()
    index = 0
    dlen = len(data)
    sn = None
    while index < dlen:
        sn = struct.unpack_from("q", data, index)[0]
        index = index + 8
        index = index + 4 # skip crc32
        elen = struct.unpack_from("I", data,index)[0]
        index = index + 4
        typ = struct.unpack_from("I", data, index)[0]
        index = index + elen
    return typ

def get_last_i_tlog ( node_id ):
    tlog_dump = dump_tlog ( node_id, get_last_tlog_id(node_id) ) 
    tlog_dump_list = tlog_dump.split("\n")
    tlog_first_entry = tlog_dump_list[0]
    tlog_first_i = int(tlog_first_entry.split(":") [0].lstrip(" "))
    if tlog_first_i % CONFIG.tlog_entries_per_tlog != 0 :
        test_failed = True
        raise Exception( "Problem with tlog rollover, first entry (%d) incorrect" % tlog_first_i ) 
    tlog_last_entry = tlog_dump_list [-2]
    tlog_last_i = tlog_last_entry.split(":") [0].lstrip( " 0" )
    return tlog_last_i

def stopOne(name):
    cluster = _getCluster()
    cluster.stopOne(name)

def startOne(name):
    cluster = _getCluster()
    cluster.startOne(name)

def catchupOnly(name):
    cluster = _getCluster()
    cluster.catchupOnly(name)
    
def restart_all():
    cluster = _getCluster()
    cluster.restart()
    
def rotate_logs( max_logs_to_keep = 5, compress_old_files = True):
    for node_name in node_names:
        rotate_log( node_name, max_logs_to_keep, compress_old_files)

def send_signal ( node_name, signal ):
    cluster = _getCluster()
    pid = cluster._getPid(node_name)
    if pid is not None:
        q.system.process.kill( pid, signal )

def rotate_log(node_name, max_logs_to_keep, compress_old_files ):
    cfg = getConfig(node_name)
    log_dir = cfg['log_dir']
    
    log_file = fs.joinPaths(log_dir, "%s.log" % (node_name) )
    if compress_old_files:
        old_log_fmt = fs.joinPaths(log_dir, "%s.log.%%d.gz" % (node_name) )
    else :
        old_log_fmt = fs.joinPaths(log_dir, "%s.log.%%d" % (node_name) )
        
    tmp_log_file = log_file + ".1"
    
    def shift_logs ( ) :
        log_to_remove = old_log_fmt % (max_logs_to_keep - 1) 
        if fs.isFile ( log_to_remove ) :
            fs.unlink(log_to_remove)
            
        for i in range( 1, max_logs_to_keep - 1) :
            j = max_logs_to_keep - 1 - i
            log_to_move = old_log_fmt % j
            new_log_name = old_log_fmt % (j + 1)
            if fs.isFile( log_to_move ) :
                fs.renameFile ( log_to_move, new_log_name )
    cluster = _getCluster()
    shift_logs()
    if fs.isFile( log_file ):
        fs.renameFile ( log_file, tmp_log_file )
        if cluster.getStatusOne(node_name) == q.enumerators.AppStatusType.RUNNING:
            send_signal ( node_name, signal.SIGUSR1 )
        
        if compress_old_files:
            cf = gzip.open( old_log_fmt % 1 , 'w')
            orig = open(tmp_log_file, 'r' )
            cf.writelines(orig)
            cf.close()
            orig.close()
            fs.unlink(tmp_log_file)
    
    
def getConfig(name):
    cluster = _getCluster()
    return cluster.getNodeConfig(name)

def regenerateClientConfig( cluster_id ):
    h = '%s/%s' % (X.cfgDir,'arakoonclients')
    p = X.getConfig(h)

    if cluster_id in p.sections():
        clusterDir = p.get(cluster_id, "path")
        clientCfgFile = '/'.join([clusterDir, "%s_client.cfg" % cluster_id])
        if X.fileExists(clientCfgFile):
            X.removeFile(clientCfgFile)

    client = ArakoonClient.ArakoonClient()
    cliCfg = client.getClientConfig( cluster_id )
    
    cliCfg.generateFromServerConfig()
    

def whipe(name):
    config = getConfig(name)
    data_dir = config['home']
    X.removeDirTree(data_dir)
    X.createDir(data_dir)
    clu = _getCluster()
    clu._initialize(name)
    X.logging.info("whiped %s" % name)

def get_memory_usage(node_name):
    cluster = _getCluster()
    pid = cluster._getPid(node_name )
    if pid is None:
        return 0
    cmd = "ps -p %s -o vsz" % (pid)
    (exit_code, stdout,stderr) = q.system.process.run( cmd, stopOnError=False)
    if (exit_code != 0 ):
        X.logging.error( "Coud not determine memory usage: %s" % stderr )
        return 0
    try:
        size_str = stdout.split("\n") [1]
        return int( size_str )
    except Exception as ex:
        X.logging.error( "Coud not determine memory usage: %s" % ex )
        return 0
    
def collapse(name, n = 1):
    config = getConfig(name)
    ip = config['ip']
    port = config['client_port']
    rc = subprocess.call([CONFIG.binary_full_path, 
                          '--collapse-remote', 
                          CONFIG.cluster_id,
                          ip,port,str(n)])
    return rc

def add_node ( i ):
    ni = CONFIG.node_names[i]
    X.logging.info( "Adding node %s to config", ni )
    (db_dir,log_dir) = build_node_dir_names(ni)
    cluster = _getCluster()
    cluster.addNode (
        ni,
        CONFIG.node_ips[i], 
        clientPort = CONFIG.node_client_base_port + i,
        messagingPort= CONFIG.node_msg_base_port + i, 
        logDir = log_dir,
        logLevel = 'debug',
        home = db_dir)
    cluster.addLocalNode (ni )
    cluster.createDirs(ni)

def start_all(clusterId = None) :
    cluster = _getCluster(clusterId )
    cluster.start()
    time.sleep(3.0)  

def start_nursery( nursery_size ):
    for i in range(nursery_size):
        clu = _getCluster( nursery_cluster_ids[i])
        clu.start()
    time.sleep(0.2)
    
def stop_all(clusterId = None ):
    X.logging.info("stop_all")
    cluster = _getCluster( clusterId )
    cluster.stop()

def stop_nursery( nursery_size ):
    for i in range(nursery_size):
        clu = _getCluster( nursery_cluster_ids[i])
        clu.stop()
    
def restart_nursery( nursery_size ):
    stop_nursery(nursery_size)
    start_nursery(nursery_size)
    
def restart_all(clusterId = None):
    stop_all(clusterId)
    start_all(clusterId)

def restart_random_node():
    node_index = random.randint(0, len(node_names) - 1)
    node_name = node_names [node_index ]
    delayed_restart_nodes( [ node_name ] )

def delayed_restart_all_nodes() :
    delayed_restart_nodes( node_names )
    
def delayed_restart_nodes(node_list) :
    downtime = random.random() * 60.0
    for node_name in node_list :
        stopOne(node_name )
    time.sleep( downtime )
    for node_name in node_list :
        startOne(node_name )

def delayed_restart_1st_node ():
    delayed_restart_nodes( [ node_names[0] ] )

def delayed_restart_2nd_node ():
    delayed_restart_nodes( [ node_names[1] ] )

def delayed_restart_3rd_node ():
    delayed_restart_nodes( [ node_names[2] ] )
    
def restart_nodes_wf_sim( n ):
    wf_step_duration = 0.2
    
    for i in range (n):
        stopOne(CONFIG.node_names[i] )
        time.sleep( wf_step_duration )
    
    for i in range (n):    
        startOne(CONFIG.node_names[i] )
        time.sleep( wf_step_duration )

def getRandomString( length = 16 ) :
    def getRC ():
        return chr(random.randint(0,25) + ord('A'))

    retVal = ""
    for i in range( length ) :
        retVal += getRC()        
    return retVal

def build_node_dir_names ( nodeName, base_dir = None ):
    if base_dir is None:
        base_dir = X.tmpDir
    data_dir = '%s/%s' % (base_dir, nodeName)
    db_dir   = '%s/%s' % ( data_dir, "db")
    log_dir  = '%s/%s' % ( data_dir, "log")
    return (db_dir, log_dir)

def setup_n_nodes_base(c_id, 
                       node_names, 
                       force_master, 
                       base_dir, 
                       base_msg_port, 
                       base_client_port, 
                       extra = None):
    
    cluster = _getCluster( c_id )
    print cluster
    cluster.tearDown()
    cluster = _getCluster( c_id )
    if base_dir:
        X.logging.info( "Creating data base dir %s" % base_dir )
        X.createDir(base_dir)
    
    n = len(node_names)
    
    for i in range (n) :
        nodeName = node_names[ i ]
        (db_dir,log_dir) = build_node_dir_names( nodeName, base_dir )
        cluster.addNode(name=nodeName,
                        clientPort = base_client_port+i,
                        messagingPort = base_msg_port+i,
                        logDir = log_dir,
                        home = db_dir )
        
        cluster.addLocalNode(nodeName)
        cluster.createDirs(nodeName)

    if force_master:
        X.logging.info( "Forcing master to %s", node_names[0] )
        cluster.forceMaster(node_names[0] )
    else :
        X.logging.info( "Using master election" )
        cluster.forceMaster(None )
    #
    #
    #
    if extra : 
        X.logging.info("EXTRA!")
        config = cluster._getConfigFile()
        for k,v in extra.items():
            logging.info("%s -> %s", k, v)
            config.set("global", k, v)
        
        X.logging.info("config=\n%s", X.cfg2str(config))
        h = cluster._getConfigFileName()
        X.writeConfig(config,h)
        
    
    X.logging.info( "Creating client config" )
    regenerateClientConfig( c_id )
    
    X.logging.info( "Changing log level to debug for all nodes" )
    cluster.setLogLevel("debug")
    
    lease = int(CONFIG.lease_duration)
    X.logging.info( "Setting lease expiration to %d" % lease)
    cluster.setMasterLease( lease )
    
    
def setup_n_nodes ( n, force_master, home_dir , extra = None):
    setup_n_nodes_base(CONFIG.cluster_id, 
                       CONFIG.node_names[0:n], 
                       force_master, 
                       home_dir,
                       CONFIG.node_msg_base_port, 
                       CONFIG.node_client_base_port, 
                       extra = extra)
    
    X.logging.info( "Starting cluster" )
    start_all( CONFIG.cluster_id ) 
   
    X.logging.info( "Setup complete" )
    

def setup_3_nodes_forced_master (home_dir):
    setup_n_nodes( 3, True, home_dir)
    
def setup_2_nodes_forced_master (home_dir):
    setup_n_nodes( 2, True, home_dir)

def setup_1_node_forced_master (home_dir):
    setup_n_nodes( 1, True, home_dir)

def setup_3_nodes_mini(home_dir):
    extra = {'__tainted_tlog_entries_per_file':'1000'}
    setup_n_nodes( 3, False, home_dir, extra)
    
def setup_3_nodes (home_dir) :
    setup_n_nodes( 3, False, home_dir)

def setup_2_nodes (home_dir) :
    setup_n_nodes( 2, False, home_dir)
    
def setup_1_node (home_dir):
    setup_n_nodes( 1, False, home_dir )

default_setup = setup_3_nodes

def setup_nursery_n (n, home_dir):
    
    for i in range(n):
        c_id = CONFIG.nursery_cluster_ids[i]
        base_dir = '/'.join([CONFIG.data_base_dir, c_id])
        setup_n_nodes_base( c_id, CONFIG.nursery_nodes[c_id], False, base_dir,
                            CONFIG.node_msg_base_port + 3*i, 
                            CONFIG.node_client_base_port+3*i)
        clu = _getCluster(c_id)
        clu.setNurseryKeeper(CONFIG.nursery_keeper_id)
        
        X.logging.info("Starting cluster %s", c_id)
        clu.start()
    
    X.logging.info("Initializing nursery to contain %s" % CONFIG.nursery_keeper_id )
    
    time.sleep(5.0)
    nmgmt = NurseryManagement.NurseryManagement()
    n = nmgmt.getNursery( CONFIG.nursery_keeper_id )
    n.initialize( CONFIG.nursery_keeper_id )
    
    logging.info("Setup complete")
        
def setup_nursery_2 (home_dir):
    setup_nursery_n(2, home_dir)
    
def setup_nursery_3 (home_dir):
    setup_nursery_n(3, home_dir)
        
def dummy_teardown(home_dir):
    pass


def common_teardown( removeDirs, cluster_ids):
    X.logging.info("common_teardown(%s,%s)", removeDirs, cluster_ids)
    for cluster_id in cluster_ids:
        X.logging.info( "Stopping arakoon daemons for cluster %s" % cluster_id )
        stop_all (cluster_id )
    
        cluster = _getCluster( cluster_id)
        cluster.tearDown(removeDirs )
        cluster.remove() 

    if removeDirs:
        X.removeDirTree(CONFIG.data_base_dir )

        
def basic_teardown( removeDirs ):
    X.logging.info("basic_teardown(%s)" % removeDirs)
    for i in range( len(CONFIG.node_names) ):
        destroy_ram_fs( i )
    common_teardown( removeDirs, [CONFIG.cluster_id])
    X.logging.info( "Teardown complete" )

def nursery_teardown( removeDirs ):
    common_teardown(removeDirs, CONFIG.nursery_cluster_ids)

def get_client ( protocol_version, c_id = None):
    if c_id is None:
        c_id = CONFIG.cluster_id
    c = None
    ext = ArakoonClient.ArakoonClient()
    if protocol_version == 2:
            c = ext.getClient(c_id)
            X.logging.debug("client's config = %s", c._config)
    elif protocol_version == 1:
        cfg = ext._getClientConfig(c_id)
        nodes = cfg.getNodes()
        # we get a cfg for Arakoon2, transform it to one for Arakoon1
        nodes1 = {}
        for nn in nodes.keys():
            nip,nport = nodes[nn]
            nodes1[nn] = ([nip],nport)
        print nodes1
        cfg1 = Ara1Cfg(c_id, nodes1)
        c = Ara1.ArakoonClient(cfg1)
        print c
    
    return c

def get_nursery_client():
    ext = ArakoonClient.ArakoonClient()
    cfg = ext._getClientConfig(CONFIG.nursery_keeper_id)
    nCli = arakoon.Nursery.NurseryClient(cfg)
    return nCli

def get_nursery():
    ext = NurseryManagement.NurseryManagement()
    return ext.getNursery(CONFIG.nursery_keeper_id)

def iterate_n_times (n, f, protocol_version, startSuffix = 0, failure_max=0, valid_exceptions=None ):
    client = get_client (protocol_version = protocol_version)
    failure_count = 0
    client.recreate = False
    
    if valid_exceptions is None:
        valid_exceptions = []
        
    global test_failed
    
    for i in range ( n ) :
        if test_failed :
            X.logging.error( "Test marked as failed. Aborting.")
            break
        suffix = ( i + startSuffix )
        key = CONFIG.key_format_str % suffix
        value = CONFIG.value_format_str % suffix
        
        try:
            f(client, key, value )
        except Exception, ex:
            failure_count += 1
            fatal = True
            for valid_ex in valid_exceptions:
                if isinstance(ex, valid_ex ) :
                    fatal = False
            if failure_count > failure_max or fatal :
                client.dropConnections()
                test_failed = True
                X.logging.critical( "!!! Failing test")
                tb = traceback.format_exc()
                X.logging.critical( tb )
                raise
        if client.recreate :
            client.dropConnections()
            client = get_client(protocol_version = protocol_version)
            client.recreate = False
            
    client.dropConnections()
        

def create_and_start_thread (f ):
    class MyThread ( threading.Thread ):
        
        def __init__ (self, f, *args, **kwargs ):
            threading.Thread.__init__ ( self )
            self._f = f
            self._args = args
            self._kwargs = kwargs
        
        def run (self):
            try:
                self._f ( *(self._args), **(self._kwargs) )
            except Exception, ex:
                global test_failed
                X.logging.critical("!!! Failing test")
                tb = traceback.format_exc()
                X.logging.critical( tb )
                test_failed = True
                raise
            
    t = MyThread( f )
    t.start ()
    return t
    
def create_and_start_thread_list ( f_list ):
    return map ( create_and_start_thread, f_list )
    
def create_and_wait_for_thread_list ( f_list , timeout=None, assert_failure=True ):

    class SyncThread ( threading.Thread ):
        def __init__ (self, thr_list):
            threading.Thread.__init__ ( self )
            self.thr_list = thr_list
            
        def run (self):
            for thr in thr_list :
                thr.join()
    
    global test_failed 
    test_failed = False 
    
    thr_list = create_and_start_thread_list ( f_list )
   
    sync_thr = SyncThread ( thr_list )
    sync_thr.start()
    sync_thr.join( timeout )
    assert_false( sync_thr.isAlive() )
    if assert_failure :
        assert_false( test_failed )
    
    
def create_and_wait_for_threads ( thr_cnt, iter_cnt, f, timeout=None ):
    
    f_list = []
    for i in range( thr_cnt ) :
        g = lambda : iterate_n_times(iter_cnt, f )
        f_list.append( g )
    
    create_and_wait_for_thread_list( f_list, timeout)    
    
def mindless_simple_set( client, key, value):
    try:
        client.set( key, value)
    except Exception, ex:
        logging.info( "Error while setting => %s: %s" , ex.__class__.__name__, ex)

def simple_set(client, key, value):
    client.set( key, value )

def assert_get( client, key, value):
    assert_equals( client.get(key), value )

def set_get_and_delete( client, key, value):
    client.set( key, value )
    assert_equals( client.get(key), value )
    try:
        client.delete( key )
    except ArakoonNotFound as ex:
        logging.debug( "Caught ArakoonNotFound on delete. Ignoring" )
    assert_raises ( ArakoonNotFound, client.get, key )

def mindless_retrying_set_get_and_delete( client, key, value ):
    def validate_ex ( ex, tryCnt ):
        return True
    
    generic_retrying_set_get_and_delete( client, key, value, validate_ex )
    
    
def generic_retrying_set_get_and_delete( client, key, value, is_valid_ex):
    start = time.time()
    failed = True
    tryCnt = 0
    
    global test_failed
    
    last_ex = None 
    
    while ( failed and time.time() < start + 5.0 ) :
        try :
            tryCnt += 1
            client.set( key,value )
            assert_equals( client.get(key), value )
            try:
                client.delete( key )
            except ArakoonNotFound:
                X.logging.debug("Master switch while deleting key")
            # assert_raises ( ArakoonNotFound, client.get, key )
            failed = False
            last_ex = None
        except (ArakoonNoMaster, ArakoonNodeNotMaster), ex:
            if isinstance(ex, ArakoonNoMaster) :
                X.logging.debug("No master in cluster. Recreating client.")
            else :
                X.logging.debug("Old master is not yet ready to succumb. Recreating client")
            
            # Make sure we propagate the need to recreate the client 
            # (or the next iteration we are back to using the old one)
            client.recreate = True
            client.dropConnections()
            client = get_client() 
            
        except Exception, ex:
            X.logging.debug( "Caught an exception => %s: %s", ex.__class__.__name__, ex )
            time.sleep( 0.5 )
            last_ex = ex
            if not is_valid_ex( ex, tryCnt ) :
                # test_failed = True
                X.logging.debug( "Re-raising exception => %s: %s", ex.__class__.__name__, ex )
                raise
    
    if last_ex is not None:
        raise last_ex

    
def retrying_set_get_and_delete( client, key, value ):
    def validate_ex ( ex, tryCnt ):
        ex_msg = "%s" % ex
        validEx = False
        
        validEx = validEx or isinstance( ex, ArakoonSockNotReadable )
        validEx = validEx or isinstance( ex, ArakoonSockReadNoBytes )
        validEx = validEx or isinstance( ex, ArakoonSockRecvError )
        validEx = validEx or isinstance( ex, ArakoonSockRecvClosed )
        validEx = validEx or isinstance( ex, ArakoonSockSendError )
        validEx = validEx or isinstance( ex, ArakoonNotConnected ) 
        validEx = validEx or isinstance( ex, ArakoonNodeNotMaster )
        if validEx:
            X.logging.debug( "Ignoring exception: %s", ex_msg )
        return validEx
    
    generic_retrying_set_get_and_delete( client, key, value, validate_ex) 
    
def add_node_scenario ( node_to_add_index ):
    X.logging.info("(1) some sets")
    protocol_version = 2
    iterate_n_times( 100, simple_set, protocol_version )
    X.logging.info("(2) stopping & adding node")
    stop_all()
    add_node( node_to_add_index )
    regenerateClientConfig(CONFIG.cluster_id)
    X.logging.info("(3) starting all nodes")
    start_all()
    X.logging.info("(4) some asserts")
    iterate_n_times( 100, assert_get, protocol_version )
    X.logging.info("(5) some crud")
    iterate_n_times( 100, set_get_and_delete, protocol_version, 100)

def assert_key_value_list( start_suffix, list_size, list ):
    assert_equals( len(list), list_size )
    for i in range( list_size ) :
        suffix = start_suffix + i
        key = CONFIG.key_format_str % (suffix )
        value = CONFIG.value_format_str % (suffix )
        assert_equals ( (key,value) , list [i] )

def get_last_entries (node_id, start_i=0):
    config = getConfig(node_id)
    ip = config["ip"]
    port = config["client_port"]
    cmd = [CONFIG.binary_full_path, "--last-entries", CONFIG.cluster_id, ip, port, str(start_i)]
    X.logging.debug( "Getting last entries for %s" % node_id )
    X.logging.debug("Command is : '%s'" % cmd )
    output = X.subprocess.check_output(cmd)
    result = []
    cur_i = start_i - 1
    cur_updates = []
    for l in output.splitlines():
        if l == '':
            continue
        parts = l.split(":")
        li = parts[0]
        lup = ":".join(parts[1:])
        if li == cur_i :
            cur_updates.append(lup)
        else:
            if cur_updates != []:
                result.append( (cur_i, cur_updates) )
            cur_i = li
            cur_updates = [lup]
    
    if cur_updates != [] :
        result.append( (cur_i, cur_updates) )
    return result
    
def assert_last_i_in_sync ( node1, node2 ):
    le1 = get_last_entries (node1)
    li1, lus1 = le1[-1]
    le2 = get_last_entries (node2, int(li1) - 10 )
    li2, lus2 = le2[-1]
    diff = abs( int(li1) - int(li2) )
    assert_true (diff <= 1, "Store i's differ too much i1: %s, i2: %s" % (li1, li2))

def assert_running_nodes ( n ):
    cluster = _getCluster()
    status = cluster.getStatus()
    ok = [k for k in status.keys() if status[k] == X.AppStatusType.RUNNING]
    nr = len(ok)
    assert_equals (nr, n, "Number of expected running nodes missmatch: %s <> %s (STATUS=%s)" % (nr,n,status))

def assert_value_list ( start_suffix, list_size, list ) :
    assert_list( CONFIG.value_format_str, start_suffix, list_size, list )

def assert_key_list ( start_suffix, list_size, list ) :
    assert_list( CONFIG.key_format_str, start_suffix, list_size, list )
 
def assert_list ( format_str, start_suffix, list_size, list ) :
    assert_equals( len(list), list_size )
    
    for i in range( list_size ) :
        elem = format_str % (start_suffix + i)
        assert_equals ( elem , list [i] )

def dir_to_fs_file_name (dir_name):
    return dir_name.replace( "/", "_")

def destroy_ram_fs( node_index ) :
    nn = CONFIG.node_names[node_index]
    (mount_target,log_dir) = build_node_dir_names(nn)
    
    try :
        cmd = "umount %s" % mount_target
        run_cmd ( cmd )
    except :
        pass
    
def delayed_master_restart_loop ( iter_cnt, delay , protocol_version) :
    for i in range( iter_cnt ):
        global test_failed
        try:
            time.sleep( delay )
            cli = get_client(protocol_version)
            cli.set('delayed_master_restart_loop','delayed_master_restart_loop')
            master_id = cli.whoMaster()
            cli.dropConnections()
            stopOne( master_id )
            startOne( master_id )
        except:
            X.logging.critical("!!!! Failing test. Exception in restart loop.")
            test_failed = True
            raise
                     
def restart_loop( node_index, iter_cnt, int_start_stop, int_stop_start ) :
    for i in range (iter_cnt) :
        node = CONFIG.node_names[node_index]
        time.sleep( 1.0 * int_start_stop )
        stopOne(node)
        time.sleep( 1.0 * int_stop_start )
        startOne(node)
        

def restart_single_slave_scenario( restart_cnt, set_cnt ) :
    start_stop_wait = 3.0
    stop_start_wait = 1.0
    slave_loop = lambda : restart_loop( 1, restart_cnt, start_stop_wait, stop_start_wait )
    set_loop = lambda : iterate_n_times( set_cnt, set_get_and_delete, protocol_version = 2)
    create_and_wait_for_thread_list( [slave_loop, set_loop] )
    
    # Give the slave some time to catch up 
    time.sleep( 5.0 )
    
    assert_last_i_in_sync ( CONFIG.node_names[0], CONFIG.node_names[1] )
    compare_stores( CONFIG.node_names[0], CONFIG.node_names[1] )

def get_entries_per_tlog():
    cmd = [CONFIG.binary_full_path, "--version"]
    stdout = X.subprocess.check_process(cmd)
    return int(stdout.split('\n')[-2].split(':')[1])

def prefix_scenario( start_suffix, protocol_version):
    iterate_n_times( 100, simple_set,
                     protocol_version = protocol_version,
                     startSuffix = start_suffix )
    
    test_key_pref = CONFIG.key_format_str  % ( start_suffix + 90 ) 
    test_key_pref = test_key_pref [:-1]
    
    client = get_client(protocol_version = protocol_version)
    
    key_list = client.prefix( test_key_pref )
    X.logging.debug("key_list = %s", key_list)
    assert_key_list ( start_suffix + 90, 10, key_list)
    
    
    key_list = client.prefix( test_key_pref, 7 )
    X.logging.debug("key_list = %s", key_list)
    assert_key_list ( start_suffix + 90, 7, key_list)
    
    
    client.dropConnections ()

def range_scenario ( start_suffix, protocol_version ):

    iterate_n_times( 100, simple_set, protocol_version = 2, startSuffix = start_suffix )
    
    client = get_client(protocol_version = protocol_version)
    
    start_key = CONFIG.key_format_str % (start_suffix )
    end_key = CONFIG.key_format_str % (start_suffix + 100 )
    test_key = CONFIG.key_format_str % (start_suffix + 25)
    test_key_2 = CONFIG.key_format_str % (start_suffix + 50)
    
    key_list = client.range( test_key , True, end_key , False )
    X.logging.debug("range %s %s %s %s => key_list = %s", test_key, True, end_key, False, key_list)
    assert_key_list ( start_suffix+25, 75, key_list )
    
    key_list = client.range( test_key , False, end_key , False )
    assert_key_list ( start_suffix+26, 74, key_list )
    
    key_list = client.range( test_key, True, end_key , False, 10 )
    assert_key_list ( start_suffix+25, 10, key_list )
    
    key_list = client.range( start_key, True, test_key , False )
    assert_key_list ( start_suffix, 25, key_list)
    
    key_list = client.range( start_key, True, test_key , True )
    assert_key_list ( start_suffix, 26, key_list)
    
    key_list = client.range( start_key, True, test_key , False, 10 )
    assert_key_list ( start_suffix, 10, key_list )
    
    key_list = client.range( test_key, True, test_key_2 , False )
    assert_key_list ( start_suffix+25, 25, key_list )
    
    key_list = client.range( test_key, False, test_key_2 , True )
    assert_key_list ( start_suffix+26, 25, key_list )
    
    key_list = client.range( test_key, True, test_key_2 , False, 10 )
    assert_key_list ( start_suffix+25, 10, key_list )

def range_entries_scenario( start_suffix, protocol_version ):
    
    iterate_n_times( 100, simple_set, protocol_version, startSuffix = start_suffix)
    
    client = get_client(protocol_version)
    
    start_key = CONFIG.key_format_str % (start_suffix )
    end_suffix = CONFIG.key_format_str % ( start_suffix + 100 )
    test_key = CONFIG.key_format_str % (start_suffix + 25)
    test_key_2 = CONFIG.key_format_str % (start_suffix + 50)
    try:
        key_value_list = client.range_entries ( test_key , True, end_suffix , False )
        assert_key_value_list ( start_suffix + 25, 75, key_value_list )
    
        key_value_list = client.range_entries( test_key , False, end_suffix , False )
        assert_key_value_list ( start_suffix + 26, 74, key_value_list )
    
        key_value_list = client.range_entries( test_key, True, end_suffix , False, 10 )
        assert_key_value_list ( start_suffix + 25, 10, key_value_list )
    
        key_value_list = client.range_entries( start_key, True, test_key , False )
        assert_key_value_list ( start_suffix, 25, key_value_list)
    
        key_value_list = client.range_entries( start_key, True, test_key , True )
        assert_key_value_list ( start_suffix, 26, key_value_list)

        key_value_list = client.range_entries( start_key, True, test_key , False, 10 )
        assert_key_value_list ( start_suffix, 10, key_value_list )
    
        key_value_list = client.range_entries( test_key, True, test_key_2 , False )
        assert_key_value_list ( start_suffix + 25, 25, key_value_list )
    
        key_value_list = client.range_entries( test_key, False, test_key_2 , True )
        assert_key_value_list ( start_suffix + 26, 25, key_value_list )
    
        key_value_list = client.range_entries( test_key, True, test_key_2 , False, 10 )
        assert_key_value_list ( start_suffix + 25, 10, key_value_list )
    except Exception, ex:
        X.logging.info("on failure moment, master was: %s", client._masterId)
        raise ex
        
    
def reverse_range_entries_scenario(start_suffix, protocol_version):
    iterate_n_times(100, simple_set, protocol_version, startSuffix = start_suffix)
    client = get_client(protocol_version)
    start_key = CONFIG.key_format_str % (start_suffix)
    end_key = CONFIG.key_format_str % (start_suffix + 100)
    try:
        kv_list0 = client.range_entries("a", True,"z", True, 10)
        for t in kv_list0:
            X.logging.info("t=%s",t)
        X.logging.info("now reverse")
        kv_list = client.rev_range_entries("z", True, "a", True, 10)
        for t in kv_list:
            X.logging.info("t=%s", t)
        assert_equals( len(kv_list), 10)
        assert_equals(kv_list[0][0], 'key_000000001099')
    except Exception, ex:
        raise ex

