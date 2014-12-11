#!/bin/sh

TIME_TO_DELETE=10
MAILS_TO_ALARM=30
MAILS_TO_DISABLE=1000

#LOCAL_DOMAIN=testdomain.com
SEND_ALARM_TO=test@test.ru

WORK_DIR=/etc/quewatcher
WHITELIST_FILE=$WORK_DIR/whitelist

RUN_DIR=/var/run/quewatcher
PID_FILE=/var/run/quewatcher/quewatcher.pid

MAIL_LOG=/var/log/maillog

LOG=/var/log/quewatcher
DEBUG=0
MAX_QUEUE_SIZE=100

writeToLog()
{
	process=$1	
	if [ $DEBUG -ne 1 ]; then 
		if [ "$process" == "debug" ]; then
			return 0
		fi
	fi
	shift
	echo "$( date +'%b %d %T' ) quewatcher[$BASHPID]: $process: $*"
}

writeToArray()
{
	writeToLog "debug" "writetoarray: enter: $1 $2"
	if [ -z ${base[$1]} ]; then
		base[$1]=$2
		writeToLog "debug" "writetoarray: insert new item: base[$1]=$2"
	else		
		delta=$2
		oldValue=${base[$1]}
		writeToLog "debug" "writetoarray: update item base[$1]=${base[$1]} delta=$delta"
		base[$1]=$(( oldValue + delta ))
		writeToLog "debug" "writetoarray: update item base[$1], newvalue=${base[$1]}"
		if [ ${base[$1]} -le 0 ]; then
			writeToLog "debug" "writetoarray: unset base[$1]"
			unset base[$1]	
		fi		
	fi
	writeToLog "debug" "writetoarray: exit"
}

addToQueue()
{
	writeToLog "debug" "addToQueue: start: $1"
	if [ "${#queue[*]}" == "$MAX_QUEUE_SIZE" ]; then
		writeToLog "queue" "overflow items=${#queue[*]} max=$MAX_QUEUE_SIZE t=$topindex b=$botindex"
		exit 2
	fi
	writeToLog "debug" "queue[$topindex]=$1"
	queue[$topindex]=$1
	(( topindex++ ))
	if [ "$topindex" == "$(( MAX_QUEUE_SIZE ))" ]; then
		if [ "${queue[0]}" == "" ]; then
			topindex=0
		else
			writeToLog "queue" "overflow items=${#queue[*]} max=$MAX_QUEUE_SIZE t=$topindex b=$botindex queue[0]=${queue[0]}"
			stop
			exit 2
		fi
	fi	
	writeToLog "debug" "addToQueue: exit"
}

removeFromQueue()
{
	writeToLog "debug" "removeFromQueue: start"	
	unset queue[$botindex]
	(( botindex++ ))
	if [ "$botindex" == "$(( MAX_QUEUE_SIZE ))" ]; then
		botindex=0
	fi
}

