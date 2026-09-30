#java -noverify -server -Xmx9500M -Xms9500M -XX:+UseLargePages -XX:+UseParallelOldGC -XX:ParallelGCThreads=16 -XX:+AggressiveOpts -XX:+UseBiasedLocking -cp ../lib/*:mediactrl_rt.jar com.elcom.voicegw.mediactrl.MediaCtrlMain $1 mediactrl_rt$1 ../config/ &
nohup java -cp ../lib/*:mediactrl_rt.jar com.elcom.voicegw.mediactrl.MediaCtrlMain $1 mediactrl_rt$1 ../config/ &
