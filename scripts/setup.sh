#!/bin/bash

# ---------------------------------------------------------
# put to /etc/uci-defaults/
# see default_postinst() in lib/functions.sh
. /lib/functions/uci-defaults.sh
. /lib/functions/system.sh
board=$(board_name)
boardname="${board##*,}"
function init_theme() {
    if uci get luci.themes.Argon >/dev/null 2>&1; then
        uci set luci.main.mediaurlbase="/luci-static/argon"
        uci commit luci
    fi
}

function init_firewall_ipv6() {
	local rule_en='1'
	local wan6=$(uci -q get network.wan.ipv6)

	if [ -z "$wan6" -o "$wan6" = "0" ]; then
		rule_en='0'
	fi

	uci -q show firewall | \
		grep 'Reject-IPv6' >/dev/null && return 0

	uci batch > /dev/null <<-EOF
		add firewall rule
		set firewall.@rule[-1]=rule
		set firewall.@rule[-1].name='Reject-IPv6'
		set firewall.@rule[-1].family='ipv6'
		set firewall.@rule[-1].src='wan'
		set firewall.@rule[-1].dest='*'
		set firewall.@rule[-1].target='REJECT'
		set firewall.@rule[-1].enabled=${rule_en}
		commit firewall
	EOF
}

function init_firewall() {
	uci set firewall.@defaults[0].input='ACCEPT'
	uci set firewall.@defaults[0].output='ACCEPT'
	uci set firewall.@defaults[0].forward='ACCEPT'

	case "$boardname" in
	nanopi-r5* | nanopi-r3* | nanopi-r2*)
		uci set firewall.@defaults[0].flow_offloading='1'
		;;
	*)
		uci set firewall.@defaults[0].flow_offloading='0'
		;;
	esac

	uci set firewall.@defaults[0].fullcone='0'

	zone_name=$(uci -q get firewall.@zone[1].name)
	if [ "$zone_name" = "wan" ]; then
		INTERFACES=$(ip address | grep ^[0-9] | awk -F: '{print $2}' | sed "s/ //g" | grep '^[e]' | grep -v "@" | grep -v "\.")
		IFCOUNT=$(echo "${INTERFACES}" | wc -l)
		if [ ${IFCOUNT} -eq 1 ]; then
			# INSECURE!!! only for single-port device
			uci set firewall.@zone[1].input='ACCEPT'
			uci set firewall.@zone[1].output='ACCEPT'
			uci set firewall.@zone[1].forward='ACCEPT'
		else
			uci set firewall.@zone[1].input='REJECT'
			uci set firewall.@zone[1].output='ACCEPT'
			uci set firewall.@zone[1].forward='REJECT'
		fi
	fi

	uci commit firewall
	fw4 reload
}

function init_network() {
	uci set network.globals.ula_prefix='fd00:ab:cd::/48'
	uci commit network
}

function disable_ipv6() {
	uci set 'network.lan.ipv6=off'
	uci set 'network.lan.delegate=0'
	uci set 'network.lan.force_link=0'

	uci set 'network.wan.ipv6=0'
	uci set 'network.wan.delegate=0'
	uci delete 'network.wan6'
	uci commit network

	uci set 'dhcp.lan.dhcpv6=disabled'
	uci set 'dhcp.lan.ra=disabled'
	uci commit dhcp
}

function init_lcd2usb() {
	if [ -f /usr/bin/lcd2usb_echo ]; then
		sed -i '/^exit 0.*/d' /etc/rc.local
		cat >> /etc/rc.local <<EOL
[ -f /usr/bin/lcd2usb_echo ] && (sleep 10 && /usr/bin/lcd2usb_echo)&
exit 0
EOL
		/usr/bin/lcd2usb_echo&
	fi
}

function init_system() {
	[ -e /usr/bin/ip ] || ln -sf /sbin/ip /usr/bin/ip
	[ -e /etc/crontabs/root ] || touch /etc/crontabs/root
	uci -q batch <<-EOF
		set system.@system[-1].hostname='$HOSTNAME'
		set system.@system[-1].ttylogin='1'
		set system.@system[-1].timezone=CST-8
		set system.@system[-1].zonename=Asia/Shanghai
		commit system
	EOF
}

