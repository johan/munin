#
# cron-jobs for munin
#

MAILTO=root

@reboot         root  if [ ! -d /var/run/munin ]; then mkdir /var/run/munin; chmod 0755 /var/run/munin; chown munin:root /var/run/munin; fi
*/5 * * * *     munin if [ -x /usr/bin/munin-cron ]; then /usr/bin/munin-cron; fi
14 10 * * *     munin if [ -x /usr/share/munin/munin-limits ]; then /usr/share/munin/munin-limits --force --contact nagios --contact old-nagios; fi
