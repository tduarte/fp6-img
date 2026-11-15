#!/bin/sh
# Run on the phone: route the front sensor (s5kkd1 on csiphy3) to video0 and capture raw frames.
# usage: front-capture.sh [width height [count]]
W=${1:-3104}; H=${2:-2336}; N=${3:-8}
M="sudo media-ctl -d /dev/media0"
$M -r
$M -l '"msm_csiphy3":1->"msm_csid0":0[1]'
$M -l '"msm_csid0":1->"msm_vfe0_rdi0":0[1]'
F="SGRBG10_1X10/${W}x${H}"
for e in "s5kkd1 3-003d" msm_csiphy3 msm_csid0 msm_vfe0_rdi0; do
	$M -V "\"$e\":0[fmt:$F field:none]" || echo "format failed on $e"
done
rm -f /tmp/front.raw
# camss video nodes are renumbered when the module is reloaded: find vfe0 rdi0 by name
V=/dev/$(basename $(grep -l '^msm_vfe0_video0$' /sys/class/video4linux/video*/name | head -1 | xargs dirname))
echo "capture node $V"
sudo timeout 15 v4l2-ctl -d $V --set-fmt-video=width=$W,height=$H,pixelformat=pgAA \
	--stream-mmap --stream-count=$N --stream-to=/tmp/front.raw 2>&1 | tail -3
ls -la /tmp/front.raw
