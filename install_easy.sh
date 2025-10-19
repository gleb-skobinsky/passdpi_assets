#!/bin/sh

# automated script for easy installing zapret

EXEDIR="$(dirname "$0")"
EXEDIR="$(cd "$EXEDIR"; pwd)"
ZAPRET_BASE=${ZAPRET_BASE:-"$EXEDIR"}
ZAPRET_TARGET=${ZAPRET_TARGET:-/opt/zapret}
ZAPRET_TARGET_RW=${ZAPRET_RW:-"$ZAPRET_TARGET"}
ZAPRET_TARGET_CONFIG="$ZAPRET_TARGET_RW/config"
ZAPRET_RW=${ZAPRET_RW:-"$ZAPRET_BASE"}
ZAPRET_CONFIG=${ZAPRET_CONFIG:-"$ZAPRET_RW/config"}
ZAPRET_CONFIG_DEFAULT="$ZAPRET_BASE/config.default"
IPSET_DIR="$ZAPRET_BASE/ipset"

[ -f "$ZAPRET_CONFIG" ] || {
	ZAPRET_CONFIG_DIR="$(dirname "$ZAPRET_CONFIG")"
	[ -d "$ZAPRET_CONFIG_DIR" ] || mkdir -p "$ZAPRET_CONFIG_DIR"
	cp "$ZAPRET_CONFIG_DEFAULT" "$ZAPRET_CONFIG"
}
. "$ZAPRET_CONFIG"
. "$ZAPRET_BASE/common/base.sh"
. "$ZAPRET_BASE/common/elevate.sh"
. "$ZAPRET_BASE/common/fwtype.sh"
. "$ZAPRET_BASE/common/dialog.sh"
. "$ZAPRET_BASE/common/ipt.sh"
. "$ZAPRET_BASE/common/installer.sh"
. "$ZAPRET_BASE/common/virt.sh"
. "$ZAPRET_BASE/common/list.sh"

GET_LIST="$IPSET_DIR/get_config.sh"

check_readonly_system()
{
	local RO
	echo \* checking readonly system
        case $SYSTEM in
		systemd)
			[ -w "$SYSTEMD_SYSTEM_DIR" ] || RO=1
			;;
		openrc)
			[ -w "$(dirname "$INIT_SCRIPT")" ] || RO=1
			;;
	esac
	[ -z "$RO" ] || {
		echo '!!! READONLY SYSTEM DETECTED !!!'
		echo '!!! WILL NOT BE ABLE TO CONFIGURE STARTUP !!!'
		echo '!!! MANUAL STARTUP CONFIGURATION IS REQUIRED !!!'
		ask_yes_no N "do you want to continue" || exitp 5
	}
}

check_source()
{
	local bad=0

	echo \* checking source files
	case $SYSTEM in
		systemd)
			[ -f "$EXEDIR/init.d/systemd/zapret.service" ] || bad=1
			;;
		openrc)
			[ -f "$EXEDIR/init.d/openrc/zapret" ] || bad=1
			;;
		macos)
			[ -f "$EXEDIR/init.d/macos/zapret" ] || bad=1
			;;
       esac
       [ "$bad" = 1 ] && {
               echo 'some critical files are missing'
               echo 'are you sure you are not using embedded release ? you need full version for traditional systems'
               exitp 5
       }
}

check_bins()
{
	echo \* checking executables

	fix_perms_bin_test "$EXEDIR"
	local arch="$(get_bin_arch)"
	local make_target
	local cf="-march=native"
	[ "$FORCE_BUILD" = "1" ] && {
		echo forced build mode
		if [ "$arch" = "my" ]; then
			echo already compiled
		else
			arch=""
		fi
	}
	if [ -n "$arch" ] ; then
		echo found architecture "\"$arch\""
	elif [ -f "$EXEDIR/Makefile" ] && exists make; then
		echo trying to compile
		case $SYSTEM in
			macos)
				make_target=mac
				cf=
				;;
			systemd)
				make_target=systemd
				;;
		esac
		CFLAGS="${cf:+$cf }${CFLAGS}" OPTIMIZE=-O2 make -C "$EXEDIR" $make_target || {
			echo could not compile
			make -C "$EXEDIR" clean
			exitp 8
		}
		echo compiled
	else
		echo build tools not found
		exitp 8
	fi
}

