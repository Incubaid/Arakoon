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

sys.path.append( '../server' )

from pymonkey import InitBase

import copy
import re
import logging
import random
import sys
import smtplib
import traceback

from pymonkey import q
from arakoon_monkey_config import *
from system_tests_common import *

MEM_MAX_KB = 1024 * 128
monkey_dies = False

def get_monkey_work_dir() :
    return q.system.fs.joinPaths( q.dirs.tmpDir, "arakoon_monkey" )

def get_work_list_log_read ( iter_cnt ):
    return get_work_list_log ( iter_cnt, "r")

def get_work_list_log_write ( iter_cnt ):
    return get_work_list_log ( iter_cnt, "w")

def get_work_list_log ( iter_cnt, flag ):
    log_file_name = q.system.fs.joinPaths( get_monkey_work_dir() , "arakoon_monkey_%012d.wlist" % iter_cnt )
    file = open( log_file_name , flag )
    return file 
    
def generate_work_list( iter_cnt ):
    
    global disruptive_f 
    log = get_work_list_log_write( iter_cnt )
    
    admin_f = random.choice( monkey_disruptions_catalogue )
    disruption = "%s\n" %  admin_f[0].func_name
    logging.info( "Disruption for this iteration is: %s" % disruption.strip() )
    log.write ( disruption )
    disruptive_f = admin_f[0] 
    
    work_list_size = random.randint( 2, AM_WORK_LIST_MAX_ITEMS)
    
    f_list = []
    
    for i in range(work_list_size):
        cat_entry =  random.choice( monkey_catalogue )
        fun = cat_entry[0] 
        
        if ( cat_entry [1] == True ) :
            random_n = random.randint( 100, AM_MAX_WORKITEM_OPS )
            work_item = "%s %d %d\n" % (fun.func_name, random_n, i*AM_MAX_WORKITEM_OPS )
            logging.info( "Adding work item: %s" % work_item.strip() )
            log.write( work_item )
            tmp_f = generate_lambda( iterate_n_times, random_n, fun, i*AM_MAX_WORKITEM_OPS )
         
        else :
            work_item = "%s %d\n" % (fun.func_name, i*AM_MAX_WORKITEM_OPS)
            log.write ( work_item )
            logging.info( "Adding work item: %s" % work_item.strip())
            tmp_f = generate_lambda( fun, i*AM_MAX_WORKITEM_OPS)
        
        f_list.append( generate_lambda( wrapper, tmp_f ) )
        
    log.close()
    return (disruptive_f, f_list ) 

def build_function_dict() :
    ret_val = dict()
    for item in monkey_catalogue:
        ret_val[ item[0].func_name ] = item
        
    for item in monkey_disruptions_catalogue:
        ret_val[ item[0].func_name ] = item

    return ret_val

f_dict = build_function_dict()
disruptive_f = dummy 

def wrapper( f ):
    try:
        f()
    except Exception,ex:
        valid_ex = False
        ex_msg = "%s" % ex
        regexes = f_dict[ disruptive_f.func_name ] [1]
        for regex in regexes:
            if re.match( regex, ex_msg ) :
                valid_ex = True
        if not valid_ex :
            global monkey_dies
            monkey_dies = True
            raise
        else :
            logging.fatal( "Wiping exception under the rug (%s: '%s')" ,ex.__class__.__name__, ex_msg )
            
def play_iteration( iteration ):
    global disruptive_f
    
    log = get_work_list_log_read( iteration )
    lines = log.readlines()
     
    
    thr_list = list() 
    
    for line in lines:
        line = line.strip()
        parts = line.split( " " )
        parts_len = len(parts)
        if parts_len == 1 :
            # thr = create_and_start_thread( f_dict[ parts[0] ][0]  )
            thr = None
            disruptive_f = f_dict [ parts[0].strip() ]
        if parts_len == 2 :
            tmp_f = generate_lambda( f_dict[ parts[0] ][0], int(parts[1] ) )
            thr = create_and_start_thread( generate_lambda(wrapper, tmp_f) )
        if parts_len == 3 :
            tmp_f = generate_lambda( iterate_n_times, int(parts[1]), f_dict[parts[0]][0], int(parts[2]))
            thr = create_and_start_thread( generate_lambda( wrapper, tmp_f ))
        
        if thr is not None:
            thr_list.append( thr )
        
    
    disruptive_f ()
    
    for thr in thr_list:
        thr.join()

