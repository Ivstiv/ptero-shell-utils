#!/bin/sh
# Solution to this problem: https://github.com/pterodactyl/panel/issues/459
# Reference to iptables NAT tutorial: https://www.karlrupp.net/en/computer/nat_tutorial
# 
# Usage: bash public-ip-mapper.sh --remove <all|server_id>
# if you want to log the output: bash public-ip-mapper.sh 2>&1 | tee file.log

removeRule() {
	echo "Removing rules from -t nat POSTROUTING: $1"
	indexes=$(/sbin/iptables -t nat -nL POSTROUTING --line-number -w | grep $1 | awk '{print $1}' | tac)
	for rule in $indexes; do
		lastRule=$(/sbin/iptables -t nat -S POSTROUTING $rule -w)
		/sbin/iptables -t nat -D POSTROUTING $rule -w
		echo "Removed rule:$lastRule"
	done
	[[ -z $indexes ]] && echo "Couldn't find any references."
}

if [[ $1 == "--remove" ]]; then
	# quick validation
	[[ -z $2 ]] && echo -e "Specify a server id or \"all\"" && exit
	
	if [[ $2 == "all" ]]; then
		removeRule ip-mapper
	else
		removeRule $2
	fi
	echo "Finished."
	exit
fi

echo Listening for docker events... 
docker events --filter type=container --format '{{.Status}} {{.Actor.Attributes.name}}' | while read event

do
	status=$(echo $event | awk '{print $1}')
	if [[ $status == 'start' ]]; then
		server_id=$(echo $event | awk '{print $2}')
		local_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $server_id)
		public_ip=$(docker exec $server_id printenv SERVER_IP)
		
		echo "========================================="
		echo $(date)
		echo -e "Status=$status\nServer_ID=$server_id\nLocal_IP=$local_ip\nPublic_IP=$public_ip"
		echo "Action: Adding to NAT"
		# sometimes docker is still holding the lock of xtables, so we use -w
		# remove old rules with this comment just in case
		removeRule $server_id
		echo "Proceeding with the new rule..."
		
		if [[ -z $public_ip ]]; then
			echo "Missing environmental variable: SERVER_IP"
			echo "Cannot be added to iptables!"
		else
			#add new rule 
			iptables -t nat -I POSTROUTING -s $local_ip -j SNAT --to $public_ip -m comment --comment ip-mapper-$server_id -w
			echo "Finished."
		fi
		echo "========================================="
	elif [[ $status == 'die' ]]; then
		server_id=$(echo $event | awk '{print $2}')
		
		echo "========================================="
		echo $(date)
		echo "server_id=$server_id"
		echo "Action: Removing from NAT by Server ID"
		removeRule $server_id
		echo "Finished."
		echo "========================================="
	fi
	
	# You can configure all events from here: https://docs.docker.com/engine/reference/commandline/events/
    
done

# Why I chose to use the die event
# kill - no public ip on 2nd kick after stop (kicks 2 times on stop? wtf)
# die - no local,public ip (Kicks only once always)
# stop - no local,public ip (Doesn't kick on kill)