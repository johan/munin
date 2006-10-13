#
# cron-jobs for munin
#

MAILTO=root

@reboot         root  if [ ! -d /var/run/munin ]; then /bin/bash -c 'perms=(`/usr/sbin/dpkg-statoverride --list /var/run/munin`); mkdir /var/run/munin; if [ ! -z "$perms" ]; then chown ${perms[0]}:${perms[1]} /var/run/munin; chmod ${perms[2]} /var/run/munin; else chown munin:root /var/run/munin; chmod 0755 /var/run/munin; fi'; fi
*/5 * * * *     munin if [ -x /usr/bin/munin-cron ]; then /usr/bin/munin-cron; fi
14 10 * * *     munin if [ -x /usr/share/munin/munin-limits ]; then /usr/share/munin/munin-limits --force --contact nagios --contact old-nagios; fi