call_install_bin()
{
	sh "$EXEDIR/install_bin.sh" $1
}
get_bin_arch()
{
	call_install_bin getarch
}

install_binaries()
{
	echo \* installing binaries

	call_install_bin || {
		echo compatible binaries not found
		exitp 8
	}
}

ws_opt_validate()
{
	# ПРИМЕЧАНИЕ ДЛЯ РАСПРОСТРАНИТЕЛЕЙ КОПИПАСТЫ
	# ЭТОТ КОД СДЕЛАН СПЕЦИАЛЬНО ДЛЯ ВАС, ЧТОБЫ ВЫ НЕ ПОСТИЛИ В СЕТЬ ПЛОХИЕ РЕЦЕПТЫ
	# ЕСЛИ ВАМ ХОЧЕТСЯ ЕГО УДАЛИТЬ И НАПИСАТЬ ИНСТРУКЦИЮ КАК ЕГО УДАЛЯТЬ, ВЫ ДЕЛАЕТЕ ХРЕНОВУЮ УСЛУГУ. НАПИШИТЕ ЛУЧШЕ custom script.
	# custom script - ЭТО ФАЙЛИК, КОТОРЫЙ ДОСТАТОЧНО СКОПИРОВАТЬ В НУЖНУЮ ДИРЕКТОРИЮ, ЧТОБЫ ОН СДЕЛАЛ ТОЖЕ САМОЕ, НО ЭФФЕКТИВНО.
	# ФИЛЬТРАЦИЯ ПО IPSET В ЯДРЕ НЕСРАВНИМО ЭФФЕКТИВНЕЕ, ЧЕМ ПЕРЕКИДЫВАТЬ ВСЕ ПАКЕТЫ В nfqws И ТАМ ФИЛЬТРОВАТЬ
	# --ipset СУЩЕСТВУЕТ ТОЛЬКО ДЛЯ ВИНДЫ И LINUX СИСТЕМ БЕЗ ipset (НАПРИМЕР, Android).
	# И ТОЛЬКО ПО ЭТОЙ ПРИЧИНЕ ОНО НЕ ВЫКИНУТО ПОЛНОСТЬЮ ИЗ LINUX ВЕРСИИ
	has_bad_ws_options "$1" && {
		help_bad_ws_options
		return 1
	}
	return 0
}
tpws_opt_validate()
{
	ws_opt_validate "$1" || return 1
	dry_run_tpws || {
		echo invalid tpws options
		return 1
	}
}
tpws_socks_opt_validate()
{
	# --ipset allowed here
	dry_run_tpws_socks || {
		echo invalid tpws options
		return 1
	}
}
nfqws_opt_validate()
{
	ws_opt_validate "$1" || return 1
	dry_run_nfqws || {
		echo invalid nfqws options
		return 1
	}
}

select_mode_group()
{
	# $1 - ENABLE var name
	# $2 - ask text
	# $3 - vars
	# $4 - validator func
	# $5 - validator func param var

	local enabled var v edited bad Y param

	echo
	ask_yes_no_var $1 "$2"
	write_config_var $1
	eval enabled=\$$1
	[ "$enabled" = 1 ] && {
		echo
		while  : ; do
			list_vars $3
			bad=0; Y=N
			[ -n "$4" ] && {
				eval param="\$$5"
				$4 "$param"; bad=$?
				[ "$bad" = 1 ] && Y=Y
			}
			ask_yes_no $Y "do you want to edit the options" || {
				[ "$bad" = 1 ] && {
					echo installer will not allow to use bad options. exiting.
					exitp 3
				}
				[ -n "$edited" ] && {
					for var in $3; do
						write_config_var $var
					done
				}
				break
			}
			edit_vars $3
			edited=1
			echo ..edited..
		done
	}
}

