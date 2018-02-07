#! /bin/ksh
#
# Name: check_queues
#
# Purpose:
#  This script manages the config of a VIO server
#
# Change History:
#
# Date          Name    Version         Comments
#------------------------------------------------------------------------
# 31 mar 2010   ander   01.00.00        new
# 15 apr 2010	ander	01.00.00		ww_name recognition for not pvid disks.
# 17 apr 2017	ander	02.00.00		NPIV added
# 06 FEB 2018	ander	02.05.00		Script rebuild (output text & tmp files)
# 06 FEB 2018 	ander	02.05.02		NPIV fixed. Other minor fixes.

SCRIPT_VERSION="02.05.02" # Script version

DATE=`date +"%Y-%m-%d"`

HOSTNAME=`hostname`

#DEBUG_MODE=1
DEBUG_MODE=0

BASEDIR="/usr/local/VIOclone/$HOSTNAME/$DATE"
if [ ! -e "$BASEDIR" ]
then
	mkdir -p "$BASEDIR"
fi

NETMASTERCONFIGFILE="$BASEDIR/VIOclone.$HOSTNAME.NET.masterconfig"
NETCOMMANDLIST="$BASEDIR/VIOclone.$HOSTNAME.NET.commandlist"

DISKSLIST="$BASEDIR/VIOcloneconfig.$HOSTNAME.diskslist"
INITIALCONFIGFILE="$BASEDIR/VIOcloneconfig.$HOSTNAME.lsmap-all"

SANMASTERCONFIGFILE="$BASEDIR/VIOclone.$HOSTNAME.vSCSI.masterconfig"
NPIVMASTERCONFIGFILE="$BASEDIR/VIOclone.$HOSTNAME.NPIV.masterconfig"
COMMANDLIST="$BASEDIR/VIOclone.$HOSTNAME.vSCSI.commandlist"
NPIVCOMMANDLIST="$BASEDIR/VIOclone.$HOSTNAME.NPIV.commandlist"

log() { # Display something
        # echo `date +"%Y-%m-%d_%H:%M"` $$ "$1" |tee -a $LOG_FILE
		logger "$1"
		echo "$1"
}

logd() { # Display something if DEBUG is activated
        if [ "$DEBUG_MODE" = "1" ]; then log "$1"; fi
}

getdisksconfig() {
	log "INFO: Initializing disks status"
	
	if [ -e "$DISKSLIST" ]; then rm -fr "$DISKSLIST"; fi
	
	lspv > $BASEDIR/lspv.list
	while read LINE
	do
		PVNAME=`echo $LINE| awk '{print $1;}'`
		SANLINE=`lsattr -El $PVNAME -a unique_id 2>/dev/null`
 		SANWWN=`echo $SANLINE| awk '{print $2;}'`
		if [ "$SANWWN" != "" ]
		then
			echo "$PVNAME $SANWWN" >> $DISKSLIST
		else
			logd "ERROR: Disk $PVNAME has not unique_id. Either no PVID or local disk."
		fi
	done < $BASEDIR/lspv.list
}