def health_check() :
   
    logging.info( "Starting health check" )
 
    cli = get_client() 
    encodedPing = arakoon.ArakoonProtocol.ArakoonProtocol.encodePing( "me", cluster_id )
    
    global monkey_dies
    
    if ( monkey_dies ) : 
        return
    
    # Make sure all processes are running
    assert_running_nodes( 3 )
    
    # Do a hello to all nodes
    for node in node_names :
        try :
            con = cli._sendMessage( node, encodedPing )
            reply = con.decodeStringResult()
            logging.info ( "Node %s is responsive: '%s'" , node, reply )
        except Exception, ex:     
            monkey_dies = True
            logging.fatal( "Node %s is not responding: %s:'%s'", node, ex.__class__.__name__, ex )
            
    if ( monkey_dies ) :
        return
    
    key = "@@some_key@@"
    value = "@@some_value@@"
    
    # Perform a basic set get and delete to see the cluster can make progress
    cli.set( key, value )
    assert_equals( cli.get( key ), value )
    cli.delete( key )
    assert_raises( ArakoonNotFound, cli.get, key ) 
    
    # Give the nodes some time to sync up
    time.sleep(2.0)
    stop_all()
    
    # Make sure the tlogs are in sync
    assert_last_i_in_sync( node_names[0], node_names[1] )
    assert_last_i_in_sync( node_names[1], node_names[2] )
    # Make sure the stores are equal
    
    compare_stores( node_names[0], node_names[1] )
    compare_stores( node_names[2], node_names[1] )
    
    
    cli._dropConnections()
    
    if not check_disk_space():
        logging.critical("SUCCES! Monkey filled the disk to its threshold")
        sys.exit(0)
    
    logging.info("Cluster is healthy!")

def check_disk_space():
    cmd = "df -h | awk ' { if ($6==\"/\") print $5 } ' | cut -d '%' -f 1"
    (exit,stdout,stderr) = q.system.process.run(cmd)
    if( exit != 0 ):
        raise Exception( "Could not determine free disk space" )
    stdout = stdout.strip()
    disk_free = int( stdout )
    free_threshold = 95
    if disk_free > free_threshold :
        return False
    logging.info( "Still under free disk space threshold. Used space: %d%% < %d%% " % (disk_free,free_threshold) ) 
    return True

def memory_monitor():
    global monkey_dies
    
    while monkey_dies == False :
        for name in node_names:
            used = get_memory_usage( name )
            
            if used > MEM_MAX_KB:
                logging.critical( "!!!! %s uses more than %d kB of memory (%d) " % (name, MEM_MAX_KB, used))
                stop_all()
                monkey_dies = True
            else :
                logging.info( "Node %s under memory threshold (%d)" % (name, used) )
        time.sleep(10.0)
                
def make_monkey_run() :
  
    global monkey_dies
    
    system_tests_common.data_base_dir = '/opt/qbase3/var/tmp/arakoon-monkey'
    
    t = threading.Thread( target=memory_monitor)
    t.start()
    
    stop_all()
    q.config.arakoon.tearDown(cluster_id) 
    #setup_3_nodes_forced_master()
    setup_3_nodes( system_tests_common.data_base_dir )
    time.sleep( 5.0 )
    monkey_dir = get_monkey_work_dir()
    if q.system.fs.exists( monkey_dir ) :
        q.system.fs.removeDirTree( monkey_dir )
    q.system.fs.createDir( monkey_dir )
    iteration = 0 
    start_all()
    time.sleep( 1.0 )
    while( True ) :
        iteration += 1
        logging.info( "Preparing iteration %d" % iteration )
        thr_list = list ()
        try:
            (disruption, f_list) = generate_work_list( iteration )
            logging.info( "Starting iteration %d" % iteration )
            thr_list = create_and_start_thread_list( f_list )
            
            disruption ()
            
            for thr in thr_list :
                thr.join(60.0 * 60.0)
                if thr.isAlive() :
                    logging.fatal( "Thread did not complete in a timely fashion.")
                    monkey_dies = True
            
            if not monkey_dies:
                logging.info( "Work is done. Starting little safety nap." )
                time.sleep( lease_duration )     
                health_check ()
        except SystemExit, ex:
            if str(ex) == "0":
                sys.exit(0)
            else :
                logging.fatal( "Caught SystemExit => %s: %s" %(ex.__class__.__name__, ex) )
                tb = traceback.format_exc()
                logging.fatal( tb )
                for thr in thr_list :
                    thr.join() 
                monkey_dies = True

        except Exception, ex:
            logging.fatal( "Caught fatal exception => %s: %s" %(ex.__class__.__name__, ex) )
            tb = traceback.format_exc()
            logging.fatal( tb )
            for thr in thr_list :
                thr.join() 
            monkey_dies = True
            
        if monkey_dies :
            euthanize_this_monkey ()
 
        rotate_logs(5,False)
        
        toWipe = node_names[random.randint(0,2)]
        #logging.info("Wiping node %s" % toWipe)
        #whipe(toWipe)
        
        toCollapse = node_names[random.randint(0,2)]
        while toCollapse == toWipe:
            toCollapse = node_names[random.randint(0,2)]
        collapse_candidate_count = get_tlog_count (toCollapse ) -1 
        if collapse_candidate_count > 0 :
            logging.info("Collapsing node %s" % toCollapse )
            if collapse(toCollapse, collapse_candidate_count ) != 0:
                logging.error( "Could not collapse tlog of node %s" % toCollapse )
        
        start_all()
 
