#!/bin/gosh
# u-root init has already mounted /proc, /sys, /dev and made / a tmpfs.
mkdir -p /bundle /tmp /var/run/runsc /var/lib/containerd /run/containerd
mount -t virtiofs bundle /bundle
ip link set eth0 up
dhclient -ipv6=false eth0
# Persistent ext4 attached by the host as /dev/vda (make disk).
mount -t ext4 /dev/vda /var/lib/containerd || echo "disk mount failed (continuing without persistence)"
# runsc probes cgroupfs even with --ignore-cgroups; mount v2 and enable the
# controllers runsc mandates (pids at minimum) on the root subtree.
mount -t cgroup2 cgroup2 /sys/fs/cgroup || echo "cgroup2 mount failed"
for c in pids memory cpu io cpuset; do
  echo "+$c" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || echo "cgroup enable $c failed"
done
# vsock → containerd socket relay for Mac-side control (phase 5).
dios-vsockd &
containerd --config /etc/containerd/config.toml > /tmp/containerd.log 2>&1 &
n=0
while [ ! -S /run/containerd/containerd.sock ]; do
  sleep 0.2
  n=$((n + 1))
  if [ "$n" -gt 100 ]; then echo "containerd socket never appeared"; break; fi
done
echo "--- pre-pull state (persistence evidence) ---"
ctr image ls 2>&1
ctr snapshots ls 2>&1
echo "--- pull (should be no-op on warm disk) ---"
start=$(date +%s)
ctr image pull --platform linux/arm64 docker.io/library/busybox:latest
echo "pull rc=$? in $(( $(date +%s) - start ))s"
# Drop leftovers from previous boots (image + snapshots persist on /dev/vda;
# container rm does not remove snapshots, so rm those too).
for id in demo demo1 demo2 proof2 lsone lsbad e0 e1 e2 e3 x31 x32 x33 f1 f2 f3 ttydemo sbxdemo; do
  ctr t kill -s 9 $id 2>/dev/null || true
  ctr t rm $id 2>/dev/null || true
  ctr c rm $id 2>/dev/null || true
  ctr snapshots rm $id 2>/dev/null || true