clearBase()
{
	writeToLog "debug" "clearbase: enter"
	timenow=$( date +%s )
	allok=${#queue[*]}
	curitem=$botindex
	while [ "$allok" -gt 0 ]
	do	
		toParse=( ${queue[$botindex]} )
		writeToLog "debug" "clearbase: queue item: |${queue[$botindex]}| index=$botindex"
		timetodelete=${toParse[2]}
		writeToLog "debug" "clearbase: ttd=$timetodelete timenow=$timenow"
		if [ "$timenow" -ge "$timetodelete"  ]; then
			writeToLog "debug" "clearbase: writeToArray: ${queue[$botindex]}"
			writeToArray ${queue[$botindex]}
			writeToLog "debug" "clearbase: unset queue[$botindex]=${queue[$botindex]}"
			removeFromQueue
			writeToLog "debug" "clearbase: array have ${#queue[*]} items"
			allok=${#queue[*]}
		else
			allok=0
		fi			
	done
	writeToLog "debug" "clearbase: exit"
}

checker()
{
	writeToLog "debug" "checker: start"
	for addr in "${!base[@]}"
	do
		val=${base[$addr]}
		writeToLog "debug" "checker: $addr sent $val messages"
		if [ $val -gt $MAILS_TO_ALARM ]; then
			writeToLog "debug" "checker: ALARM: $addr was sent $val messages for last $TIME_TO_DELETE seconds"
			if [[ "$( echo "$currentignore"|grep -iw $addr )" == "" ]]; then
				writeToLog "checker" "SEND ALARM: $addr was sent $val messages for last $TIME_TO_DELETE seconds"
				echo "ALARM: $addr was sent $val messages for last $TIME_TO_DELETE seconds" | mail -s "MCORE: ALERT! Many outgoing e-mails" $SEND_ALARM_TO				
				currentignore+=$( echo -e "\n$addr\n" )
				writeToLog "debug" "checker: send alarm. currentignore=$currentignore"			
			else
				writeToLog "debug" "checker: current ignore"
			fi			
		else
			if [[ "$( echo "$currentignore"|grep -iw $addr )" != "" ]]; then				
				currentignore=$(echo "$currentignore" | grep -vw $addr)		
				writeToLog "debug" "checker: delete $addr from ignore, currentignore=$currentignore"				
			fi
		fi
	done
	writeToLog "debug" "checker: exit"
}

start()
{
	echo "Starting quewatcher";
	if ! [ -d $RUN_DIR ]; then
		mkdir $RUN_DIR	
		if [ $? -ne 0 ]; then
			echo "Cant create working directory: $RUN_DIR"
			exit 2
		fi
	fi
	if [ -e $PID_FILE ]; then
		pid=$( cat "$PID_FILE" )
		if [ -e /proc/$pid ]; then
			echo "Daemon already running with pid = $pid"
			exit 1
		else
			echo "Daemon not running, but pid file is exist: $pid"
			exit 2
		fi
	fi
	if ! [ -e $MAIL_LOG ]; then
		echo "Cant find maillog: $MAIL_LOG"
		exit 2
	fi
	if ! [ -e $LOG ]; then
		touch $LOG
	fi
	if [ -e $WHITELIST_FILE ]; then
		whitelist=$( cat $WHITELIST_FILE )
	fi
	regexdomain=$( echo $LOCAL_DOMAIN|replace '.' '\.' )
	declare -A base
	declare -A queue	
	topindex=0
	botindex=0
	currentignore=""
    cd /
	exec >> $LOG
	exec < /dev/null
	writeToLog "init" "Ok, lets begin."
	(
		trap  "{ rm -f $PID_FILE; exit 255; }" TERM INT EXIT
		writeToLog "master" "Start with pid: $BASHPID"
		tail -f $MAIL_LOG|while read line
		do		
			if [[ "$( echo $line|grep -ie 'from=<.*@sstu\.ru>.*nrcpt=.*' )" != "" ]]; then
				address=$( echo $line | grep -io '<.*>' )
				if [[ "$( echo $whitelist|grep -io "$address")" != "" ]]; then
					writeToLog "debug" "master: whitelisted: $address $nrcptVal"
				else
					clearBase
					nrcptVal=$( echo $line | replace '=' ' ' | cut -d ' ' -f 12 )
					writeToLog "master" "$address $nrcptVal"
					writeToArray $address $nrcptVal
					writeToLog "debug" "master: add item to queue: |$address $(( 0 - $nrcptVal )) $(( $( date +%s ) + $TIME_TO_DELETE ))|"
					addToQueue "$address $(( 0 - $nrcptVal )) $(( $( date +%s ) + $TIME_TO_DELETE ))"
					checker
					fi
			fi		
			#sleep 1
		done
		exit 0
	)&
	writeToLog "debug" "init exit"
	echo $! > $PID_FILE
}

stop()
{
	if [ -e $PID_FILE ]; then
		currentPid=$( cat $PID_FILE )
		echo "Stopping quewatcher (pid: $currentPid)";
		pkill -TERM -P $currentPid
		rm -f $PID_FILE > /dev/null
	else
		echo "quewatcher not running";
	fi	
}

case "$1" in
	'start')
		start
		;;
		
	'stop')
		stop
		;;

	*)
		echo "Usage: $0 { start | stop }"
		exit 1
		;;
esac
exit 0