buildSANmasterconfig() {

	log "INFO: Processing SAN disks config"
	
	# We get and create the configuration of the running VIO server.
	/usr/ios/cli/ioscli lsmap -all > $INITIALCONFIGFILE
	
	log "INFO: Processing disks config"
	
	if [ -e "$SANMASTERCONFIGFILE" ]; then rm -fr "$SANMASTERCONFIGFILE"; fi
	
	VHOST=""
	NEWVHOST=""
	VTD=""
	NEWVTD=""
	BDEV=""
	NEWBDEV=""
	LPARID=""
	LINESANWWN=""
	
	while read LINE
	do
		NEWVHOST=`echo $LINE|grep vhost`
		if [ "$NEWVHOST" != "" ]
		then
			VHOST=`echo $NEWVHOST| awk '{print $1;}'`
			LPARIDHEX=`echo $NEWVHOST| awk '{print $3;}'|sed 's/0x//g'| tr '[a-z]' '[A-Z]'`
			LPARID=`echo "ibase=16; $LPARIDHEX"|bc`
			logd "INFO: Reading config for LPAR #$LPARID."
		fi
		NEWVTD=`echo $LINE|grep VTD`
		if [ "$NEWVTD" != "" ]
		then
			VTD=`echo $NEWVTD| awk '{print $2;}'`
		fi
		NEWBDEV=`echo $LINE|grep "Backing device"`
		if [ "$NEWBDEV" != "" ]
		then
			BDEV=`echo $NEWBDEV| awk '{print $3;}'`
			#LINESANWWN=`cat $DISKSLIST|grep $BDEV`
			if [ "$BDEV" != "" ]; then LINESANWWN=`cat $DISKSLIST|grep "$BDEV"`; fi
			SANWWN=`echo $LINESANWWN| awk '{print $2;}'`
			if [ "$SANWWN" = "" ]; then SANWWN="NONE"; fi
			echo "$LPARID $VHOST $BDEV $SANWWN $VTD " >> $SANMASTERCONFIGFILE
		fi
	done < $INITIALCONFIGFILE
	log "INFO: vSCSI (STORAGE) master config file --> [$SANMASTERCONFIGFILE]."
	
	# Collect NPIV information
	# - Collect HBA physical adapters info
	/usr/ios/cli/ioscli lsdev -vpd | grep fcs > $NPIVMASTERCONFIGFILE.adapters
	# - Collect NPIV Virtual adapters info
	/usr/ios/cli/ioscli lsmap -all -npiv| grep -e vfchost -e "FC name"| sed 's/FC name:/ /g'| sed 's/FC loc code:/ /g'> /tmp/npiv.viad1.tmp

	# Clean de configuration file
	> /tmp/npiv.viad2.tmp
	while read LINE 
	do
		PARTITIONID=`echo $LINE| awk '{print $3;}'`
		VADAPTER=`echo $LINE| awk '{print $1;}'`
		VADAPTERLOCATION=`echo $LINE| awk '{print $2;}'`
		read LINE
		PHADAPTER=`echo $LINE| awk '{print $1;}'`
		PHADAPTERLOCATION=`echo $LINE| awk '{print $2;}'`

		echo "$PARTITIONID $VADAPTER $VADAPTERLOCATION $PHADAPTER $PHADAPTERLOCATION" >> /tmp/npiv.viad2.tmp

	done < /tmp/npiv.viad1.tmp
	sort /tmp/npiv.viad2.tmp > $NPIVMASTERCONFIGFILE
	log "INFO: NPIV (STORAGE) master config file  --> [$NPIVMASTERCONFIGFILE]."
}

getvhost4pid(){
	
	INPUT="$1"
	RETURN="NOTFOUND"
	while read LOCALLINE
	do
		LOCALLPARPIDHEX=`echo $LOCALLINE| awk '{print $3;}'|sed 's/0x//g'| tr '[a-z]' '[A-Z]'`
		LOCALLPARPID=`echo "ibase=16; $LOCALLPARPIDHEX"|bc`
		
		if [ "$LOCALLPARPID" = "$INPUT" ]
		then
			LOCALVHOST=`echo $LOCALLINE| awk '{print $1;}'`
			RETURN="$LOCALVHOST"
		fi
	done < "$LOCALVHOSTPID"	
	#logd "MASTERPID=$INPUT LOCALVHOST=$RETURN"
}
	
