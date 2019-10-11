#!/bin/bash

# The MIT License (MIT)
#
# Copyright (c) 2015 Microsoft Azure
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# Author: Cognosys Technologies
 
### 
### Warning! This script partitions and formats disk information be careful where you run it
###          This script is currently under development and has only been tested on Ubuntu images in Azure
###          This script is not currently idempotent and only works for provisioning at the moment

### Remaining work items
### -Alternate discovery options (Azure Storage)
### -Implement Idempotency and Configuration Change Support
### -Recovery Settings (These can be changed via API)

help()
{
    echo "This script installs Apache Kafka cluster on Ubuntu.
    
Usage: $0 [-h] [-k [kafka-version]] [-z [zookeeper-version]] [-b broker-id] [-l listeners] [-i zookeeper-ip] [-c instance-count] [-K kafka-source] [-Z zookeeper-source]

Options:
  -k
        kafka version - Install specified Apache Kafka version (like '2.3.0').
        The version parameter is optional.
  -z
        zookeeper version - If Apache Zookeeper version is specified, then it
        will be installed and it also means that Kafka will NOT be installed.
        The version (like '3.5.5') MUST exist in the 'zookeeper-source'.
        The version parameter is optional.
  -b
        broker id - It is required when installing Kafka. Every instance MUST
        have a unique broker ID.
  -l
        listeners - Can be used when installing Kafka to set up listener.
        On some network configurations this should be set to IP address or
        hostname. 
  -i
        zookeeper private IP address prefix - It is used when installing both
        Kafka and Zookeeper (see instance count).
  -c
        instance count - specifies a range of IP addresses that will be 
        configured in both Kafka and Zookeeper. The range begins at IP
        defined using 'zookeeper-ip' and the rest of IPs are calculated.
  -K
        kafka source - defines the mirror for Apache Kafka. The script expects
        the source to be a directory which contains a file in a standard format
        defined by both directory and name like '/2.3.0/kafka_2.12-2.3.0.tgz'
  -Z
        zookeeper source - defines the mirror for Zookeeper. The script expects
        the source to be a directory which contains a file in a standard format
        like 'apache-zookeeper-3.5.5.tar.gz'
        in both Kafka and Zookeeper. The range begins at 'zookeeper-ip'.
  -h
        display this help content"
}

log()
{
	# If you want to enable this logging add a un-comment the line below and add your account key 
	#curl -X POST -H "content-type:text/plain" --data-binary "$(date) | $(hostname) | $1" https://logs-01.loggly.com/inputs/[account-key]/tag/kafka-test,${HOSTNAME}
	echo "$1"
}

log "Begin execution of kafka script extension on $(hostname)"

if [ "${UID}" -ne 0 ];
then
    log "Script executed without root permissions"
    echo "error: You must be root to run this program." >&2
    exit 1
fi

# TEMP FIX - Re-evaluate and remove when possible
# This is an interim fix for hostname resolution in current VM
grep -q "$(hostname)" /etc/hosts
if [ $? -eq 0 ]; then
  log "hostname $(hostname) found in /etc/hosts"
else
  log "hostname $(hostname) NOT found in /etc/hosts"
  # Append it to the hosts file if not there
  echo "127.0.0.1 $(hostname)" >> /etc/hosts
  log "hostname $(hostname) added to /etc/hosts"
fi

# Get optional argument
getopts_optional_argument() {
  eval next_token=\${$OPTIND}
  if [[ -n $next_token && $next_token != -* ]]; then
    OPTIND=$((OPTIND + 1))
    OPTARG=$next_token
  else
    OPTARG=""
  fi
}

#Loop through options passed
while getopts :kK:b:l:zZ:i:c:h optname; do
  log "Option '$optname' set with argument '${OPTARG}'"
  case $optname in
    k)  #kafka version
      INSTALL_KAFKA=true
      getopts_optional_argument $@
      KAFKA_VERSION=${OPTARG}      
      ;;
    K)  #kafka source url
      KAFKA_SOURCE=${OPTARG}
      ;;
    b)  #broker id
      BROKER_ID=${OPTARG}
      ;;
    l)  #kafka listener
      KAFKA_LISTENER=${OPTARG}
      ;;
    z)  #zookeeper not kafka
      INSTALL_ZOOKEEPER=true
      getopts_optional_argument $@
      ZOOKEEPER_VERSION=${OPTARG}
      ;;
    Z)  #zookeeper source url
      ZOOKEEPER_SOURCE=${OPTARG}
      ;;
    i)  #zookeeper Private IP address prefix
      ZOOKEEPER_IP_PREFIX=${OPTARG}
      ;;
    c)  #number of instances
      INSTANCE_COUNT=${OPTARG}
      ;;
    h)  #show help
      help
      exit 2
      ;;
    \?) #unrecognized option - show help
      echo -e \\n"error: Option -${BOLD}$OPTARG${NORM} not allowed."
      help
      exit 3
      ;;
    :)  #missing argumet
      echo "error: Missing argument for option -$OPTARG" >&2;
      help 
      exit 4
      ;;
  esac