function init_samba4() {
	[ -f /etc/samba/smb.conf.template ] || return 0

	uci -q batch <<-EOF
		set samba4.@samba[0].name='$HOSTNAME'
		set samba4.@samba[0].workgroup='WORKGROUP'
		set samba4.@samba[0].description='$HOSTNAME'
		set samba4.@samba[0].homes='1'
		commit samba4
	EOF
}

function init_ttyd() {
	uci -q delete ttyd.@ttyd[0].interface
	uci commit ttyd
}

function init_luci_stat() {
	uci set luci_statistics.collectd_thermal.enable='1'
	uci set luci_statistics.collectd_thermal.Device="thermal_zone0 thermal_zone1"
	uci commit luci_statistics
}

function init_openssh() {
	local conf=/etc/ssh/sshd_config
	[ -f $conf ] || return 0

	sed "s/^#PermitRootLogin.*/PermitRootLogin yes/g" $conf -i.orig
	sed "s/^#\s*Banner/Banner/g" $conf -i
	/etc/init.d/sshd reload
}

function old_init_theme() {
	if [ "$PKG_UPGRADE" != 1 ]; then
		uci get luci.themes.Bootstrap >/dev/null 2>&1 && \
		uci batch <<-EOF
			set luci.main.mediaurlbase=/luci-static/bootstrap
			commit luci
		EOF
	fi
}

function init_root_home() {
	chmod 0700 /root
	mkdir -m 0700 -p /root/.ssh

	[ -x /bin/bash ] || return 0
	grep "^root.*bash" /etc/passwd >/dev/null && return 0
	sed "s/^\(root.*\/\)ash/\1bash/g" /etc/passwd -i-
}

function init_root_vimrc() {
	[ -f /root/.vimrc ] && return 0

	cat > /root/.vimrc <<-EOF
		version 8.0

		set shiftwidth=4
		set tabstop=4

		set hlsearch
		set incsearch
	EOF
}

function init_button() {
	local CONF=/etc/triggerhappy/triggers.d/example.conf
	grep "BTN_1" ${CONF} >/dev/null && return 0
	[ -f ${CONF} ] && echo 'BTN_1 1 /sbin/reboot' >> ${CONF}
}

function clean_fstab() {
	# delete all entries but keep /opt
	local index=0
	while uci -q get fstab.@mount[$index]; do
		local target=$(uci -q get fstab.@mount[$index].target)
		if [ "$target" = "/opt" ]; then
			index=$((index + 1))
		else
			uci -q del fstab.@mount[$index]
			# do not increment index because the remaining entries will shift forward after deletion
		fi
	done
	uci commit fstab
}

function update_ntp_server() {
	local def_pool="openwrt.pool.ntp.org"
	local ntps="$(uci -q get system.ntp.server)"

	[ "${ntps}" = "${ntps#0\.${def_pool}}" ] && return 0

	while uci -q del system.ntp.server; do true; done
	uci -q batch <<-EOF
		add_list system.ntp.server="time.apple.com"
		add_list system.ntp.server="ntp.tencent.com"
		add_list system.ntp.server="time.cloudflare.com"
		add_list system.ntp.server="0.${def_pool}"
		commit system.ntp
	EOF
}

# ---------------------------------------------------------
# Refer: package/network/services/odhcpd/files/odhcpd.defaults

function clean_static_host() {
	while uci -q del dhcp.@host[-1]; do true; done
}

function add_static_host() {
	uci add dhcp host
	uci set dhcp.@host[-1].mac=$1
	uci set dhcp.@host[-1].ip=$2
	uci set dhcp.@host[-1].name=$3
	uci commit dhcp
}

# ---------------------------------------------------------

HOSTNAME="NanoPC-T6"

if [ "${1}" = "all" ]; then
	init_network
	init_firewall_ipv6
	init_firewall
	init_system
	init_samba4
	init_ttyd
	init_luci_stat
	init_openssh
	init_theme
	init_root_home
	init_root_vimrc
	init_button
	clean_fstab
	update_ntp_server
fi

