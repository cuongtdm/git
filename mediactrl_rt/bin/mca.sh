#!/bin/bash
# Source function library.
# import some useful functions : status(), echo_success(), echo_failed() ....
#. /opt/li/bin/li_functions

source $HOME/.bash_profile

RETVAL=0


start() {
    local app_idx=${1##*/}
    local app_name=${2##*/}
    case $app_name in
    *mediactrl*)
        ./mediactrl_env.sh $app_idx $app_name
        ;;
    esac
}

stop() {
    local app_idx=${1##*/}
    local app_name=${2##*/}
    local PID=`ps -ef | grep java | grep $app_name$app_idx | grep -v controller_user | grep -v grep | awk '{print $2}'`

    if [ -z "$PID" ]
    then
        echo "$app_name$app_idx not started"
        echo ""
        return 1
    fi

    echo "Killing $app_name$app_idx(pid=$PID)"
    echo ""
    kill ${PID}
    RETVAL=$?
    if [ $RETVAL -eq 0 ] 
    then
        echo "Killed $app_name$app_idx"
        echo ""
    else
        echo "Failed to kill $app_name$app_idx"
        echo ""
    fi

    return $RETVAL
}

reload() {
    local app_idx=${1##*/}
    local app_name=${2##*/}
    local action_name=${3##*/}
    local module_name=${4##*/}
    local vlive_module_name=${5##*/}

    if  [ -z $module_name ] 
    then
        help "reload"
        exit 0
    fi

    if  [ -z $module_name ] 
    then
        help "reload"
        exit 0
    fi

    case $module_name in 
    *)
         ./controller.sh user RELOAD_CONFIG $app_name$app_idx $vlive_module_name
         ;;
    esac
}

view() {
    local app_idx=${1##*/}
    local app_name=${2##*/}
    local action_name=${3##*/}
    local module_name=${4##*/}
    local vlive_module_name=${5##*/}
    local tag=${6##*/}

    if  [ -z $module_name ] 
    then
        help "view"
        exit 0
    fi

    if  [ -z $module_name ] 
    then
        help "view"
        exit 0
    fi

    case $module_name in
    *)
        ./controller.sh user GET_MODULE_INFO $app_name$app_idx $vlive_module_name $tag
        ;;
    esac
}

status() {
    local app_idx=${1##*/}
    local app_name=${2##*/}
    #local PID=`jps -m | grep $app_name$app_idx | grep -v controller | grep -v grep | awk '{print $1}'`
    #local PID=`ps -ef | grep $app_name$app_idx | grep -v controller | grep -v grep | awk '{print $2}'`
    local PID=`ps -ef | grep java | grep $app_name$app_idx | grep -v controller_user | grep -v grep | awk '{print $2}'`

    if [ -z "$PID" ]
    then
        echo "$app_name$app_idx is not running"
    else
        echo "$app_name$app_idx is running(pid=$PID)..."
    fi

    echo ""
    echo ""
}

restart() {
    echo "----------------------------------"
    stop $1 $2

    sleep 3
    echo "----------------------------------"
    echo "Starting new instance of $2$1"
    start $1 $2
    status $1 $2
}

help_reload(){
    return 0
}

help_view(){
    return 0
}

usage(){
    local shell_name=${0##*/}
    local app_idx=${1##*/}
    local app_name=${2##*/}
    local action_name=${3##*/}
    local module_name=${4##*/}
    local vlive_module_name=${5##*/}

    echo $"Usage: <module_name>.sh {start|stop|restart|reload|view|status|help}"
}

help(){
    usage
}

list_action(){
    echo "start|stop|restart|reload|view|status|help"
}

action_name=${3##*/}
case $action_name in
start)
    start $1 $2
    ;;

stop)
    stop $1 $2
    ;;

reload)
    reload $1 $2 $3 $4 $5
    ;;

restart)
    restart $1 $2
    ;;

view)
    view $1 $2 $3 $4 $5 $6
    ;;

status)
    status $1 $2
    ;;

help)
    help $1 $2 $3 $4
    ;;
*)
    usage
    exit 1
esac

exit $?

