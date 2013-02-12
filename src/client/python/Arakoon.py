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

"""
Arakoon client module
"""


import sys
import time
import random
import threading

from ArakoonProtocol import *
from ArakoonExceptions import *
from ArakoonClientConnection import *
from ArakoonValidators import SignatureValidator

from functools import wraps


FILTER = ''.join([(len(repr(chr(x)))==3) and chr(x) or '.' for x in range(256)])

def dump(src, length=8):
    N = 0
    result = ''
    while src:
        s, src = src[:length], src[length:]
        hexa = ' '.join(["%02X"%ord(x) for x in s])
        s = s.translate(FILTER)
        result += "%04X   %-*s   %s\n" % (N, length*3, hexa, s)
        N += length
    return result

# Seed the random generator
random.seed ( time.time() )


def retryDuringMasterReelection (f):
    @wraps(f)    
    def retrying_f (self,*args,**kwargs):    
        start = time.time()
        tryCount = 0.0
        backoffPeriod = 0.2
        callSucceeded = False
        retryPeriod = ArakoonClientConfig.getNoMasterRetryPeriod ()
        deadline = start + retryPeriod
        while( not callSucceeded and time.time() < deadline ): 
            try :
                retVal = f(self,*args,**kwargs)
                callSucceeded = True
            except (ArakoonNoMaster, ArakoonNodeNotMaster, ArakoonSocketException, ArakoonNotConnected) as ex:
                if len( self._config.getNodes().keys()) == 0 :
                    raise ArakoonInvalidConfig( "Empty client configuration" )
                self._masterId = None
                self.dropConnections()
                sleepPeriod = backoffPeriod * tryCount
                if time.time() + sleepPeriod > deadline :
                    raise 
                tryCount += 1.0
                ArakoonClientLogger.logWarning( "Master not found (%s). Retrying in %0.2f sec." % (ex, sleepPeriod) )
                time.sleep( sleepPeriod )
        return retVal
    
    return retrying_f
    
