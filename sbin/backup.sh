#!/bin/sh

umask 0077
renice +19 -p $$ >/dev/null 2>&1

[ ! -e /var/spool/backup ] && mkdir -p /var/spool/backup
[ ! -e /var/spool/backup/tmp ] && mkdir -p /var/spool/backup/tmp

#postgres backup enabled?
cfg_pgsql_backup=`grep cfg_pgsql_backup /usr/local/etc/backup.conf | awk -F= '{ print $2 }' | sed 's/"//g;s/ //g;s/;//g;s/no//i'`
[ -z "${cfg_pgsql_backup}" ] && b_group=root || b_group=postgres

chown root:${b_group} -R /var/spool/backup
chmod 750 /var/spool/backup/tmp >/dev/null 2>&1
chmod 750 /var/spool/backup >/dev/null 2>&1
/usr/local/sbin/backup.pl >/dev/null

chown root:${b_group} -R /var/spool/backup
chmod 640 /var/spool/backup/tmp/* >/dev/null 2>&1
chmod 640 /var/spool/backup/* >/dev/null 2>&1

exit 0