buildSANcommandLIST() {
	
	log  "INFO: Using $SANMASTERCONFIGFILE."
	
	# We create the vhost - PID correspondence local file
	
	LOCALVHOSTPID="$BASEDIR/VIOclone.localvhostpid.tmp"
	/usr/ios/cli/ioscli lsmap -all|grep vhost > "$LOCALVHOSTPID"
	
	
	if [ -e "$COMMANDLIST" ]; then rm -fr "$COMMANDLIST"; fi
	if [ -e "$COMMANDLIST.chdev" ]; then rm -fr "$COMMANDLIST.chdev"; fi
	if [ -e "$COMMANDLIST.mkvdev" ]; then rm -fr "$COMMANDLIST.mkvdev"; fi

	VHOST=""
	NEWVHOST=""
	VTD=""
	NEWVTD=""
	BDEV=""
	NEWBDEV=""
	
	logd "DEBUG: Local vhosts detected, now processing master file."
	
	if [ -z "$SANMASTERCONFIGFILE" ]
	then
		log "Master CONFIG file $SANMASTERCONFIGFILE does not exists, create it first. EXITING."
		log "************************************************************************************"
		exit 1
	fi
	
	while read LINE
	do
		LPARID=`echo $LINE| awk '{print $1;}'`
		VHOST=`echo $LINE| awk '{print $2;}'`
		BDEV=`echo $LINE| awk '{print $3;}'`
		SANWWN=`echo $LINE| awk '{print $4;}'`
		VTD=`echo $LINE| awk '{print $5;}'`
	
		BDEV=`cat "$DISKSLIST"|grep $SANWWN| awk '{print $1;}'`
		
		MINIDISK=`echo $BDEV|sed 's/hdisk/hd/'`
		MINIVHOST=`echo $VHOST|sed 's/vhost/vh/'`
		VTD=$MINIDISK$MINIVHOST"P"$LPARID
		
		getvhost4pid "$LPARID"
		if [ "$RETURN" = "NOTFOUND" ]
		then
			log "ERROR: local VHOST $VHOST not found for LPARID $LPARID."
			log "************************************************************************************"
			exit 2
			
		else
			VHOST="$RETURN"
		fi		
		
		if [ "$BDEV" != "" ]
		then
			
			echo "/usr/ios/cli/ioscli chdev -dev $BDEV -attr reserve_policy=no_reserve" >> $COMMANDLIST.chdev
			echo "/usr/ios/cli/ioscli mkvdev -vdev $BDEV -vadapter $VHOST -dev $VTD" >> $COMMANDLIST.mkvdev

		else
			logd "INFO: Line [$LINE] contains a defined but not available SAN disk."
		fi

	done < $SANMASTERCONFIGFILE
	
	cp $COMMANDLIST.chdev $COMMANDLIST
	cat $COMMANDLIST.mkvdev >> $COMMANDLIST
	
	log "INFO: The vSCSI COMMANDS file [ $COMMANDLIST ] has been created."
	
	# Restore de NPIV configuration ********************************************************************************************************
	
	log "INFO: Starting NPIV part."
	# - Get the current list of virtual server adaters
	/usr/ios/cli/ioscli lsmap -all -npiv| grep -e vfchost -e "FC name"| sed 's/FC name:/ /g'| sed 's/FC loc code:/ /g'> /tmp/npiv.viadlocal1.tmp
	# Clean de Command list file
	> $NPIVCOMMANDLIST
	# Clean de configuration file
	> /tmp/npiv.viadlocal2.tmp
	while read LINE 
	do
		PARTITIONID=`echo $LINE| awk '{print $3;}'`
		VADAPTER=`echo $LINE| awk '{print $1;}'`
		VADAPTERLOCATION=`echo $LINE| awk '{print $2;}'`
		read LINE
		PHADAPTER=`echo $LINE| awk '{print $1;}'`
		PHADAPTERLOCATION=`echo $LINE| awk '{print $2;}'`

		echo "$PARTITIONID $VADAPTER $VADAPTERLOCATION $PHADAPTER $PHADAPTERLOCATION" >> /tmp/npiv.viadlocal2.tmp

	done < /tmp/npiv.viadlocal1.tmp
	sort /tmp/npiv.viadlocal2.tmp > /tmp/npiv.viadlocal.tmp

	# - Check if there is the same number of adapters
	NUMLINESORIGIN=`wc -l $NPIVMASTERCONFIGFILE| awk '{print $1;}'`
	NUMLINESDESTINY=`wc -l /tmp/npiv.viadlocal.tmp| awk '{print $1;}'`
	if [ "$NUMLINESORIGIN" != "$NUMLINESDESTINY" ]
	then
		log "INFO: There is a different number of adapters in config file ($NUMLINESORIGIN) vs running config ($NUMLINESDESTINY)"
	else
		logd "INFO: Same number of Virtual server adapters in config and in local VIOS ($NUMLINESORIGIN)."
	
	    # Restore the vfcadapter to the right fcsx host
	    NLINE=1
	    while [[ $NLINE -le $NUMLINESORIGIN ]]
	    do
	            LINEORIG=`sed -n "$NLINE"p $NPIVMASTERCONFIGFILE`
	            LINEDEST=`sed -n "$NLINE"p /tmp/npiv.viadlocal.tmp`

	            PART_ID_ORIG=`echo $LINEORIG| awk '{print $1;}'`
	            VADAPTER_ORIG=`echo $LINEORIG| awk '{print $2;}'`
	            PHADAPTER_ORIG=`echo $LINEORIG| awk '{print $4;}'`

	            PART_ID_DEST=`echo $LINEDEST| awk '{print $1;}'`
	            VADAPTER_DEST=`echo $LINEDEST| awk '{print $2;}'`

	            if [ $PART_ID_ORIG == $PART_ID_DEST ]
	            then
	                    echo "/usr/ios/cli/ioscli vfcmap -vadapter $VADAPTER_DEST -fcp $PHADAPTER_ORIG" >> $NPIVCOMMANDLIST
	            else
	                    log "ERROR: There is a mismatch in the vadapters and/or LPARS ($PART_ID_ORIG) ($PART_ID_DEST)"
						log "************************************************************************************"
						exit
	            fi
	            let NLINE=NLINE+1
	    done
	fi
	
	log "INFO: The NPIV COMMANDS file [ $NPIVCOMMANDLIST ] has been created."
}

