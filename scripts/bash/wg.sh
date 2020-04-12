#!/usr/bin/env bash

cd `dirname ${BASH_SOURCE[0]}`
WG_CONFIG="/etc/wireguard/wg0.conf"

. ../data/wg.def
CLIENT_TPL_FILE=../data/client.conf.tpl
SERVER_TPL_FILE=../data/server.conf.tpl
SAVED_FILE=../data/tmp/saved.tmp
AVAILABLE_IP_FILE=../data/tmp/available_ip.tmp
WG_TMP_CONF_FILE=../data/tmp/$_INTERFACE.conf.tmp
WG_CONF_FILE="/etc/wireguard/$_INTERFACE.conf"

dec2ip() {
    local delim=''
    local ip dec=$@
    for e in {3..0}
    do
        ((octet = dec / (256 ** e) ))
        ((dec -= octet * 256 ** e))
        ip+=$delim$octet
        delim=.
    done
    printf '%s\n' "$ip"
}

generate_cidr_ip_file_if() {
    local cidr=${_VPN_NET}
    local ip mask a b c d

    IFS=$'/' read ip mask <<< "$cidr"
    IFS=. read -r a b c d <<< "$ip"
    local beg=$((a * 256 ** 3 + b * 256 ** 2 + c * 256 + d))
    local end=$(( beg+(1<<(32-mask))-1 ))
    ip=$(dec2ip $((beg+1)))
    _SERVER_IP="$ip/$mask"
    if [[ -f $AVAILABLE_IP_FILE ]]; then
        return
    fi

    > $AVAILABLE_IP_FILE
    local i=$((beg+2))
    while [[ $i -lt $end ]]; do
        ip=$(dec2ip $i)
	echo "$ip/$mask" >> $AVAILABLE_IP_FILE
        i=$((i+1))
    done
}

get_vpn_ip() {
    local ip=$(head -1 $AVAILABLE_IP_FILE)
    if [[ $ip ]]; then
	local mat="${ip/\//\\\/}"
        sed -i "/^$mat$/d" $AVAILABLE_IP_FILE
    fi
    echo "$ip"
}

add_user() {
    local user=$1
    local template_file=${CLIENT_TPL_FILE}
    local interface=${_INTERFACE}
    local userdir="../../profiles/$user"

    mkdir -p "$userdir"

    CLIENT_PRIVKEY=$( wg genkey )
    CLIENT_PUBKEY=$( echo $CLIENT_PRIVKEY | wg pubkey )
    PRIVATE_SUBNET=$( head -n1 $WG_CONFIG | awk '{print $2}')
    PRIVATE_SUBNET_MASK=$( echo $PRIVATE_SUBNET | cut -d "/" -f 2 )
    SERVER_ENDPOINT=$( head -n1 $WG_CONFIG | awk '{print $3}')
    SERVER_PUBKEY=$( head -n1 $WG_CONFIG | awk '{print $4}')
    CLIENT_DNS=$( head -n1 $WG_CONFIG | awk '{print $5}')
    LASTIP=$( grep "/32" $WG_CONFIG | tail -n1 | awk '{print $3}' | cut -d "/" -f 1 | cut -d "." -f 4 )
    CLIENT_ADDRESS="${PRIVATE_SUBNET::-4}$((LASTIP+1))"

    echo "[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_ADDRESS/$PRIVATE_SUBNET_MASK
DNS = $CLIENT_DNS
[Peer]
PublicKey = $SERVER_PUBKEY
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $SERVER_ENDPOINT
PersistentKeepalive = 25" > $userdir/wg0.conf
qrencode -o $userdir/$user.png  < $userdir/wg0.conf

    ip address | grep -q wg0 && wg set wg0 peer "$CLIENT_PUBKEY" allowed-ips "$CLIENT_ADDRESS/32"
    echo "Client added, new configuration file --> $userdir/wg0.conf"
}

del_user() {
    local user=$1
    local userdir="../../profiles/$user"
    local ip key
    local interface=${_INTERFACE}

    read ip key <<<"$(awk "/^$user /{print \$2, \$3}" ${SAVED_FILE})"
    if [[ -n "$key" ]]; then
        wg set $interface peer $key remove
        if [[ $? -ne 0 ]]; then
            echo "wg set failed"
            exit 1
        fi
    fi
    sed -i "/^$user /d" ${SAVED_FILE}
    if [[ -n "$ip" ]]; then
        echo "$ip" >> ${AVAILABLE_IP_FILE}
    fi
    rm -rf $userdir && echo -e "\e[44m[wg-api cli]\e[0m Revoked $user"
}

generate_and_install_server_config_file() {
    echo "VOID"
}

clear_all() {
    local interface=$_INTERFACE
    wg-quick down $interface
    > $WG_CONF_FILE
    rm -f ${SAVED_FILE} ${AVAILABLE_IP_FILE}
}

do_user() {
    generate_cidr_ip_file_if

    if [[ $action == "-a" ]]; then
        if [[ -d $user ]]; then
            echo "$user exist"
            exit 1
        fi
        add_user $user
    elif [[ $action == "-d" ]]; then
        del_user $user
    fi

    generate_and_install_server_config_file
}

init_server() {
    local interface=$_INTERFACE
    local template_file=${SERVER_TPL_FILE}

    if [[ -s $WG_CONF_FILE ]]; then
        echo "$WG_CONF_FILE exist"
	exit 1
    fi
    generate_cidr_ip_file_if
    eval "echo \"$(cat "${template_file}")\"" > $WG_CONF_FILE
    chmod 600 $WG_CONF_FILE
    wg-quick up $interface
}

list_user() {
    cat ${SAVED_FILE}
}

usage() {
    echo "usage: $0 [-a|-d|-c|-g|-i] [username] [-r]

    -i: init server conf
    -a: add user
    -d: del user
    -l: list all users
    -c: clear all
    -g: generate ip file
    -r: enable router(allow 0.0.0.0/0)
    "
}

# main
if [[ $EUID -ne 0 ]]; then
   echo -e "\e[44m[wg-api cli]\e[0m This script needs to be run as root"
    exit 1
fi

action=$1
user=$2
route=$3

if [[ $action == "-i" ]]; then
    init_server
elif [[ $action == "-c" ]]; then
    clear_all
elif [[ $action == "-l" ]]; then
    list_user
elif [[ $action == "-g" ]]; then
    generate_cidr_ip_file_if
elif [[ ! -z "$user" && ( $action == "-a" || $action == "-d" ) ]]; then
    do_user
else
    usage
    exit 1
fi