select_mode_tpws_socks()
{
	local EDITVAR_NEWLINE_DELIMETER="--new" EDITVAR_NEWLINE_VARS="TPWS_SOCKS_OPT"
	select_mode_group TPWS_SOCKS_ENABLE "enable tpws socks mode on port $TPPORT_SOCKS ?" "TPPORT_SOCKS TPWS_SOCKS_OPT" tpws_socks_opt_validate TPWS_SOCKS_OPT
}
select_mode_tpws()
{
	local EDITVAR_NEWLINE_DELIMETER="--new" EDITVAR_NEWLINE_VARS="TPWS_OPT"
	select_mode_group TPWS_ENABLE "enable tpws transparent mode ?" "TPWS_PORTS TPWS_OPT" tpws_opt_validate TPWS_OPT
}
select_mode_nfqws()
{
	local EDITVAR_NEWLINE_DELIMETER="--new" EDITVAR_NEWLINE_VARS="NFQWS_OPT"
	select_mode_group NFQWS_ENABLE "enable nfqws ?" "NFQWS_PORTS_TCP NFQWS_PORTS_UDP NFQWS_TCP_PKT_OUT NFQWS_TCP_PKT_IN NFQWS_UDP_PKT_OUT NFQWS_UDP_PKT_IN NFQWS_PORTS_TCP_KEEPALIVE NFQWS_PORTS_UDP_KEEPALIVE NFQWS_OPT" nfqws_opt_validate NFQWS_OPT
}

select_mode_mode()
{
	select_mode_tpws_socks
	select_mode_tpws
	[ "$UNAME" = Linux ] && select_mode_nfqws

	echo
	echo "current custom scripts in $CUSTOM_DIR/custom.d:"
	[ -d "$CUSTOM_DIR/custom.d" ] && ls "$CUSTOM_DIR/custom.d"
	echo "Make sure this is ok"
	echo
}

select_mode_filter()
{
	local filter="none ipset hostlist autohostlist"
	echo
	echo select filtering :
	ask_list MODE_FILTER "$filter" none && write_config_var MODE_FILTER
}

select_mode()
{
	select_mode_filter
	select_mode_mode
	select_mode_iface
}

select_getlist()
{
	if [ "$MODE_FILTER" = "ipset" -o "$MODE_FILTER" = "hostlist" -o "$MODE_FILTER" = "autohostlist" ]; then
		local D=N
		[ -n "$GETLIST" ] && D=Y
		echo
		if ask_yes_no $D "do you want to auto download ip/host list"; then
			if [ "$MODE_FILTER" = "hostlist" -o "$MODE_FILTER" = "autohostlist" ] ; then
				GETLISTS="get_refilter_domains.sh get_antizapret_domains.sh get_reestr_resolvable_domains.sh get_reestr_hostlist.sh"
				GETLIST_DEF="get_antizapret_domains.sh"
			else
				GETLISTS="get_user.sh get_refilter_ipsum.sh get_antifilter_ip.sh get_antifilter_ipsmart.sh get_antifilter_ipsum.sh get_antifilter_ipresolve.sh get_antifilter_allyouneed.sh get_reestr_resolve.sh get_reestr_preresolved.sh get_reestr_preresolved_smart.sh"
				GETLIST_DEF="get_antifilter_allyouneed.sh"
			fi
			ask_list GETLIST "$GETLISTS" "$GETLIST_DEF" && write_config_var GETLIST
			return
		fi
	fi
	GETLIST=""
	write_config_var GETLIST
}

ask_config()
{
	select_mode
	select_getlist
}

ask_config_offload()
{
	[ "$FWTYPE" = nftables ] || is_ipt_flow_offload_avail && {
		echo
		echo flow offloading can greatly increase speed on slow devices and high speed links \(usually 150+ mbits\)
		if [ "$SYSTEM" = openwrt ]; then
			echo unfortuantely its not compatible with most nfqws options. nfqws traffic must be exempted from flow offloading.
			echo donttouch = disable system flow offloading setting if nfqws mode was selected, dont touch it otherwise and dont configure selective flow offloading
			echo none = always disable system flow offloading setting and dont configure selective flow offloading
			echo software = always disable system flow offloading setting and configure selective software flow offloading
			echo hardware = always disable system flow offloading setting and configure selective hardware flow offloading
		else
			echo offloading is applicable only to forwarded traffic. it has no effect on outgoing traffic
			echo hardware flow offloading is available only on specific supporting hardware. most likely will not work on a generic system
		fi
		echo offloading breaks traffic shaper
		echo select flow offloading :
		local options="none software hardware"
		local default="none"
		[ "$SYSTEM" = openwrt ] && {
			options="donttouch none software hardware"
			default="donttouch"
		}
		ask_list FLOWOFFLOAD "$options" $default && write_config_var FLOWOFFLOAD
	}
}