def send_email(from_addr, to_addr_list, cc_addr_list,
              subject, message,
              login, password,
              smtpserver ):
    
    import smtplib
    
    header  = 'From: %s\n' % from_addr
    header += 'To: %s\n' % ','.join(to_addr_list)
    header += 'Cc: %s\n' % ','.join(cc_addr_list)
    header += 'Subject: %s\n\n' % subject
    message = header + message
 
    server = smtplib.SMTP ()
    server.connect(smtpserver)
    server.starttls()
    server.login(login,password)
    problems = server.sendmail(from_addr, to_addr_list, message)
    server.quit()
    return problems

def get_mail_escalation_cfg() :
    
    cfg_file = q.config.getInifile("arakoon_monkey")
    cfg_file_dict = cfg_file.getFileAsDict() 
    
    if ( len( cfg_file_dict.keys() ) == 0) :
        raise Exception( "Escalation ini-file empty" )
    if not cfg_file_dict.has_key ( "email" ):
        raise Exception ( "Escalation ini-file does not have a 'email' section" )
    
    cfg = cfg_file_dict [ "email" ]
    
    required_keys = [
        "server",
        "port",
        "from",
        "to",
        "login",
        "password",
        "subject",
        "msg"
        ]
    
    missing_keys = []
    for key in required_keys :
        if not cfg.has_key( key ) :
            missing_keys.append( key )
    if len(missing_keys) != 0 :
        raise Exception( "Required key(s) missing in monkey escalation config file: %s" % missing_keys )
    
    split_to = []
    for to in cfg["to"].split(",") :
        to = to.strip()
        if len( to ) > 0 :
            split_to.append ( to )
    
    cfg["to"] = split_to
    
    return cfg
    
def escalate_dying_monkey() :
    
    cfg = get_mail_escalation_cfg()
   
    logging.info( "Sending mails to : %s" % cfg["to"] )
 
    problems = send_email( cfg["from"], cfg["to"], [] ,
                cfg["subject"], cfg["msg"], cfg["login"], cfg["password"] ,
                "%s:%d" % (cfg["server"], int(cfg["port"]) ) )
    
    if ( len(problems) != 0 ) :
        logging.fatal("Could not send mail to the following recipients: %s" % problems ) 
    
    
def euthanize_this_monkey() :
    logging.fatal( "This monkey is going to heaven" )
    try :
        escalate_dying_monkey()
    except Exception, ex:
        logging.fatal( "Could not escalate dead monkey => %s: '%s'" % (ex.__class__.__name__, ex) )
    stop_all()
    sys.exit( 255 )
    
if __name__ == "__main__" :
    logger = logging.getLogger()
    logger.setLevel(logging.DEBUG)
    ch = logging.StreamHandler()
    ch.setLevel(logging.DEBUG)
    formatter = logging.Formatter("%(asctime)s - %(levelname)s - %(message)s")
    ch.setFormatter(formatter)
    logger.addHandler(ch)

    make_monkey_run()