discover_stdint() {
		STDINT=$1
		logd "INFO[$2]: STANDARD Interface Detected $STDINT"
		# Treat Standard Interface
		lsattr -El $STDINT > $BASEDIR/standardint.$STDINT.config
		echo "STDINT interface $STDINT" >> $NETMASTERCONFIGFILE
		#echo $STDINT >> $NETMASTERCONFIGFILE
		while read LINESTDINT
		do 
		    ATTR=`echo $LINESTDINT| awk '{print $1;}'`
		    VALUE=`echo $LINESTDINT| awk '{print $2;}'`
		    echo "$STDINT $ATTR='$VALUE'" >> $NETMASTERCONFIGFILE
		done < $BASEDIR/standardint.$STDINT.config
		echo "END_STDINT interface $STDINT" >> $NETMASTERCONFIGFILE
}

discover_etherchannel() {
		ETHERCH=$1
		log "INFO[$2]: ETHERCHANNEL Detected $1"
		
		ADAPTERS_LIST="$BASEDIR/ETHERCHANNEL_adapters.list";
		rm -fr $ADAPTERS_LIST
		
		# Treat Etherchannel
		lsattr -El $ETHERCH > $BASEDIR/etherchannel.$ETHERCH.config
		echo "ETHERCHANNEL interface  $ETHERCH" >> $NETMASTERCONFIGFILE
		#echo $ETHERCH >> $NETMASTERCONFIGFILE
		while read LINEETHERCH
		do 
		    ATTR=`echo $LINEETHERCH| awk '{print $1;}'`
		    VALUE=`echo $LINEETHERCH| awk '{print $2;}'`
		    echo "$ETHERCH $ATTR='$VALUE'" >> $NETMASTERCONFIGFILE
	    
		    if [ "$ATTR" = "adapter_names" ]
		    then
		    	echo $VALUE >> $ADAPTERS_LIST
		    fi	   
		    if [ "$ATTR" = "backup_adapter" ]
		    then
		    	echo $VALUE >> $ADAPTERS_LIST
		    fi	   
		done < $BASEDIR/etherchannel.$ETHERCH.config
		echo "END_ETHERCHANNEL interface $1" >> $NETMASTERCONFIGFILE
		
		while read INTERFACE 
		do
			# logd "DEBUG: Treating single $INTERFACE"
			discover_stdint $INTERFACE $ETHERCH
		done < $ADAPTERS_LIST 
		
}

