#!/usr/bin/env bash

# check color support
colors=$(tput colors)
if (($colors >= 8)); then
    red='\033[0;31m'
    green='\033[0;32m'
    blue='\033[0;34m'
    nocolor='\033[00m'
else
  red=
  green=
  blue=
  nocolor=
fi

# OS Types
OSX="Darwin"
Linux="Linux"

# tools
DIG_PATH="dig"
SSHPASS_PATH="sshpass"
AIRPORT_PATH="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
RSYNC_PATH="rsync"
FSWATCH_PATH="fswatch"
INOTIFYWAIT_PATH="inotifywait"

# dependency check
dependencies=()
if ! type $SSHPASS_PATH  >/dev/null; then dependencies+=($SSHPASS_PATH); fi
if ! type $RSYNC_PATH    >/dev/null; then dependencies+=($RSYNC_PATH); fi
if [[ $(uname) == $OSX ]]; then if ! type $AIRPORT_PATH >/dev/null; then dependencies+=($AIRPORT_PATH); fi; fi
if [[ $(uname) == $OSX ]]; then if ! type $FSWATCH_PATH     >/dev/null; then dependencies+=($FSWATCH_PATH); fi; fi
if [[ $(uname) == $Linux ]]; then if ! type $INOTIFYWAIT_PATH >/dev/null; then dependencies+=($INOTIFYWAIT_PATH); fi; fi

if [[ ${#dependencies[@]} != 0 ]]; then
	echo "You need to install the following tools before running the script:"
	for dep in ${dependencies[@]}; do
		echo -e "$red $dep $nocolor"
	done
	return 1;
fi

CURRENT_FILENAME="$(basename $BASH_SOURCE)"
LATENCY="3"

# source / destination paths
LOCAL_PATH="."
TARGET_PATH="/usr/local/changeme_app"

# credentials
TARGET_SSH_USER="changeme"
TARGET_SSH_PASSWORD="changeme"

# list of active IP addresses
IPs=(`arp -a | awk '$4 != "(incomplete)"' | awk '{print $2}' | sed 's/[()]//g'`)

for IP in ${IPs[@]}; do
	ping -c 1 IP &>/dev/null
done

# get network SSID for OSX
SSID="${AIRPORT_PATH} -I | awk -F': ' '/ SSID/ {print $2}'"

# Reverse DNS Lookup to get hostnames of specified active IP addresses
count=0
HOSTNAMES=()
for IP in ${IPs[@]}; do
	HOSTNAME=`${DIG_PATH} +time=0 +tries=0 +retry=0 +short -x $IP @224.0.0.251 -p 5353 | sed 's/.$//'`
	if [[ $HOSTNAME != *"connection timed out"* && $HOSTNAME != $(hostname) ]]; then
			(( count++ ))
			HOSTNAMES+=($HOSTNAME)
			echo -e "${red}" $count")${nocolor}" $HOSTNAME
	fi
done

if [[ ${#HOSTNAMES[@]} = 0 ]]; then
	echo -e "${red}No device available on the network! $nocolor"
	return 1;
fi

# provide selected machine's credentials
unset TARGET
response="ssh status"
while [[ $response != "" ]]; do
	unset number
	while [[ ! $number =~ ^[0-9]+$ ]]; do
		echo "select a valid number from the list above"
		read -p "choose hostname: " number
	done
	TARGET=${HOSTNAMES[ $number - 1 ]}

	if [[ $TARGET != *"change_machine_name"* ]]; then
		read -p "username: " TARGET_SSH_USER
		read -sp "password: " TARGET_SSH_PASSWORD
		echo ""
	fi

	CHOWN="sudo chown -R ${TARGET_SSH_USER}:${TARGET_SSH_USER} $TARGET_PATH &"
	response=`${SSHPASS_PATH} -p "${TARGET_SSH_PASSWORD}" ssh -T $TARGET_SSH_USER@$TARGET ${CHOWN} exit 2>&1 >/dev/null`
	echo -e ${red}$response${nocolor}
done

echo ""
echo -e "target hostname chosen is $blue $TARGET $nocolor"
echo ""

# perform initial complete sync
read -n1 -r -p "Press any key to continue (or abort with Ctrl-C)... " key
echo ""
echo -n "Synchronizing... "

${RSYNC_PATH} -avzr --delete --force \
			  --exclude=".*" \
			  --exclude="$CURRENT_FILENAME" \
			  --rsh="${SSHPASS_PATH} -p \"${TARGET_SSH_PASSWORD}\" ssh -l $TARGET_SSH_USER" \
			  $LOCAL_PATH $TARGET:$TARGET_PATH
echo "done."
echo ""

# watch for changes and sync
echo "Watching for changes. Quit anytime with Ctrl-C."

if [[ $(uname) == $OSX ]]; then
	${FSWATCH_PATH} -0 -r -l $LATENCY -Ee '(.*.sw|git|idea)' $LOCAL_PATH \
	| while read -d "" event; do
	    echo -en "${red}" `date` "${nocolor}\"$event\" changed. Synchronizing... "

	    ${RSYNC_PATH} -avzr --delete --force \
			          --exclude=".*" \
			          --exclude="$CURRENT_FILENAME" \
			          --rsh="${SSHPASS_PATH} -p \"${TARGET_SSH_PASSWORD}\" ssh -l $TARGET_SSH_USER" \
			          $LOCAL_PATH $TARGET:$TARGET_PATH
	  done
elif [[ $(uname) == $Linux ]]; then
	${INOTIFYWAIT_PATH} -rm -qe modify --exclude '(.*.sw|git|idea)' --format "%w%f" $LOCAL_PATH \
	| while read FILE; do
		${RSYNC_PATH} -avzr --delete --force \
			          --exclude=".*" \
			          --exclude="$CURRENT_FILENAME" \
			          --rsh="${SSHPASS_PATH} -p \"${TARGET_SSH_PASSWORD}\" ssh -l $TARGET_SSH_USER" \
			          $FILE ${TARGET}:${TARGET_PATH}${FILE}
	done
fi
