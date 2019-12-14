#!/bin/sh

umask 0077

#backup virtualhosts
VZL=`which vzlist 2>/dev/null`
[ -z "${VZL}" ] && exit

VZLIST=`${VZL} -H -o veid | awk '{ print $1 }' 2>/dev/null`
echo "${VZLIST}" | while read VEID; do
[ -n "${VEID}" ] && {
    /usr/local/sbin/backup.pl "/usr/local/etc/backup.conf" "${VEID}" >/dev/null
    chmod 400 /var/spool/backup/tmp/* >/dev/null 2>&1
    }
done

exit
