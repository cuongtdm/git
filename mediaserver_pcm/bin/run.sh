#!/bin/bash
export LD_LIBRARY_PATH=/opt/vrbt/bin/mediaserver_pcm/lib
ulimit -c unlimited
/opt/vrbt/bin/mediaserver/bin/mediaserver ../config > /dev/null 2>&1 &
#/opt/vrbt/bin/ivrnew/mediaserver/bin/mediaserver ../config 