done

#Script Parameters
if [ "$INSTALL_ZOOKEEPER" == true ]; then
	  INSTALL_KAFKA=false
fi
if [ -z "$ZOOKEEPER_VERSION" ]; then
    ZOOKEEPER_VERSION="3.5.5"
fi
if [ -z "$ZOOKEEPER_SOURCE" ]; then
    ZOOKEEPER_SOURCE="http://mirrors.ukfast.co.uk/sites/ftp.apache.org/zookeeper/stable/"
fi
if [ -z "$ZOOKEEPER_IP_PREFIX" ]; then
    ZOOKEEPER_IP_PREFIX="10.0.0.4"
fi
ZOOKEEPER_PORT="2181"
SCALA_VERSION="2.12"
if [ -z "$KAFKA_VERSION" ]; then
    KAFKA_VERSION="2.3.0"
fi
if [ -z "$KAFKA_SOURCE" ]; then
    KAFKA_SOURCE="http://mirror.dkm.cz/apache/kafka/"
fi
if [ -z "$BROKER_ID" ]; then
    BROKER_ID=0
fi
if [ -z "$INSTANCE_COUNT" ]; then
    INSTANCE_COUNT=1
fi

# Install Java
install_java_failed=false
install_java()
{
    log "Installing Java"
    #add-apt-repository -y ppa:webupd8team/java
    #echo debconf shared/accepted-oracle-license-v1-1 select true | sudo debconf-set-selections
    #echo debconf shared/accepted-oracle-license-v1-1 seen true | sudo debconf-set-selections
    #apt-get -y install oracle-java8-installer
    # Installation of Oracle Java is not possible by 09/2019:
    # Oracle Java downloads now require logging in to an Oracle account to download Java updates, like the latest Oracle Java 8u211 / Java SE 8u212. Because of this I cannot update the PPA with the latest Java (and the old links were broken by Oracle).
    # For this reason, THIS PPA IS DISCONTINUED (unless I find some way around this limitation).
    # Oracle Java (JDK) Installer (automatically downloads and installs Oracle JDK8). There are no actual Java files in this PPA.
    apt -y update    
    if [ $? != 0 ]; then 
      >&2 echo "error: Unable to update packages."
      # Do not exit now to continue with installation, Java can be installed later.
      install_java_failed=true
    fi
    apt -y install openjdk-8-jdk
    if [ $? != 0 ]; then 
      >&2 echo "error: Java installation failed."
      install_java_failed=true
    fi
    export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
    echo "export JAVA_HOME=${JAVA_HOME}" >> /etc/profile
    java -version
    if [ $? != 0 ]; then 
      >&2 echo "error: Java is NOT installed."
      install_java_failed=true
    fi
}

# Expand a list of successive IP range defined by a starting address prefix (e.g. 10.0.0.1) and the number of machines in the range
# 10.0.0.1-3 would be converted to "10.0.0.10 10.0.0.11 10.0.0.12"

zookeeper="apache-zookeeper-${ZOOKEEPER_VERSION}-bin"
zookeeper_config="${zookeeper}/conf/zoo.cfg"

expand_ip_range_for_server_properties() {
    IFS='-' read -a HOST_IPS <<< "$1"
    for (( n=0 ; n<("${HOST_IPS[1]}"+0) ; n++))
    do
        echo "server.$(expr ${n} + 1)=${HOST_IPS[0]}${n}:2888:3888" >> $zookeeper_config
    done
}

function join_params { local IFS="$1"; shift; echo "$*"; }

