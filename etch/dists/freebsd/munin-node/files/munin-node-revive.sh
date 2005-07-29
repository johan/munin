#!/bin/sh

#
# Add the following lines to /etc/rc.conf to enable munin-node:
# munin_node_enable (bool):      Set to "NO" by default.
#                                Set it to "YES" to enable munin-node
# munin_node_config (path):      Set to "%%PREFIX%%/etc/munin/munin-node.conf" by default.
#

. %%RC_SUBR%%

name="munin_node"
rcvar=`set_rcvar`

[ -z "$munin_node_enable" ] && munin_node_enable="NO"
[ -z "$munin_node_config" ] && munin_node_config="%%PREFIX%%/etc/munin/munin-node.conf"

command="%%PREFIX%%/sbin/munin-node"
pidfile=`awk '$1 == "pid_file" { print $2 }' $munin_node_config`

load_rc_config $name

#set -x
pid=`check_pidfile $pidfile %%PREFIX%%/sbin/munin-node`
if [ -z "$pid" ]; then
  run_rc_command start
fi
