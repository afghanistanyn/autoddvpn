#!/bin/sh

# file lock to avoid other rc_firewall running at the same time
LOCK='/tmp/rc_fw_done'

#if [ -e $LOCK ]; then
#	echo "[DEBUG] other rc_firewall may already be running, quit" >> $VPNLOG
#	exit 1
#else
#	touch $LOCK
#fi

VPNUP='vpnup.sh'
VPNDOWN='vpndown.sh'
VPNLOG='/tmp/autoddvpn.log'
PPTPSRVSUB=$(nvram get pptpd_client_srvsub)
DLDIR='http://autoddvpn.googlecode.com/svn/trunk/'
CRONJOBS="* * * * * root /bin/sh /tmp/check.sh >> /tmp/last_check.log"
PID=$$
INFO="[INFO#${PID}]"
DEBUG="[DEBUG#${PID}]"


#
# By running this script, we'll assign the following variables into nvram 
#
# pptpd_client_dev : the device name of pptp client, eg. ppp0 ppp1 ...
# pptp_gw : the gateway IP of the PPTP VPN
#

#ping -W 3 -c 1 $VPNIP > /dev/null 2>&1 

echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") log starts" >> $VPNLOG
tokillcnt=0
while true
do
	if [ $PPTPSRVSUB != '' ]; then
		# pptp is up
		PPTPDEV=$(route | grep ^$PPTPSRVSUB | awk '{print $NF}')
		if [ $PPTPDEV != '' ]; then
			echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") got PPTPDEV as $PPTPDEV, set into nvram" >> $VPNLOG
			nvram set pptpd_client_dev="$PPTPDEV"
		else
			# check concurrent number of pptp client process to fix bug #6 
			# see: http://code.google.com/p/autoddvpn/issues/detail?id=6
			PPTPCCNT=$(ps | grep pptp | grep -c file)
			if [ $PPTPCCNT -gt 1  ]; then
				if [ $tokillcnt -le 4 ]; then
					tokillcnt=$((tokillcnt+1))
					echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") got concurrent $PPTPCCNT running clients, just leave them alone :-) $tokillcnt/5" >> $VPNLOG
				else
					echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") got concurrent $PPTPCCNT running clients, fixing it." >> $VPNLOG
					kill $(ps | grep pptp | grep file  | awk '{print $1}' | tail -n1)
					tokillcnt=0
				fi
			fi
			echo "$DEBUG $(date "+%d/%b/%Y:%H:%M:%S") failed to get PPTPDEV, retry in 10 seconds" >> $VPNLOG
			sleep 10
			continue
		fi

		# find the PPTP gw
		while true
		do
			PPTPGW=$(ifconfig $PPTPDEV | grep -Eo "P-t-P:([0-9.]+)" | cut -d: -f2)
			if [ $PPTPGW != '' ]; then
				echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") got PPTPGW as $PPTPGW, set into nvram" >> $VPNLOG
				nvram set pptp_gw="$PPTPGW"
				break
			else
				echo "$DEBUG $(date "+%d/%b/%Y:%H:%M:%S") failed to get PPTPGW, retry in 3 seconds" >> $VPNLOG
				sleep 3
				continue
				# let it fall into endless loop if we still can't find the PPTP gw
			fi
		done
		
		# now we hve the PPTPGW, let's modify the routing table
		echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") VPN is UP, trying to modify the routing table" >> $VPNLOG
		cd /tmp; 
		/usr/bin/wget $DLDIR$VPNDOWN
		rm -f $VPNUP
		#( /usr/bin/wget $DLDIR$VPNUP -O - | /bin/sh  2>&1 ) >> $VPNLOG
		( /usr/bin/wget $DLDIR$VPNUP && /bin/sh $VPNUP 2>&1 ) >> $VPNLOG
		rt=$?
		echo "$DEBUG $(date "+%d/%b/%Y:%H:%M:%S") return $rt" >> $VPNLOG
		if [ $rt -eq 0 ]; then 
			# prepare for the exceptional routes, see http://code.google.com/p/autoddvpn/issues/detail?id=7
			echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") preparing the exceptional routes" >> $VPNLOG
			if [ $(nvram get exroute_enable) -eq 1 ]; then
				echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") modifying the exceptional routes" >> $VPNLOG
				for i in $(nvram get exroute_list)
				do
					echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") fetching exceptional routes for $i"  >> $VPNLOG
					wget http://autoddvpn.googlecode.com/svn/trunk/exroute.d/$i -O /tmp/$i && \
					for r in $(grep -v ^# /tmp/$i)
					do
						echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") adding $r via wan_gateway"  >> $VPNLOG
						# check the item is a subnet or a single ip address
						echo $r | grep "/" > /dev/null
						if [ $? -eq 0 ]; then
							route add -net $r gw $(nvram get wan_gateway) 
						else
							route add $r gw $(nvram get wan_gateway) 
						fi
					done 
				done
				route | grep ^default | awk '{print $2}' >> $VPNLOG
				# for custom list of exceptional routes
				echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") modifying custom exceptional routes if available" >> $VPNLOG
				for i in $(nvram get exroute_custom)
				do
					echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") adding custom host/subnet $i via wan_gateway"  >> $VPNLOG
					# check the item is a subnet or a single ip address
					echo $i | grep "/" > /dev/null
					if [ $? -eq 0 ]; then
						route add -net $i gw $(nvram get wan_gateway) 
					else
						route add $i gw $(nvram get wan_gateway) 
					fi
				done
			else
				echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") exceptional routes disabled."  >> $VPNLOG
				echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") exceptional routes features detail:  http://goo.gl/fYfJ"  >> $VPNLOG
			fi
	
			# prepare the self-fix script
			route | grep ^default | awk '{print $2}' >> $VPNLOG
			echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") preparing the self-fix script at /tmp/check.sh" >> $VPNLOG
			/usr/bin/wget "${DLDIR}/cron/check.sh"

			#echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") preparing the cron_job" >> $VPNLOG
			#mkdir /tmp/cron.d/
			#nvram set cron_jobs="${CRONJOBS}"
			#nvram get cron_jobs > /tmp/cron.d/cron_jobs
			#nvram set cron_enable=1
			#pidof cron || \
			#echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") cron not running, starting the cron ..." && cron

			echo "$DEBUG $(date "+%d/%b/%Y:%H:%M:%S") ALL DONE!" >> $VPNLOG
			break; 
		fi
	else
		echo "$INFO $(date "+%d/%b/%Y:%H:%M:%S") VPN is down, please bring up the PPTP VPN first." >> $VPNLOG
		sleep 10
	fi
done

rm -f $LOCK