expand_ip_range() {
    IFS='-' read -a HOST_IPS <<< "$1"

    declare -a EXPAND_STATICIP_RANGE_RESULTS=()

    for (( n=0 ; n<("${HOST_IPS[1]}"+0) ; n++))
    do
        HOST="${HOST_IPS[0]}${n}:${ZOOKEEPER_PORT}"
                EXPAND_STATICIP_RANGE_RESULTS+=($HOST)
    done

    echo "${EXPAND_STATICIP_RANGE_RESULTS[@]}"
}

# Install Zookeeper - can expose zookeeper version
install_zookeeper()
{
	mkdir -p /var/lib/zookeeper
	cd /var/lib/zookeeper
	zookeeper_package="${zookeeper}.tar.gz"
	zookeeper_url="${ZOOKEEPER_SOURCE}$zookeeper_package"
	wget $zookeeper_url
	tar -xvf $zookeeper_package

	if [[ ! -d "$zookeeper" ]]; then	  
		log "Directory '$zookeeper' not found."
		echo "error: Unable to find installation '$zookeeper', maybe something is wrong with source file '$zookeeper_url'." >&2
		exit 5
	fi
	touch $zookeeper_config

	echo "tickTime=2000" >> $zookeeper_config
	echo "dataDir=/var/lib/zookeeper" >> $zookeeper_config
	echo "clientPort=$ZOOKEEPER_PORT" >> $zookeeper_config
	echo "initLimit=5" >> $zookeeper_config
	echo "syncLimit=2" >> $zookeeper_config
	# OLD Test echo "server.1=${ZOOKEEPER_IP_PREFIX}:2888:3888" >> $zookeeper_config
	$(expand_ip_range_for_server_properties "${ZOOKEEPER_IP_PREFIX}-${INSTANCE_COUNT}")

	echo $(($1+1)) >> /var/lib/zookeeper/myid

	${zookeeper}/bin/zkServer.sh start
}

# Install kafka
install_kafka()
{
	cd /usr/local
	name=kafka
	version=${KAFKA_VERSION}
	description="Apache Kafka is a distributed publish-subscribe messaging system."
	url="https://kafka.apache.org/"
	arch="all"
	section="misc"
	license="Apache Software License 2.0"
	package_version="-1"
	kafka="kafka_${SCALA_VERSION}-${KAFKA_VERSION}"
	kafka_package="${kafka}.tgz"
	kafka_url="${KAFKA_SOURCE}${KAFKA_VERSION}/${kafka_package}"

	rm -rf kafka
	mkdir -p kafka
	cd kafka
	kafka_path="$(pwd)/$kafka"
	#_ MAIN _#
	if [[ ! -f "${kafka_package}" ]]; then
	  log "Get $kafka_url"
	  wget $kafka_url
	fi
	tar zxf $kafka_package
	if [[ ! -d "$kafka_path" ]]; then	  
		log "Directory '$kafka_path' not found."
		echo "error: Unable to find installation '$kafka_path', maybe something is wrong with source file '$kafka_url'." >&2
		exit 6
	fi
	cd $kafka_path
	
	sed -E -i "s/(broker.id)=(.*)/\1=${BROKER_ID}/g" config/server.properties 
	sed -E -i "s/(zookeeper.connect)=(.*)/\1=$(join_params , $(expand_ip_range "${ZOOKEEPER_IP_PREFIX}-${INSTANCE_COUNT}"))/g" config/server.properties
  if [ ! -z "$KAFKA_LISTENER" ]; then
    sed -E -i "s/^#?(advertised.listeners)=(.*)(:[0-9]+)/\1=PLAINTEXT:\/\/${KAFKA_LISTENER}\3/g" config/server.properties
  fi

	chmod u+x $kafka_path/bin/kafka-server-start.sh
	$kafka_path/bin/kafka-server-start.sh $kafka_path/config/server.properties &
}

# Primary Install Tasks
#########################
#NOTE: These first three could be changed to run in parallel
#      Future enhancement - (export the functions and use background/wait to run in parallel)

#Install Oracle Java
#------------------------
install_java

if [ "$INSTALL_ZOOKEEPER" == true ]; then
	#
	#Install zookeeper
	#-----------------------
	install_zookeeper
fi
if [ "$INSTALL_KAFKA" == true ]; then
	#
	#Install kafka
	#-----------------------
	install_kafka
fi

if [ "$install_java_failed" == true ]; then
  echo "Install Java manually and then run service daemon: sudo apt -y update; sudo apt -y install openjdk-8-jdk" >&2
  exit 10
fi
