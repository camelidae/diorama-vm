#!/bin/gosh
# u-root init has already mounted /proc, /sys, /dev and made / a tmpfs.

mkdir -p /bundle /tmp /var/run/runsc
mount -t virtiofs bundle /bundle

ip link set eth0 up
dhclient -ipv6=false eth0

runsc --network=host --ignore-cgroups do echo "gVisor alive"

cd /bundle
[ -f config.json ] || runsc spec -- /bin/sh
exec runsc --network=host --ignore-cgroups --overlay2=root:memory run demo