class ArakoonClient :

    def __init__ (self, config=None):
        """
        Constructor of an Arakoon client object.

        It takes one optional paramater 'config'.
        This parameter contains info on the arakoon server nodes.
        See the constructor of L{ArakoonClientConfig} for more details.

        @type config: L{ArakoonClientConfig}
        @param config: The L{ArakoonClientConfig} object to be used by the client. Defaults to None in which
            case a default L{ArakoonClientConfig} object will be created.
        """
        if config is None:
            config = ArakoonClientConfig()
        self._initialize( config )
        self.__lock = threading.RLock()
        self._masterId = None
        self._connections = dict()
        self._allowDirty = False
        nodeList = self._config.getNodes().keys()
        if len(nodeList) == 0:
            raise ArakoonInvalidConfig("Node list empty.")
        self._dirtyReadNode = random.choice( nodeList )
    
    def allowDirtyReads(self):
        """
        Allow the client to read values from a potential slave. 
        
        Enabling this can give back outdated values!
        """
        self._allowDirty = True
        
    def disallowDirtyReads(self):
        """
        Disallow the client to read values from a potential slave.   
        
        Enabling dirty reads can give back outdated values!
        """
        self._allowDirty = False

    def _initialize(self, config ):
        self._config = config

    @SignatureValidator('string')
    def setDirtyReadNode(self, node):
        """
        Set the node that will be used for dirty read operations
        
        @type node : string
        @param node : the node identifier
        @rtype: void
        """
        if node not in self._config.getNodes().keys():
            raise ArakoonUnknownNode( node )
        self._dirtyReadNode = node

    @retryDuringMasterReelection 
    def getKeyCount (self) :
        """
        Retrieve the number of keys in the database on the master
        
        @rtype: int
        """
        encoded = ArakoonProtocol.encodeGetKeyCount()
        conn = self._sendToMaster(encoded)
        return conn.decodeInt64Result()        
    
    def getDirtyReadNode(self):
        """
        Retrieve the node that will be used for dirty read operations
        
        @rtype: string
        @return : the node identifier
        """
        return self._dirtyReadNode

    @retryDuringMasterReelection
    @SignatureValidator( 'string' )
    def ping (self, clientId, clusterId = 'arakoon'):
        """
        send a hello message to the node with your id and the cluster id.
        

        Will return the server node identifier and the version of arakoon it is running

        @type clientId  : string
        @type clusterId : string
        @param clusterId : must match the cluster_id of the node
        @rtype: string
        @return: The master identifier and its version in a single string
        """
        encoded = ArakoonProtocol.encodePing(clientId,clusterId)
        conn = self._sendToMaster(encoded)
        return conn.decodeStringResult()

    @retryDuringMasterReelection
    @SignatureValidator( 'string' )
    def exists(self, key):
        """
        @type key : string
        @param key : key
        @returen : True if there is a value for that key, False otherwise
        """
        msg = ArakoonProtocol.encodeExists(key, self._allowDirty)
        if self._allowDirty:
            conn = self._sendMessage(self._dirtyReadNode, msg)
        else:
            conn = self._sendToMaster (msg)
        return conn.decodeBoolResult()

    @retryDuringMasterReelection
    @SignatureValidator( 'string' )
    def get(self, key):
        """
        Retrieve a single value from the store.

        Retrieve the value associated with the given key

        @type key: string
        @param key: The key whose value you are interested in
        @rtype: string
        @return: The value associated with the given key
        """
        msg = ArakoonProtocol.encodeGet(key, self._allowDirty)
        if self._allowDirty:
            conn = self._sendMessage(self._dirtyReadNode, msg)
        else:
            conn = self._sendToMaster (msg)
        result = conn.decodeStringResult()
        return result

    @retryDuringMasterReelection
    def multiGet(self,keys):
        """
        Retrieve the values for the keys in the given list.

        @type key: string list
        @rtype: string list
        @return: the values associated with the respective keys
        """
        msg = ArakoonProtocol.encodeMultiGet(keys, self._allowDirty)
        if self._allowDirty:
            conn = self._sendMessage(self._dirtyReadNode, msg)
        else:
            conn = self._sendToMaster (msg)
        result = conn.decodeStringListResult()
        return result
    
    @retryDuringMasterReelection
    @SignatureValidator( 'string', 'string' )
    def set(self, key, value):
        """
        Update the value associated with the given key.

        If the key does not yet have a value associated with it, a new key value pair will be created.
        If the key does have a value associated with it, it is overwritten.
        For conditional value updates see L{testAndSet}

        @type key: string
        @type value: string
        @param key: The key whose associated value you want to update
        @param value: The value you want to store with the associated key

        @rtype: void
        """
        msg = ArakoonProtocol.encodeSet( key, value ) 
        conn = self._sendToMaster (msg)
        conn.decodeVoidResult()

    @retryDuringMasterReelection
    @SignatureValidator('string','string')
    def confirm(self, key,value):
        """
        Do nothing if the value associated with the given key is this value; 
        otherwise, behave as set(key,value)
        @rtype: void
        """
        msg = ArakoonProtocol.encodeConfirm(key,value)
        conn = self._sendToMaster(msg)
        conn.decodeVoidResult()
        
    @retryDuringMasterReelection
    @SignatureValidator('string','string_option')
    def aSSert(self, key, vo):
        """
        verifies the value for key to match vo
        @type key: string
        @type vo: string_option
        @param key: the key to be verified
        @param vo: what the value should be (can be None)
        @rtype: void
        """
        msg = ArakoonProtocol.encodeAssert(key, vo, self._allowDirty)
        if self._allowDirty:
            conn = self._sendMessage(self._dirtyReadNode, msg)
        else:
            conn = self._sendToMaster (msg)
        result = conn.decodeVoidResult()
        return result

    @retryDuringMasterReelection
    def aSSert_exists(self, key):
        """
        verifies the value for key exists
        @type key: string
        @param key: the key to be verified
        @rtype: void
        """
        msg = ArakoonProtocol.encodeAssert_exists(key, self._allowDirty)
        if self._allowDirty:
            conn = self._sendMessage(self._dirtyReadNode, msg)
        else:
            conn = self._sendToMaster (msg)
        result = conn.decodeVoidResult()
        return result

    @retryDuringMasterReelection
    @SignatureValidator( 'sequence' )
    def sequence(self, seq, sync = False):
        """
        Try to execute a sequence of updates. 
        if sync is true then the filesystem on 
        server side will get synchronised right after the update.

        It's all-or-nothing: either all updates succeed, or they all fail.
        @type seq: Sequence
        """
        encoded = ArakoonProtocol.encodeSequence(seq, sync)
        conn = self._sendToMaster(encoded)
        conn.decodeVoidResult()
    
    @retryDuringMasterReelection
    @SignatureValidator( 'string' )
    def delete(self, key):
        """
        Remove a key-value pair from the store.

        @type key: string
        @param key: Remove this key and its associated value from the store

        @rtype: void
        """
        conn = self._sendToMaster ( ArakoonProtocol.encodeDelete( key ) )
        conn.decodeVoidResult()


    __setitem__= set
    __getitem__= get
    __delitem__= delete
    __contains__ = exists
    
    @retryDuringMasterReelection
    @SignatureValidator( 'string_option', 'bool', 'string_option', 'bool', 'int' )
    def range(self, beginKey, beginKeyIncluded, endKey, endKeyIncluded, maxElements = 100 ):
        """
        Perform a range query on the store, retrieving the set of matching keys

        Retrieve a set of keys that lexographically fall between the beginKey and the endKey
        You can specify whether the beginKey and endKey need to be included in the result set
        Additionaly you can limit the size of the result set to maxElements. Default is to return all matching keys.

        @type beginKey: string option
        @type beginKeyIncluded: boolean
        @type endKey :string option
        @type endKeyIncluded: boolean
        @type maxElements: integer option
        @param beginKey: Lower boundary of the requested range
        @param beginKeyIncluded: Indicates if the lower boundary should be part of the result set
        @param endKey: Upper boundary of the requested range
        @param endKeyIncluded: Indicates if the upper boundary should be part of the result set
        @param maxElements: The maximum number of keys to return. None no maximum, all matches will be returned. Defaults to 100.

        @rtype: list of strings
        @return: Returns a list containing all matching keys
        """
        msg = ArakoonProtocol.encodeRange( beginKey, beginKeyIncluded, endKey,
                                           endKeyIncluded, maxElements, self._allowDirty)
        if self._allowDirty:
            conn = self._sendMessage(self._dirtyReadNode, msg)
        else:
            conn = self._sendToMaster (msg)
        return conn.decodeStringListResult()
    
    @retryDuringMasterReelection
    @SignatureValidator( 'string_option', 'bool', 'string_option', 'bool', 'int' )
    def range_entries(self,
                      beginKey,
                      beginKeyIncluded,
                      endKey,
                      endKeyIncluded,
                      maxElements= 100):
        """
        Perform a range query on the store, retrieving the set of matching key-value pairs

        Retrieve a set of keys that lexographically fall between the beginKey and the endKey
        You can specify whether the beginKey and endKey need to be included in the result set
        Additionaly you can limit the size of the result set to maxElements. Default is to return all matching keys.

        @type beginKey: string option
        @type beginKeyIncluded: boolean
        @type endKey :string option
        @type endKeyIncluded: boolean
        @type maxElements: integer
        @param beginKey: Lower boundary of the requested range
        @param beginKeyIncluded: Indicates if the lower boundary should be part of the result set
        @param endKey: Upper boundary of the requested range
        @param endKeyIncluded: Indicates if the upper boundary should be part of the result set
        @param maxElements: The maximum number of key-value pairs to return. None means no maximum, all matches will be returned. Defaults to 100.

        @rtype: list of (string,string)
        @return: Returns a list containing all matching key-value pairs
        """
        msg = ArakoonProtocol.encodeRangeEntries(beginKey,
                                                 beginKeyIncluded,
                                                 endKey,
                                                 endKeyIncluded,
                                                 maxElements,
                                                 self._allowDirty)
        if self._allowDirty:
            conn = self._sendMessage(self._dirtyReadNode, msg)
        else:
            conn = self._sendToMaster (msg)
        result = conn.decodeStringPairListResult()
        return result

    @retryDuringMasterReelection
    @SignatureValidator('string_option', 'bool', 'string_option', 'bool','int')
    def rev_range_entries(self,
                          beginKey, beginKeyIncluded,
                          endKey,  endKeyIncluded,
                          maxElements= 100):
        """ 
        Performs a reverse range query on the store, returning a sorted (in reverse order) list of key value pairs.
        @type beginKey: string option
        @type endKey :string option
        @type beginKeyIncluded: boolean
        @type endKeyIncluded: boolean
        @type maxElements: integer
        @param beginKey: higher boundary of the requested range
        @param endKey: lower boundary of the requested range
        @param maxElements: maximum number of key-value pairs to return. None means 'all'. Defaults to 100
        @rtype : list of (string,string)
        """
        msg = ArakoonProtocol.encodeReverseRangeEntries(beginKey,
                                                        beginKeyIncluded,
                                                        endKey,
                                                        endKeyIncluded,
                                                        maxElements,
                                                        self._allowDirty)
        if self._allowDirty:
            conn = self._sendMessage(self._dirtyReadNode, msg)
        else:
            conn = self._sendToMaster (msg)
        result = conn.decodeStringPairListResult()
        return result

    
    @retryDuringMasterReelection
    @SignatureValidator( 'string', 'int' )
    def prefix(self, keyPrefix , maxElements = None ):
        """
        Retrieve a set of keys that match with the provided prefix.

        You can indicate whether the prefix should be included in the result set if there is a key that matches exactly
        Additionaly you can limit the size of the result set to maxElements

        @type keyPrefix: string
        @type maxElements: integer option
        @param keyPrefix: The prefix that will be used when pattern matching the keys in the store
        @param maxElements: The maximum number of keys to return. None means all matches will be returned. Defaults to None.

        @rtype: list of strings
        @return: Returns a list of keys matching the provided prefix
        """
        msg = ArakoonProtocol.encodePrefixKeys( keyPrefix, maxElements, self._allowDirty)
        if self._allowDirty:
            conn = self._sendMessage(self._dirtyReadNode, msg)
        else:
            conn = self._sendToMaster (msg)
        return conn.decodeStringListResult( )

    def whoMaster(self):
        self._determineMaster()
        return self._masterId

    def expectProgressPossible(self):
        """
        @return: true if the master thinks progress is possible, false otherwise
        """
        msg = ArakoonProtocol.encodeExpectProgressPossible()
        try:
            conn = self._sendToMaster(msg)
            return conn.decodeBoolResult()
        except ArakoonNoMaster:
            return False

    def getVersion(self, nodeId = None):
        """
        will return a tuple containing major, minor and patch level versions of the server side
        @type nodeId : String
        @param nodeId : id of the node you want to query (None if you want to query the master)
        @rtype : (int,int,int,string)
        @return : (major, minor, patch, info)
        """
        msg = ArakoonProtocol.encodeGetVersion()
        conn = None
        if nodeId is None:
            conn = self._sendToMaster(msg)
        else:
            conn = self._sendMessage(nodeId, msg )

        result = conn.decodeVersionResult()
        
        return result


    def statistics(self):
        """
        @return a dictionary with some statistics about the master
        """
        msg = ArakoonProtocol.encodeStatistics()
        conn = self._sendToMaster(msg)
        return conn.decodeStatistics()

    @retryDuringMasterReelection
    @SignatureValidator( 'string', 'string_option', 'string_option' )
    def testAndSet(self, key, oldValue, newValue):
        """
        Conditionaly update the value associcated with the provided key.

        The value associated with key will be updated to newValue if the current value in the store equals oldValue
        If the current value is different from oldValue, this is a no-op.
        Returns the value that was associated with key in the store prior to this operation. This way you can check if the update was executed or not.

        @type key: string
        @type oldValue: string option
        @type newValue: string
        @param key: The key whose value you want to updated
        @param oldValue: The expected current value associated with the key.
        @param newValue: The desired new value to be stored.

        @rtype: string
        @return: The value that was associated with the key prior to this operation
        """
        msg = ArakoonProtocol.encodeTestAndSet( key, oldValue, newValue )
        conn = self._sendToMaster( msg )
        return conn.decodeStringOptionResult()
        
    @retryDuringMasterReelection
    @SignatureValidator('string', 'string_option')
    def userFunction(self, name, argument): #pylint: disable-msg=C0103
        '''Call a user-defined function on the server
        @param name: Name of user function
        @type name: string
        @param argument: Optional function argument
        @type argument: string option

        @return: Function result
        @rtype: string option
        '''
          
        msg = ArakoonProtocol.encodeUserFunction(name, argument)
        conn = self._sendToMaster(msg)
        return conn.decodeStringOptionResult()

    @retryDuringMasterReelection
    def getNurseryConfig(self):
        msg = ArakoonProtocol.encodeGetNurseryCfg()
        con = self._sendToMaster(msg)
        return con.decodeNurseryCfgResult()
        
    def _determineMaster(self):
        nodeIds = []

        if self._masterId is None:
            # Prepare to ask random nodes who is master
            nodeIds = self._config.getNodes().keys()
            random.shuffle( nodeIds )

            while self._masterId is None and len(nodeIds) > 0 :
                node = nodeIds.pop()
                try :
                    self._masterId = self._getMasterIdFromNode( node )
                    tmpMaster = self._masterId

                    try :
                        if self._masterId is not None :
                            if self._masterId != node and not self._validateMasterId ( self._masterId ) :
                                self._masterId = None
                        else :
                            ArakoonClientLogger.logWarning( "Node '%s' does not know who the master is", node )
                        
                    except Exception, ex :
                        
                        ArakoonClientLogger.logWarning( "Could not validate master on node '%s'", tmpMaster )
                        ArakoonClientLogger.logDebug( "%s: %s" % (ex.__class__.__name__, ex))
                        self._masterId = None
                            
                        
                except Exception, ex :
                    # Exceptions will occur when nodes are down, simply ignore and try the next node
                    ArakoonClientLogger.logWarning( "Could not query node '%s' to see who is master", node )
                    ArakoonClientLogger.logDebug( "%s: %s" % (ex.__class__.__name__, ex))
                

        if self._masterId is None:
            ArakoonClientLogger.logError( "Could not determine master."  )
            raise ArakoonNoMaster()

    def _sendToMaster(self, msg):

        self._determineMaster()

        retVal = self._sendMessage(self._masterId, msg )

        if retVal is None :
            raise ArakoonNoMasterResult ()
        return retVal

    def _validateMasterId(self, masterId):
        if masterId is None:
            return False

        otherMasterId = self._getMasterIdFromNode(masterId)
        return masterId == otherMasterId

    def _getMasterIdFromNode(self, nodeId):
        conn = self._sendMessage( nodeId , ArakoonProtocol.encodeWhoMaster() )
        masterId = conn.decodeStringOptionResult( )
        return masterId

    def _sleep(self, timeout):
        time.sleep( timeout )

    def _sendMessage(self, nodeId, msgBuffer, tryCount = -1):

        result = None

        if tryCount == -1 :
            tryCount = self._config.getTryCount()

        for i in range(tryCount) :

            if i > 0:
                maxSleep = i * ArakoonClientConfig.getBackoffInterval()
                self._sleep( random.randint(0, maxSleep) )

            with self.__lock :

                try :
                    connection = self._getConnection( nodeId )
                    total = ArakoonProtocol.close(msgBuffer)
                    #print dump(total)
                    connection.send( total )

                    # Message sent correctly, return client connection so result can be read
                    result = connection
                    break

                except Exception, ex:
                    fmt = "Attempt %d to exchange message with node %s failed with error (%s: '%s')."
                    ArakoonClientLogger.logWarning( fmt , i, nodeId, ex.__class__.__name__, ex )

                    # Get rid of the connection in case of an exception
                    self._connections[nodeId].close()
                    del self._connections[ nodeId ] 
                    self._masterId = None

        if result is None:
            # If result is None, this means that all retries failed.
            # Re-raise the last exception to escalate the problem
            raise

        return result

    def _getConnection(self, nodeId):
        connection = None
        if self._connections.has_key( nodeId ) :
            connection = self._connections [ nodeId ]

        if connection is None:
            nodeLocation = self._config.getNodeLocation( nodeId )
            clusterId = self._config.getClusterId()
            connection = ArakoonClientConnection ( nodeLocation , clusterId)
            self._connections[ nodeId ] = connection

        return connection

    def dropConnections(self ):
        keysToRemove = self._connections.keys()
        
        for key in keysToRemove:
            self._connections[key].close()
            del self._connections[ key ] 