ask_config_tmpdir()
{
	# ask tmpdir change for low ram systems with enough free disk space
	[ -n "$GETLIST" ] && [ $(get_free_space_mb "$EXEDIR/tmp") -ge 128 ] && [ $(get_ram_mb) -le 400 ] && {
		echo
		echo /tmp in openwrt is tmpfs. on low RAM systems there may be not enough RAM to store downloaded files
		echo default tmpfs has size of 50% RAM
		echo "RAM  : $(get_ram_mb) Mb"
		echo "DISK : $(get_free_space_mb) Mb"
		echo select temp file location
		[ -z "$TMPDIR" ] && TMPDIR=/tmp
		ask_list TMPDIR "/tmp $EXEDIR/tmp" && {
		    [ "$TMPDIR" = "/tmp" ] && TMPDIR=
		    write_config_var TMPDIR
		}
	}
}

nft_flow_offload()
{
	[ "$UNAME" = Linux -a "$FWTYPE" = nftables ] && [ "$FLOWOFFLOAD" = software -o "$FLOWOFFLOAD" = hardware ]
}

ask_iface()
{
	# $1 - var to ask
	# $2 - additional name for empty string synonim

	local ifs i0 def new
	eval def="\$$1"

	[ -n "$2" ] && i0="$2 "
	case $SYSTEM in
		macos)
			ifs="$(ifconfig -l)"
			;;
		*)
			ifs="$(ls /sys/class/net)"
			;;
	esac
	[ -z "$def" ] && eval $1="$2"
	ask_list $1 "$i0$ifs" && {
		eval new="\$$1"
		[ "$new" = "$2" ] && eval $1=""
		write_config_var $1
	}
}
ask_iface_lan()
{
	echo LAN interface :
	local opt
	nft_flow_offload || opt=NONE
	ask_iface IFACE_LAN $opt
}
ask_iface_wan()
{
	echo WAN interface :
	local opt
	nft_flow_offload || opt=ANY
	ask_iface IFACE_WAN $opt
}

select_mode_iface()
{
	# openwrt has its own interface management scheme
	# filter just creates ip tables, no daemons involved
	# nfqws sits in POSTROUTING chain and unable to filter by incoming interface
	# tpws redirection works in PREROUTING chain
	# in tpws-socks mode IFACE_LAN specifies additional bind interface for the socks listener
	# it's not possible to instruct tpws to route outgoing connection to an interface (OS routing table decides)
	# custom mode can also benefit from interface names (depends on custom script code)

	[ "$SYSTEM" = "openwrt" ] && return

	ask_iface_lan
	ask_iface_wan
}

default_files()
{
	# $1 - ro location
	# $2 - rw location (can be equal to $1)
	[ -d "$2/ipset" ] || mkdir -p "$2/ipset"
	[ -f "$2/ipset/zapret-hosts-user-exclude.txt" ] || cp "$1/ipset/zapret-hosts-user-exclude.txt.default" "$2/ipset/zapret-hosts-user-exclude.txt"
	[ -f "$2/ipset/zapret-hosts-user.txt" ] || echo nonexistent.domain >> "$2/ipset/zapret-hosts-user.txt"
	[ -f "$2/ipset/zapret-hosts-user-ipban.txt" ] || touch "$2/ipset/zapret-hosts-user-ipban.txt"
	for dir in openwrt sysv macos; do
		[ -d "$1/init.d/$dir" ] && {
			[ -d "$2/init.d/$dir" ] || mkdir -p "$2/init.d/$dir"
			[ -d "$2/init.d/$dir/custom.d" ] || mkdir -p "$2/init.d/$dir/custom.d"
		}
	done
}
copy_all()
{
	local dir

	cp -R "$1" "$2"
	[ -d "$2/tmp" ] || mkdir "$2/tmp"
}

fix_perms()
{
	[ -d "$1" ] || return
	find "$1" -type d -exec chmod 755 {} \;
	find "$1" -type f -exec chmod 644 {} \;
	local chow
	case "$UNAME" in
		Linux)
			chow=root:root
			;;
		*)
			chow=root:wheel
	esac
	chown -R $chow "$1"
	find "$1/binaries" '(' -name tpws -o -name dvtws -o -name nfqws -o -name ip2net -o -name mdig ')' -exec chmod 755 {} \;
	for f in \