discover_interface() {
	INT=$1
	INTTYPE=`lsdev|grep $INT|grep EtherChannel`
	if [ "$INTTYPE" != "" ]
	then
		discover_etherchannel $INT $2
	else
		discover_stdint $INT $2
	fi
}

discover_tcpip_config() {
	TCPIPFILE=$HOSTNAME.tcpipconfig
	ifconfig -a > $TCPIPFILE
	INTERFACE=""
	FIRSTTEXT=""
	
	while read TCPIPLINE
	do
		INTERFACE=$FIRSTTEXT
		FIRSTTEXT=`echo $TCPIPLINE| awk '{print $1;}'|sed "s/[:]//g"`
		if [ "$FIRSTTEXT" = "inet" ]
		then
			echo "TCPIPCFG $INTERFACE $TCPIPLINE" >> $NETMASTERCONFIGFILE
		fi
	done < $TCPIPFILE
	}

get_net_config() {
	lsdev|grep ent|grep Available|grep Shared > $BASEDIR/sharedevs.list
	while read SHA_LINE
	do
		echo $SHA_LINE| awk '{print $1;}' >> $BASEDIR/sharedadapters.list
	done < $BASEDIR/sharedevs.list
	
	if [ -z $BASEDIR/sharedevs.list ]
	then
		log "INFO: Looks like there is no SEAs in this VIO server."
	else
		
		while read SEA
		do
			lsattr -El $SEA > $BASEDIR/SEAadapter.$SEA.config
			echo "SEA interface $SEA" >> $NETMASTERCONFIGFILE
			logd "INFO: SEA adapter found [$SEA] vlan [`lsattr -El $SEA|grep PVID |awk '{print $2;}'`]"
			while read LINE
			do 
			    ATTR=`echo $LINE| awk '{print $1;}'`
			    VALUE=`echo $LINE| awk '{print $2;}'`
			    echo "$SEA $ATTR='$VALUE'" >> $NETMASTERCONFIGFILE
			    
			    if [ "$ATTR" = "real_adapter" ]
			    then
			    	REAL_ADAPTER=$VALUE
			    	# logd "DEBUG: $VALUE"
			    fi	    
			    
			done < $BASEDIR/SEAadapter.$SEA.config
			echo "END_SEA interface $SEA" >> $NETMASTERCONFIGFILE
			discover_interface $REAL_ADAPTER $SEA
			
		done < $BASEDIR/sharedadapters.list
	fi
	
	discover_tcpip_config
	log "INFO: NETWORK master config file         --> [$NETMASTERCONFIGFILE]."
}

