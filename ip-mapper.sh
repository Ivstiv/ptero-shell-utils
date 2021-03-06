#!/bin/sh
# Solution to this problem: https://github.com/pterodactyl/panel/issues/459
# Reference to iptables NAT tutorial: https://www.karlrupp.net/en/computer/nat_tutorial
#H#
#H# ip-mapper.sh — Maps container IPs to public IPs set in their environment from the panel.
#H#
#H# Examples:
#H#   sh ip-mapper.sh
#H#   sh ip-mapper.sh --list <all | uuid>
#H#   sh ip-mapper.sh --remove <all | uuid>
#H#
#H# Options:
#H#   --list <all | UUID>      Lists active rules added by the script.
#H#   --remove <all | UUID>    Removes rules added by the script.
#H#   --help                   Shows this message.

help() {
    sed -rn 's/^#H# ?//;T;p' "$0"
}

removeRule() {
    echo "Removing rules from -t nat POSTROUTING: $1"
    rules=$(/sbin/iptables -t nat -S POSTROUTING -w | grep "$1" | cut -f 1 -d ' ' --complement)
    if [ -z "$rules" ]; then
        echo "Couldn't find any references."
    else
        echo "$rules" | while IFS= read -r rule; do
            # using eval to expand $rule before the command
            eval /sbin/iptables -t nat -D "$rule" -w
            echo "Removed: $rule"
        done
    fi
}

listRule() {
    rules=$(/sbin/iptables -t nat -S POSTROUTING -w | grep "$1" | cut -f 1 -d ' ' --complement)
    if [ -z "$rules" ]; then
        echo "Couldn't find any references."
    else
        echo "$rules" | while IFS= read -r rule; do
            formattedRule=$(echo "$rule" | awk '{ $7 = substr($7, 11, 36); print $7" :: "$3" -> "$11; }')
            echo "$formattedRule"
        done
    fi
}

checkDependencies() {
    mainShellPID="$$"
    printf "docker\ngrep\nawk\niptables\ncut" | while IFS= read -r program; do
        if ! [ -x "$(command -v "$program")" ]; then
            echo "Error: $program is not installed." >&2
            kill -9 "$mainShellPID" 
        fi
    done
}

if  [ -x "$(command -v nft)" ]; then
            echo "Error: Your system works with nftables which is incopatible with this script! Please use ip-mapper-nft.sh instead." >&2
            exit
 fi

checkDependencies

if [ "$1" = "--remove" ]; then
    # quick validation
    [ -z "$2" ] && echo 'Specify server id or "all"' && exit
    [ "$2" = "all" ] && removeRule ip-mapper || removeRule "$2"
    exit

elif [ "$1" = "--list" ]; then
    # quick validation
    [ -z "$2" ] && echo 'Specify server id or "all"' && exit
    [ "$2" = "all" ] && listRule ip-mapper || listRule "$2"
    exit

elif [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    help
    exit 0
fi

echo "Listening for docker events..."
docker events --filter type=container --format '{{.Status}} {{.Actor.Attributes.name}}' | while read -r event

do
    status=$(echo "$event" | awk '{print $1}')
    if [ "$status" = 'start' ]; then
        server_id=$(echo "$event" | awk '{print $2}')
        local_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$server_id")
        public_ip=$(docker exec "$server_id" printenv SERVER_IP)
        
        echo "========================================="
        date
        echo "Status=$status"
        echo "Server_ID=$server_id"
        echo "Local_IP=$local_ip"
        echo "Public_IP=$public_ip"
        echo "Action: Adding to NAT"
        echo "Trying to remove old rules just in case..."
        removeRule "$server_id"
        echo "Adding the new rule..."
        
        if [ -z "$public_ip" ]; then
            echo "Missing environmental variable: SERVER_IP"
            echo "Cannot be added to iptables!"
        else
            # add new rule 
            eval /sbin/iptables -t nat -I POSTROUTING -s "$local_ip" -j SNAT --to "$public_ip" -m comment --comment ip-mapper-"$server_id" -w
            echo "Finished."
        fi
        echo "========================================="
    elif [ "$status" = 'die' ]; then
        server_id=$(echo "$event" | awk '{print $2}')
        
        echo "========================================="
        date
        echo "Status=$status"
        echo "Server_ID=$server_id"
        echo "Action: Removing from NAT by Server ID"
        removeRule "$server_id"
        echo "Finished."
        echo "========================================="
    fi
    
    # You can configure all events from here: https://docs.docker.com/engine/reference/commandline/events/
    
done

# Why I chose to use the die event
# kill - no public ip on 2nd kick after stop (kicks 2 times on stop? wtf)
# die - no local,public ip (Kicks only once always)
# stop - no local,public ip (Doesn't kick on kill)