install_bin.sh \
blockcheck.sh \
install_easy.sh \
install_prereq.sh \
files/huawei/E8372/zapret-ip \
files/huawei/E8372/unzapret-ip \
files/huawei/E8372/run-zapret-hostlist \
files/huawei/E8372/unzapret \
files/huawei/E8372/zapret \
files/huawei/E8372/run-zapret-ip \
ipset/get_exclude.sh \
ipset/clear_lists.sh \
ipset/get_refilter_domains.sh \
ipset/get_refilter_ipsum.sh \
ipset/get_antifilter_ipresolve.sh \
ipset/get_reestr_resolvable_domains.sh \
ipset/get_config.sh \
ipset/get_reestr_preresolved.sh \
ipset/get_user.sh \
ipset/get_antifilter_allyouneed.sh \
ipset/get_reestr_resolve.sh \
ipset/create_ipset.sh \
ipset/get_reestr_hostlist.sh \
ipset/get_ipban.sh \
ipset/get_antifilter_ipsum.sh \
ipset/get_antifilter_ipsmart.sh \
ipset/get_antizapret_domains.sh \
ipset/get_reestr_preresolved_smart.sh \
ipset/get_antifilter_ip.sh \
init.d/pfsense/zapret.sh \
init.d/macos/zapret \
init.d/runit/zapret/run \
init.d/runit/zapret/finish \
init.d/openrc/zapret \
init.d/sysv/zapret \
init.d/openwrt/zapret \
init.d/openwrt-minimal/tpws/etc/init.d/tpws \
uninstall_easy.sh \
	; do chmod 755 "$1/$f" 2>/dev/null ; done
}


_backup_settings()
{
	local i=0
	for f in "$@"; do
		# safety check
		[ -z "$f" -o "$f" = "/" ] && continue

		[ -f "$ZAPRET_TARGET/$f" ] && cp -f "$ZAPRET_TARGET/$f" "/tmp/zapret-bkp-$i"
		[ -d "$ZAPRET_TARGET/$f" ] && cp -rf "$ZAPRET_TARGET/$f" "/tmp/zapret-bkp-$i"
		i=$(($i+1))
	done
}
_restore_settings()
{
	local i=0
	for f in "$@"; do
		# safety check
		[ -z "$f" -o "$f" = "/" ] && continue

		[ -f "/tmp/zapret-bkp-$i" ] && {
			mv -f "/tmp/zapret-bkp-$i" "$ZAPRET_TARGET/$f" || rm -f "/tmp/zapret-bkp-$i"
		}
		[ -d "/tmp/zapret-bkp-$i" ] && {
			[ -d "$ZAPRET_TARGET/$f" ] && rm -r "$ZAPRET_TARGET/$f"
			mv -f "/tmp/zapret-bkp-$i" "$ZAPRET_TARGET/$f" || rm -r "/tmp/zapret-bkp-$i"
		}
		i=$(($i+1))
	done
}
backup_restore_settings()
{
	# $1 - 1 - backup, 0 - restore
	local mode=$1
	on_off_function _backup_settings _restore_settings $mode "config" "init.d/sysv/custom.d" "init.d/openwrt/custom.d" "init.d/macos/custom.d" "ipset/zapret-hosts-user.txt" "ipset/zapret-hosts-user-exclude.txt" "ipset/zapret-hosts-user-ipban.txt" "ipset/zapret-hosts-auto.txt"
}

config_is_obsolete()
{
	[ -f "$1" ] && grep -qE "^[[:space:]]*NFQWS_OPT_DESYNC=|^[[:space:]]*MODE_HTTP=|^[[:space:]]*MODE_HTTPS=|^[[:space:]]*MODE_QUIC=|^[[:space:]]*MODE=" "$1"
}