buildcommandlist() {

	# Check basic interfaces
	BASIC_INT_LIST="$BASEDIR/BASIC_interface.list"
	rm -fr "$BASIC_INT_LIST"
	# Find all basic interfaces in the configuration file
	log "INFO: Detecting standard interfaces in local machine..."
	cat $NETMASTERCONFIGFILE|grep -v "END_STDINT"|grep "STDINT interface"|sort -u > "$BASIC_INT_LIST.tmp"
	while read LINE
	do
		INTERFACE=`echo $LINE| awk '{print $3;}'`
		echo "$INTERFACE" >> "$BASIC_INT_LIST"
	done < "$BASIC_INT_LIST.tmp"
	
	# Check etherchannel interfaces
	ETHER_INT_LIST="$BASEDIR/ETHER_interface.list"	
	rm -fr "$ETHER_INT_LIST"
	# Find all etherchannel interfaces in the configuration file
	log "INFO: Detecting etherchannel interfaces in local machine..."
	cat $NETMASTERCONFIGFILE|grep ETHERCHANNEL|grep -v END|sort -u > "$ETHER_INT_LIST.tmp2"
	while read LINE
	do
		INTERFACE=`echo $LINE| awk '{print $3;}'`
		echo "$INTERFACE" >> "$ETHER_INT_LIST"
	done < "$ETHER_INT_LIST.tmp2"
	
	# Check SEA interfaces
	SEA_INT_LIST="$BASEDIR/SEA_interface.list"
	rm -fr "$SEA_INT_LIST"
	# Find all SEA interfaces in the configuration file
	log "INFO: Detecting SEA interfaces in local machine..."
	cat $NETMASTERCONFIGFILE|grep SEA|grep -v END|sort -u > "$SEA_INT_LIST.tmp3"
	while read LINE
	do
		INTERFACE=`echo $LINE| awk '{print $3;}'`
		echo "$INTERFACE" >> "$SEA_INT_LIST"
	done < "$SEA_INT_LIST.tmp3"
	
	# Check if they exist and are available
	if [ -e "$BASIC_INT_LIST" ]
	then
		while read LINE
		do
			ISOK=`lsdev|grep $LINE|grep Available`
			if [ "$ISOK" = "" ]
			then
				log "FATAL ERROR: The interface [$LINE] does not exist or is not available. Run: cfgmgr -l $LINE"
				log "************************************************************************************"
				exit 1
	        else
	            logd "DEBUG: OK for [$LINE]."
			fi
		done < "$BASIC_INT_LIST"	
		log "INFO: All basic interfaces detected OK."
	fi
	
	log "INFO: Creating commands to delete existing interfaces (ALL)"
	echo "#Delete all existing interfaces to avoid problems during the creation of the new interfaces" >> $NETCOMMANDLIST
	# Commands to delete the SEAs
	if [ -e "$SEA_INT_LIST" ]
	then
		echo "#Deleting SEAs" >> $NETCOMMANDLIST
		while read LINE
		do
			echo "rmdev -dl $LINE" >> $NETCOMMANDLIST
		done < "$SEA_INT_LIST"
	fi
	# Commands to delete the ETHERCHANNELS
	if [ -e "$ETHER_INT_LIST" ]
	then

		echo "#Deleting ETHERCHANNELS" >> $NETCOMMANDLIST
		while read LINE
		do
			echo "rmdev -dl $LINE" >> $NETCOMMANDLIST
		done < "$ETHER_INT_LIST"
	fi
	# Commands to delete the basic interfaces
	if [ -e "$BASIC_INT_LIST" ]
	then
		echo "#Recreating normal interfaces" >> $NETCOMMANDLIST
		while read LINE
		do
			echo "rmdev -dl $LINE" >> $NETCOMMANDLIST
			echo "cfgmgr -l $LINE" >> $NETCOMMANDLIST
		done < "$BASIC_INT_LIST"

		# If we are here all basic interfaces are OK so Treat basic interfaces
		log "INFO: Creating commands list to recreate the network configuration"
		log "INFO: Creating commands for standard interfaces."
		echo "#Preparation of standard interfaces" >> $NETCOMMANDLIST
		while read LINE
		do
		
			# Read options
			cat $NETMASTERCONFIGFILE|grep $LINE > $NETMASTERCONFIGFILE.$LINE
			ATTRIBUTES=""
			while read INTLINE
			do
				TEXT1=`echo $INTLINE| awk '{print $1;}'`
				TEXT2=`echo $INTLINE| awk '{print $2;}'`
				if [ "$LINE" = "$TEXT1" ]
				then
					ATTRIBUTES="$ATTRIBUTES -a $TEXT2"
				fi
			done < $NETMASTERCONFIGFILE.$LINE
			
			# Apply options chdev 
			echo "chdev -l $LINE $ATTRIBUTES" >> $NETCOMMANDLIST
			
		done < "$BASIC_INT_LIST"	

	fi

	if [ -e "$ETHER_INT_LIST" ]
	then
		# If we are here we treat etherchannel interfaces
		log "INFO: Creating commands for Etherchannels."
		echo "#Creation of Etherchannels" >> $NETCOMMANDLIST
		while read LINE
		do
			# Read options
			cat $NETMASTERCONFIGFILE|grep $LINE > $NETMASTERCONFIGFILE.$LINE
			ATTRIBUTES=""
						
			while read ETHLINE
			do
				TEXT1=`echo $ETHLINE| awk '{print $1;}'`
				TEXT2=`echo $ETHLINE| awk '{print $2;}'`
				if [ "$LINE" = "$TEXT1" ]
				then
					ATTRIBUTES="$ATTRIBUTES $TEXT2"
				fi
			done < $NETMASTERCONFIGFILE.$LINE
					
			# Apply options chdev 
			echo "mkdev -c adapter -s pseudo -t ibm_ech $ATTRIBUTES" >> $NETCOMMANDLIST
			
		done < "$ETHER_INT_LIST"		
	fi

	if [ -e "$SEA_INT_LIST" ]
	then	
		# Create the SEAs
		log "INFO: Creating commands for SEA interfaces."
		echo "#Creation of SEAs (check that the interface created as etherchannel interface is the one in the '-sea xxx' position)." >> $NETCOMMANDLIST
	
		while read LINE
		do	
			REALADAPTER=`cat $NETMASTERCONFIGFILE|grep $LINE|grep real_adapter=| 	awk '{print $2;}'| sed "s/[']//g"| sed "s/real_adapter=//g"`
			VADAPTER=`cat $NETMASTERCONFIGFILE|grep $LINE|grep virt_adapters=| 	awk '{print $2;}'| sed "s/[']//g"| sed "s/virt_adapters=//g"`
			PVIDADAPTER=`cat $NETMASTERCONFIGFILE|grep $LINE|grep pvid_adapter=| 	awk '{print $2;}'| sed "s/[']//g"| sed "s/pvid_adapter=//g"`
			PVID=`cat $NETMASTERCONFIGFILE|grep $LINE|grep pvid=| 				awk '{print $2;}'| sed "s/[']//g"| sed "s/pvid=//g"`
			HAMODE=`cat $NETMASTERCONFIGFILE|grep $LINE|grep ha_mode=| 			awk '{print $2;}'| sed "s/[']//g"| sed "s/ha_mode=//g"`
			CTLCHAN=`cat $NETMASTERCONFIGFILE|grep $LINE|grep ctl_chan=| 			awk '{print $2;}'| sed "s/[']//g"| sed "s/ctl_chan=//g"`
			
			# Apply options chdev 
			echo "/usr/ios/cli/ioscli mkvdev -sea $REALADAPTER -vadapter $VADAPTER -default $PVIDADAPTER -defaultid $PVID -attr ha_mode=$HAMODE ctl_chan=$CTLCHAN" >> $NETCOMMANDLIST
		done < "$SEA_INT_LIST"
	fi
	
	# Assign IP addresses
	log "INFO: Creating commands to reassign the IP Addresses."
	echo "#IP Addresses reassignement. PLEASE CHECK that the interfaces names have not changed (enxx)." >> $NETCOMMANDLIST
	
	cat $NETMASTERCONFIGFILE|grep TCPIPCFG > "$ETHER_INT_LIST.tmp4"
	while read LINE
	do
		IPADDRESS=`echo $LINE| awk '{print $4;}'`
		if [ "$IPADDRESS" != "127.0.0.1" ]
		then
			NETMASK=`echo $LINE| awk '{print $6;}'`
			INTERFACE=`echo $LINE| awk '{print $2;}'`
			HOSTNAME=`cat /etc/hosts|grep $IPADDRESS| awk '{print $2;}'`
			DNS=""
			DOMAIN=""
			GATEWAY=""
			ACTIVE="no"
			CABLETYPE="N/A"
			STARTNOW="yes"
			echo "/usr/sbin/mktcpip -h'$HOSTNAME' -a'$IPADDRESS' -m'$NETMASK' -i'$INTERFACE' -A'$ACTIVE' -t'$CABLETYPE' " >> $NETCOMMANDLIST
			#-n'$DNS' -d'$DOMAIN' -g'$GATEWAY' -s'$STARTNOW'
		fi
	done < "$ETHER_INT_LIST.tmp4"	
			
	log "INFO: The NET COMMANDS file [ $NETCOMMANDLIST ] has been created."
}