done
echo "--- rootfs health ---"
mkdir -p /mnt/img
umount /mnt/img 2>/dev/null || true
ctr image mount docker.io/library/busybox:latest /mnt/img 2>&1 || echo "image mount failed"
ls -l /mnt/img/bin/echo /mnt/img/bin/sh /mnt/img/lib/ld-linux-aarch64.so.1 2>&1
du -s /mnt/img/bin/echo 2>&1
echo "--- runsc direct probe ---"
/bin/runsc --network=host --ignore-cgroups --overlay2=root:memory do echo probe-ok && echo RUNSC-DIRECT-OK || echo "RUNSC-DIRECT-RC=$?"
echo "--- phase 4 gate: ctr run via runsc shim ---"
ctr run --runtime io.containerd.runsc.v1 docker.io/library/busybox:latest demo sh -c 'dmesg | grep -i -m1 gvisor; echo hello-from-gvisor' 2>&1
echo "gate run rc=$?"
ctr t rm demo 2>/dev/null || true
ctr c rm demo 2>/dev/null || true
ctr run --runtime io.containerd.runsc.v1 docker.io/library/busybox:latest demo1 echo hello-from-gvisor 2>&1
echo "demo1 run rc=$?"
ctr t rm demo1 2>/dev/null || true
ctr c rm demo1 2>/dev/null || true
ctr run --runtime io.containerd.runsc.v1 docker.io/library/busybox:latest demo2 echo hello-from-gvisor 2>&1
echo "demo2 run rc=$?"
ctr t rm demo2 2>/dev/null || true
ctr c rm demo2 2>/dev/null || true
ctr run --runtime io.containerd.runsc.v1 docker.io/library/busybox:latest demo echo hello-from-gvisor 2>&1
echo "ctr run rc=$?"
echo "--- tty regression (console-socket path) ---"
ctr run --tty --runtime io.containerd.runsc.v1 docker.io/library/busybox:latest ttydemo echo hello-from-gvisor-tty 2>&1
echo "tty run rc=$?"
ctr t rm ttydemo 2>/dev/null || true
ctr c rm ttydemo 2>/dev/null || true
echo "--- triangulation (stdout/stderr/exit paths) ---"
ctr run --runtime io.containerd.runsc.v1 docker.io/library/busybox:latest proof2 touch /tmp/proof 2>&1
echo "proof run rc=$?"
echo "--- ls test (unmasked verdict) ---"
ctr run --runtime io.containerd.runsc.v1 docker.io/library/busybox:latest lsone ls / 2>&1
echo "lsone run rc=$?"
ctr t rm lsone 2>/dev/null || true
ctr c rm lsone 2>/dev/null || true
echo "--- stderr test: ls nonexistent (expect ls error on stderr) ---"
ctr run --runtime io.containerd.runsc.v1 docker.io/library/busybox:latest lsbad ls /nonexistent 2>&1
echo "lsbad run rc=$?"
ctr t rm lsbad 2>/dev/null || true
ctr c rm lsbad 2>/dev/null || true
echo "--- echo variants triangulation (quoteless) ---"
ctr run --runtime io.containerd.runsc.v1 docker.io/library/busybox:latest e0 true 2>&1
echo "e0 true rc=$?"
ctr t rm e0 2>/dev/null || true
ctr c rm e0 2>/dev/null || true
ctr run --runtime io.containerd.runsc.v1 docker.io/library/busybox:latest e1 echo 2>&1
echo "e1 bare-echo rc=$?"
ctr t rm e1 2>/dev/null || true
ctr c rm e1 2>/dev/null || true
ctr run --runtime io.containerd.runsc.v1 docker.io/library/busybox:latest e2 sh -c echo hi 2>&1
echo "e2 sh-echo rc=$?"
ctr t rm e2 2>/dev/null || true
ctr c rm e2 2>/dev/null || true
ctr run --runtime io.containerd.runsc.v1 docker.io/library/busybox:latest e3 cat /etc/passwd 2>&1
echo "e3 cat rc=$?"
ctr t rm e3 2>/dev/null || true
ctr c rm e3 2>/dev/null || true
echo "--- exit-3 3x (nonzero fast-exit, guest FIFO path) ---"
for n in 1 2 3; do
  ctr run --runtime io.containerd.runsc.v1 docker.io/library/busybox:latest x3$n sh -c 'exit 3' 2>&1
  echo "x3$n exit-3 rc=$?"
  ctr t rm x3$n 2>/dev/null || true
  ctr c rm x3$n 2>/dev/null || true
done
echo "--- false 3x (nonzero fast-exit) ---"
for n in 1 2 3; do
  ctr run --runtime io.containerd.runsc.v1 docker.io/library/busybox:latest f$n false 2>&1
  echo "f$n false rc=$?"
  ctr t rm f$n 2>/dev/null || true
  ctr c rm f$n 2>/dev/null || true
done
echo "--- post-run snapshots ---"
ctr snapshots ls 2>&1
echo "--- exit-code forensics (128 = shim InternalErrorCode, sandbox died) ---"
grep -c 'Failed to wait' /tmp/containerd.log 2>&1
grep -n 'Failed to wait' /tmp/containerd.log 2>&1 | head -n 4
dmesg 2>&1 | grep -i -m3 -E 'oom|killed process' || echo "no oom in dmesg"
free 2>&1 || cat /proc/meminfo 2>&1 | head -n 3
echo "container exited ($?); powering off"
# Host-side debugging (phase 5): `touch artifacts/bundle/hold` keeps the VM
# up so the Mac can drive containerd over the vsock bridge.
if [ -e /bundle/hold ]; then
  echo "hold file present; staying up for host control"
  sleep 600
fi
# Powering off makes VZ call guestDidStop, so the launcher exits cleanly.
shutdown halt