check_location()
{
	# $1 - copy function

	echo \* checking location
	# use inodes in case something is linked
	if [ -d "$ZAPRET_TARGET" ] && [ $(get_dir_inode "$EXEDIR") = $(get_dir_inode "$ZAPRET_TARGET") ]; then
		config_is_obsolete "$ZAPRET_CONFIG" && {
			echo config file $ZAPRET_CONFIG is obsolete. cannot continue.
			exitp 3
		}
		default_files "$ZAPRET_TARGET" "$ZAPRET_RW"
	else
		local obsolete=0 rwdir=0
		config_is_obsolete "$ZAPRET_TARGET_CONFIG" && obsolete=1
		[ $(get_dir_inode "$ZAPRET_BASE") = $(get_dir_inode "$ZAPRET_RW") ] || rwdir=1
		[ $rwdir = 1 -a $obsolete = 1 ] && {
                 	echo config file in custom ZAPRET_RW directory is obsolete : $ZAPRET_TARGET_CONFIG
			echo you need to edit or delete it to continue. also check for obsolete custom scripts.
			exitp 3
		}
		echo
		echo easy install is supported only from default location : $ZAPRET_TARGET
		echo currently its run from $EXEDIR
		if ask_yes_no N "do you want the installer to copy it for you"; then
			local keep=N
			if [ -d "$ZAPRET_TARGET" ]; then
				echo
				echo installer found existing $ZAPRET_TARGET
				echo directory needs to be replaced. config and custom scripts can be kept or replaced with clean version
				if ask_yes_no N "do you want to delete all files there and copy this version"; then
					echo
					if [ $obsolete = 1 ] ; then
						echo obsolete config is detected : $ZAPRET_TARGET_RW
						ask_yes_no N "impossible to keep config, custom scripts and user lists. do you want to delete them ?" || {
							echo refused to delete config in $ZAPRET_TARGET. exiting
							exitp 3
						}
					elif [ $rwdir != 1 ]; then
						ask_yes_no Y "keep config, custom scripts and user lists" && keep=Y
						[ "$keep" = "Y" ] && backup_restore_settings 1
					fi
					rm -r "$ZAPRET_TARGET"
				else
					echo refused to overwrite $ZAPRET_TARGET. exiting
					exitp 3
				fi
			fi
			local B="$(dirname "$ZAPRET_TARGET")"
			[ -d "$B" ] || mkdir -p "$B"
			$1 "$EXEDIR" "$ZAPRET_TARGET"
			fix_perms "$ZAPRET_TARGET"
			[ "$keep" = "Y" ] && backup_restore_settings 0
			echo relaunching itself from $ZAPRET_TARGET
			exec "$ZAPRET_TARGET/$(basename "$0")"
		else
			echo copying aborted. exiting
			exitp 3
		fi
	fi
	echo running from $EXEDIR
}

download_list()
{
	[ -x "$GET_LIST" ] &&	{
		echo \* downloading blocked ip/host list

		# can be txt or txt.gz
		"$IPSET_DIR/clear_lists.sh"
		"$GET_LIST"
	}
}


dnstest()
{
	# $1 - dns server. empty for system resolver
	nslookup w3.org $1 >/dev/null 2>/dev/null
}
check_dns()
{
	echo \* checking DNS

	dnstest || {
		echo -- DNS is not working. It's either misconfigured or blocked or you don't have inet access.
		return 1
	}
	echo system DNS is working
	return 0
}

install_linux()
{
	INIT_SCRIPT_SRC="$EXEDIR/init.d/sysv/zapret"
	CUSTOM_DIR="$ZAPRET_RW/init.d/sysv"

	check_bins
	require_root
	check_location copy_all
	check_dns
	check_virt
	select_fwtype
	check_prerequisites_linux
	install_binaries
	select_ipv6
	ask_config_offload
	ask_config
	download_list
	crontab_del_quiet
	# desktop system. more likely up at daytime
	crontab_add 10 22

	echo
	echo '!!! WARNING. YOUR SETUP IS INCOMPLETE !!!'
	echo you must manually add to auto start : $INIT_SCRIPT_SRC start
	echo make sure it\'s executed after your custom/firewall iptables configuration
	echo "if your system uses sysv init : ln -fs $INIT_SCRIPT_SRC /etc/init.d/zapret ; chkconfig zapret on"
}

# build binaries, do not use precompiled
[ "$1" = "make" ] && FORCE_BUILD=1

umask 0022
fix_sbin_path
fsleep_setup
check_system
check_source

install_linux


exitp 0