# Start the main process

#Detection of the Shared adapters
log "****** VIOclone running in $HOSTNAME @ `date` ****** v$SCRIPT_VERSION"

if [ "$1" = "-b" ]
then
	# SAN config
	getdisksconfig
	buildSANmasterconfig

	# Network config
	if [ -e "$NETMASTERCONFIGFILE" ]; then rm -fr $NETMASTERCONFIGFILE; fi
	if [ -e "$BASEDIR/sharedevs.list" ]; then rm -fr $BASEDIR/sharedevs.list; fi
	if [ -e "$BASEDIR/sharedadapters.list" ]; then rm -fr $BASEDIR/sharedadapters.list; fi
	get_net_config
elif [ "$1" = "-s" ]
then
	if [ "$2" != "" ]; then SANMASTERCONFIGFILE="$2"; fi
	getdisksconfig
	buildSANcommandLIST
elif [ "$1" = "-n" ]
then
	if [ -e "$NETCOMMANDLIST" ]; then rm -fr $NETCOMMANDLIST; fi
	if [ "$2" != "" ]; then NETMASTERCONFIGFILE="$2"; fi
	buildcommandlist
else
	log "VIOclone2                      # Shows this output."
	log "VIOclone2 -b                   # Builds the master config file on local filesystem."
	log "VIOclone2 -s [ SANMASTERfile ] # Creates a text file with the COMMANDS to replicate the STORAGE config located in the master file."
	log "VIOclone2 -n [ NETMASTERfile ] # Creates a text file with the COMMANDS to replicate the NETWORK config located in the master file."
	log "************************************************************************************"
	exit 0
fi
if [ "$DEBUG_MODE" = "0" ]
then
	if [ -e "$BASEDIR"/*.config ]; then rm "$BASEDIR"/*.config; fi
	if [ -e "$BASEDIR"/*.list ]; then rm "$BASEDIR"/*.list; fi
	if [ -e "$BASEDIR"/*.adapters ]; then rm "$BASEDIR"/*.adapters; fi
	if [ -e "$BASEDIR"/*.diskslist ]; then rm "$BASEDIR"/*.diskslist; fi
	if [ -e "$BASEDIR"/*.lsmap-all ]; then rm "$BASEDIR"/*.lsmap-all; fi
		
	if [ -e "$BASEDIR"/*.ent? ]; then rm "$BASEDIR"/*.ent?; fi
	if [ -e "$BASEDIR"/*.tmp ]; then rm "$BASEDIR"/*.tmp; fi
	if [ -e "$BASEDIR"/*.tmp? ]; then rm "$BASEDIR"/*.tmp?; fi
	if [ -e "$BASEDIR"/*.chdev ]; then rm "$BASEDIR"/*.chdev; fi
	if [ -e "$BASEDIR"/*.mkvdev ]; then rm "$BASEDIR"/*.mkvdev; fi
fi
log "************************************************************************************"


