#!/bin/bash
## [rev: c09b031]

##
## Copyright 2020 Andy Dustin
##
## Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except 
## in compliance with the License. You may obtain a copy of the License at
##
## http://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software distributed under the License is 
## distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and limitations under the License.
##

## This script checks for compliance against CIS CentOS Linux 7 Benchmark v2.1.1 2017-01-31 measures
## Each individual standard has it's own function and is forked to the background, allowing for 
## multiple tests to be run in parallel, reducing execution time.

## You can obtain a copy of the CIS Benchmarks from https://www.cisecurity.org/cis-benchmarks/


### Variables ###
## This section defines global variables used in the script
args=$@
count=0
exit_code=0
me=$(basename $0)
result=Fail
state=0
tmp_file_base="/tmp/.cis_audit"
tmp_file="$tmp_file_base-$(date +%y%m%d%H%M%S).output"
started_counter="$tmp_file_base-$(date +%y%m%d%H%M%S).started.counter"
finished_counter="$tmp_file_base-$(date +%y%m%d%H%M%S).finished.counter"
wait_time="0.25"
progress_update_delay="0.1"
max_running_tests=10
debug=False
trace=False
renice_bool=True
renice_value=5
start_time=$(date +%s)
color=True
test_level=0


### Functions ###
## This section defines functions used in the script 
is_test_included() {
    id=$1
    level=$2
    state=0
    
    write_debug "Checking whether to run test $id"
    
    [ -z $level ] && level=$test_level
    
    ## Check if the $level is one we're going to run
    if [ $test_level -ne 0 ]; then
        if [ "$test_level" != "$level" ]; then
            write_debug "Excluding level $level test $id"
            state=1
        fi
    fi
    
    ## Check if there were explicitly included tests
    if [ $(echo "$include" | wc -c ) -gt 3 ]; then
        
        ## Check if the $id is in the included tests
        if [ $(echo " $include " | grep -c " $id ") -gt 0 ]; then
            write_debug "Test $id was explicitly included"
            state=0
        elif [ $(echo " $include " | grep -c " $id\.") -gt 0 ]; then
            write_debug "Test $id is the parent of an included test"
            state=0
        elif [ $(for i in $include; do echo " $id" | grep " $i\."; done | wc -l) -gt 0 ]; then
            write_debug "Test $id is the child of an included test"
            state=0
        elif [ $test_level == 0 ]; then
            write_debug "Excluding test $id (Not found in the include list)"
            state=1
        fi
    fi
    
    ## If this $id was included in the tests check it wasn't then excluded
    if [ $(echo " $exclude " | grep -c " $id ") -gt 0 ]; then
        write_debug "Excluding test $id (Found in the exclude list)"
        state=1
    elif [ $(for i in $exclude; do echo " $id" | grep " $i\."; done | wc -l) -gt 0 ]; then
        write_debug "Excluding test $id (Parent found in the exclude list)"
        state=1
    fi
    
    [ $state -eq 0 ] && write_debug "Including test $id"
    
    return $state
} ## Checks whether to run a particular test or not
get_id() {
    echo $1 | sed -e 's/test_//' -e 's/\.x.*$//'
} ## Returns a prettied id for a calling function
help_text() {
    cat  << EOF |fmt -sw99
This script runs tests on the system to check for compliance against the CIS Ubuntu 18.04 Benchmarks.
No changes are made to system files by this script.

  Options:
EOF

    cat << EOF | column -t -s'|'
||-h,|--help|Prints this help text
|||--debug|Run script with debug output turned on
|||--level (1,2)|Run tests for the specified level only
|||--include "<test_ids>"|Space delimited list of tests to include
|||--exclude "<test_ids>"|Space delimited list of tests to exclude
|||--nice |Lower the CPU priority for test execution. This is the default behaviour.
|||--no-nice|Do not lower CPU priority for test execution. This may make the tests complete faster but at 
||||the cost of putting a higher load on the server. Setting this overrides the --nice option.
|||--no-colour|Disable colouring for STDOUT. Output redirected to a file/pipe is never coloured.

EOF

    cat << EOF

  Examples:
  
    Run with debug enabled:
      $me --debug
      
    Exclude tests from section 1.1 and 1.3.2:
      $me --exclude "1.1 1.3.2"
      
    Include tests only from section 4.1 but exclude tests from section 4.1.1:
      $me --include 4.1 --exclude 4.1.1
    
    Run only level 1 tests
      $me --level 1
    
    Run level 1 tests and include some but not all SELinux questions
      $me --level 1 --include 1.6 --exclude 1.6.1.2

EOF

exit 0

} ## Outputs help text
now() {
    echo $(( $(date +%s%N) / 1000000 ))
} ## Short function to give standardised time for right now (saves updating the date method everywhere)
outputter() {
    write_debug "Formatting and writing results to STDOUT"
    echo
    echo " CIS Ubuntu 18.04 Benchmark v2.1.0 Results "
    echo "---------------------------------------"
    
    if [ -t 1 -a $color == "True" ]; then
        (
            echo "ID,Description,Scoring,Level,Result,Duration"
            echo "--,-----------,-------,-----,------,--------"
            sort -V $tmp_file
        ) | column -t -s , |\
            sed -e $'s/^[0-9]\s.*$/\\n\e[1m&\e[22m/' \
                -e $'s/^[0-9]\.[0-9]\s.*$/\e[1m&\e[22m/' \
                -e $'s/\sFail\s/\e[31m&\e[39m/' \
                -e $'s/\sPass\s/\e[32m&\e[39m/' \
                -e $'s/^.*\sSkipped\s.*$/\e[2m&\e[22m/'
    else
        (
            echo "ID,Description,Scoring,Level,Result,Duration"
            sort -V $tmp_file
        ) | column -t -s , | sed -e '/^[0-9]\ / s/^/\n/'
    fi
    
    tests_total=$(grep -c "Scored" $tmp_file)
    tests_skipped=$(grep -c ",Skipped," $tmp_file)
    tests_ran=$(( $tests_total - $tests_skipped ))
    tests_passed=$(egrep -c ",Pass," $tmp_file)
    tests_failed=$(egrep -c ",Fail," $tmp_file)
    tests_errored=$(egrep -c ",Error," $tmp_file)
    tests_duration=$(( $( date +%s ) - $start_time ))
    
    echo
    echo "Passed $tests_passed of $tests_total tests in $tests_duration seconds ($tests_skipped Skipped, $tests_errored Errors)"
    echo
    
    write_debug "All results written to STDOUT"
} ## Prettily prints the results to the terminal
parse_args() {
    args=$@
    
    ## Call help_text function if -h or --help present
    $(echo $args | egrep -- '-h' &>/dev/null) && help_text
    
    ## Check arguments for --debug
    $(echo $args | grep -- '--debug' &>/dev/null)  &&   debug="True" || debug="False"
    write_debug "Debug enabled"
    
    ## Full noise output
    $(echo $args | grep -- '--trace' &>/dev/null) &&  trace="True" && set -x
    [ $trace == "True" ] && write_debug "Trace enabled"
    
    ## Renice / lower priority of script execution
    $(echo $args | grep -- '--nice' &>/dev/null)  &&   renice_bool="True"
    $(echo $args | grep -- '--no-nice' &>/dev/null)  &&   renice_bool="False"
    [ $renice_bool == "True" ] && write_debug "Tests will run with reduced CPU priority"
    
    ## Disable colourised output
    $(echo $args | egrep -- '--no-color|--no-colour' &>/dev/null)  &&   color="False" || color="True"
    [ $color == "False" ] && write_debug "Coloured output disabled"
    
    ## Check arguments for --exclude
    ## NB: The whitespace at the beginning and end is required for the greps later on
    exclude=" $(echo "$args" | sed -e 's/^.*--exclude //' -e 's/--.*$//') "
    if [ $(echo "$exclude" | wc -c ) -gt 3 ]; then
        write_debug "Exclude list is populated \"$exclude\""
    else
        write_debug "Exclude list is empty"
    fi
    
    ## Check arguments for --include
    ## NB: The whitespace at the beginning and end is required for the greps later on
    include=" $(echo "$args" | sed -e 's/^.*--include //' -e 's/--.*$//') "
    if [ $(echo "$include" | wc -c ) -gt 3 ]; then
        write_debug "Include list is populated \"$include\""
    else
        write_debug "Include list is empty"
    fi
    
    ## Check arguments for --level
    if [ $(echo $args | grep -- '--level 2' &>/dev/null; echo $?) -eq 0 ]; then
        test_level=$(( $test_level + 2 ))
        write_debug "Going to run Level 2 tests"
    fi
    if [ $(echo $args | grep -- '--level 1' &>/dev/null; echo $?) -eq 0 ]; then
        test_level=$(( $test_level + 1 ))
        write_debug "Going to run Level 1 tests"
    fi
    if [ "$test_level" -eq 0 -o "$test_level" -eq 3 ]; then
        test_level=0
        write_debug "Going to run tests from any level"
    fi
    
    
} ## Parse arguments passed in to the script
progress() {
    ## We don't want progress output while we're spewing debug or trace output
    write_debug "Not displaying progress ticker while debug is enabled" && return 0
    [ $trace == "True" ] && return 0
    
    array=(\| \/ \- \\)
    
    while [ "$(running_children)" -gt 1 -o "$(cat $tmp_file_base-stage)" == "LOADING" ]; do 
        started=$( wc -l $started_counter | awk '{print $1}' )
        finished=$( wc -l $finished_counter | awk '{print $1}' )
        running=$(( $started - $finished ))
        
        tick=$(( $tick + 1 ))
        pos=$(( $tick % 4 ))
        char=${array[$pos]}
        
        script_duration="$(date +%T -ud @$(( $(date +%s) - $start_time )))"
        printf "\r[$script_duration] ($char) $finished of $started tests completed " >&2
        
        #ps --ppid $$ >> ~/tmp/cis-audit
        #running_children >> ~/tmp/cis-audit
        #echo Stage: $test_stage >> ~/tmp/cis-audit
        
        sleep $progress_update_delay
    done
    
    ## When all tests have finished, make a final update
    finished=$( wc -l $finished_counter | awk '{print $1}' )
    script_duration="$(date +%T -ud @$(( $(date +%s) - $start_time )))"
    #printf "\r[✓] $finished of $finished tests completed\n" >&2
    printf "\r[$script_duration] (✓) $started of $started tests completed\n" >&2
} ## Prints a pretty progress spinner while running tests
run_test() {
    id=$1
    level=$2
    test=$3
    args=$(echo $@ | awk '{$1 = $2 = $3 = ""; print $0}' | sed 's/^ *//')
    
    if [ $(is_test_included $id $level; echo $?) -eq 0 ]; then
        write_debug "Requesting test $id by calling \"$test $id $args &\""
        
        while [ "$(pgrep -P $$ 2>/dev/null | wc -l)" -ge $max_running_tests ]; do 
            write_debug "There were already max_running_tasks ($max_running_tests) while attempting to start test $id. Pausing for $wait_time seconds"
            sleep $wait_time
        done
        
        write_debug "There were $(( $(pgrep -P $$ 2>&1 | wc -l) - 1 ))/$max_running_tests max_running_tasks when starting test $id."
        
        ## Don't try to thread the script if trace or debug is enabled so it's output is tidier :)
        if [ $trace == "True" ]; then
            $test $id $level $args
            
        elif [ $debug == "True" ]; then
            set -x
            $test $id $level $args
            set +x
            
        else
            $test $id $level $args &
        fi
    fi
    
    return 0
} ## Compares test id against includes / excludes list and returns whether to run test or not
running_children() {
    ## Originally tried using pgrep, but it returned one line even when output was "empty"
    search_terms="PID|ps$|grep$|wc$|sleep$"

    [ $debug == True ] && ps --ppid $$ | egrep -v "$search_terms"
    ps --ppid $$ | egrep -v "$search_terms" | wc -l
} ## Ghetto implementation that returns how many child processes are running
setup() {
    write_debug "Script was started with PID: $$"
    if [ $renice_bool = "True" ]; then
        if [ $renice_value -gt 0 -a $renice_value -le 19 ]; then
            renice_output="$(renice +$renice_value $$)"
            write_debug "Renicing $renice_output"
        fi
    fi
    
    write_debug "Creating tmp files with base $tmp_file_base*"
    cat /dev/null > $tmp_file
    cat /dev/null > $started_counter
    cat /dev/null > $finished_counter
} ## Sets up required files for test
test_start() {
    id=$1
    level=$2
    
    write_debug "Test $id started"
    echo "." >> $started_counter
    write_debug "Progress: $( wc -l $finished_counter | awk '{print $1}' )/$( wc -l $started_counter | awk '{print $1}' ) tests."
    
    now
} ## Prints debug output (when enabled) and returns current time
test_finish() {
    id=$1
    start_time=$2
    duration="$(( $(now) - $start_time ))"
    
    write_debug "Test "$id" completed after "$duration"ms"
    echo "." >> $finished_counter
    write_debug "Progress: $( wc -l $finished_counter | awk '{print $1}' )/$( wc -l $started_counter | awk '{print $1}' ) tests."
    
    echo $duration
} ## Prints debug output (when enabled) and returns duration since $start_time
test_stage() {
    echo $test_stage
} ## Shim to get up to date $test_stage value
tidy_up() {
    [ $debug == "True" ] && opt="-v"
    rm $opt "$tmp_file_base"* 2>/dev/null
} ## Tidys up files created during testing
write_cache() {
    write_debug "Writing to $tmp_file - $@"
    printf "$@\n" >> $tmp_file
} ## Writes additional rows to the output cache
write_debug() {
    [ $debug == "True" ] && printf "[DEBUG] $(date -Ins) $@\n" >&2
} ## Writes debug output to STDERR
write_err() {
    printf "[ERROR] $@\n" >&2
} ## Writes error output to STDERR
write_result() {
    write_debug "Writing result to $tmp_file - $@"
    echo $@ >> $tmp_file
} ## Writes test results to the output cache


### Benchmark Tests ###
## This section defines the benchmark tests that are called by the script

## Tests used in multiple sections
skip_test() {
    ## This function is a blank for any tests too complex to perform 
    ## or that rely too heavily on site policy for definition
    
    id=$1
    level=$2
    description=$( echo $@ | awk '{$1=$2=""; print $0}' | sed 's/^ *//')
    scored="Skipped"
    result=""

    write_result "$id,$description,$scored,$level,$result,$duration"
} 
test_is_enabled() {
    id=$1
    level=$2
    service=$3
    name=$4
    description="Ensure $name service is enabled"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [[ $(systemctl is-enabled $service ) == "enabled" ]] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_is_installed() {
    id=$1
    level=$2
    pkg=$3
    name=$4
    description="Ensure $name is installed"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(dpkg -s $pkg &>/dev/null; echo $?) -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_is_not_installed() {
    id=$1
    level=$2
    pkg=$3
    name=$4
    description="Ensure $name is not installed"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(dpkg -s $pkg &>/dev/null; echo $?) -eq 0 ] || result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_perms() {
    id=$1
    level=$2
    perms=$3
    file=$4
    description="Ensure permissions on $file are configured"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    u=$(echo $perms | cut -c1)
    g=$(echo $perms | cut -c2)
    o=$(echo $perms | cut -c3)
    file_perms="$(stat -L $file | awk '/Access: \(/ {print $2}')"
    file_u=$(echo $file_perms | cut -c3)
    file_g=$(echo $file_perms | cut -c4)
    file_o=$(echo $file_perms | cut -c5)
    
    [ "$(ls -ld $file | awk '{ print $3" "$4 }')" == "root root" ] || state=1
    [[ $file_u -le $u ]] || state=1
    [[ $file_g -le $g ]]|| state=1
    [[ $file_o -le $o ]] || state=1
    
    [ $state -eq 0 ] && result=Pass
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}


## Section 1 - Initial Setup
test_1.1.1.x() {
    id=$1
    level=$2
    filesystem=$3
    description="Ensure mounting of $filesystem is disabled"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(diff -qsZ <(modprobe -n -v $filesystem 2>/dev/null | tail -n1) <(echo "install /bin/true") &>/dev/null; echo $?) -ne 0 ] && state=$(( $state + 1 ))
    [ $(lsmod | grep $filesystem | wc -l) -ne 0 ] && state=$(( $state + 2 ))
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
} 
test_1.1.x-check_partition() {
    id=$1
    level=$2
    partition=$3
    description="Ensure separate partition exists for $partition"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    mount | grep "$partition " &>/dev/null  && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
} 
test_1.1.x-check_fs_opts() {
    id=$1
    level=$2
    partition=$3
    fs_opt=$4
    description="Ensure $fs_opt option set on $partition"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    findmnt -n $partition | grep $fs_opt && result="Pass"
    ## mount | egrep "$partition .*$fs_opt" &>/dev/null  && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
} 
test_1.1.x-check_removable() {
    id=$1
    level=$2
    fs_opt=$3
    description="Ensure $fs_opt option set on removable media partitions"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    ## Note: Only usb media is supported at the moment. Need to investigate what 
    ##  difference a CDROM, etc. can make, but I've set it up ready to add 
    ##  another search term. You're welcome :)
    devices=$(lsblk -pnlS | awk '/usb/ {print $1}')
    filesystems=$(for device in "$devices"; do lsblk -nlp $device | egrep -v '^$device|[SWAP]' | awk '{print $1}'; done)
    
    for filesystem in $filesystems; do
        fs_without_opt=$(mount | grep "$filesystem " | grep -v $fs_opt &>/dev/null | wc -l)
        [ $fs_without_opt -ne 0 ]  && state=1
    done
        
    [ $state -eq 0 ] && result=Pass
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
} 
test_1.1.22() {
    id=$1
    level=$2
    description="Ensure sticky bit is set on all world-writable dirs"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    dirs=$(df --local -P | awk '{if (NR!=1) print $6}' | xargs -I '{}' find '{}' -xdev -type d \( -perm -0002 -a ! -perm -1000 \) 2>/dev/null | wc -l)
    [ $dirs -eq 0 ] && result=Pass
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.1.23() {
    id=$1
    level=$2
    description="Disable Automounting"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    service=$(systemctl | awk '/autofs/ {print $1}')
    [ -n "$service" ] && systemctl is-enabled $service 
    [ $? -ne 0 ]  && result="Pass"
    ## Tests End ##

    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.1.24() {
    id=$1
    level=$2
    filesystem=$3
    description="Disable USB Storage"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(diff -qsZ <(modprobe -n -v $filesystem 2>/dev/null | tail -n1) <(echo "install /bin/true") &>/dev/null; echo $?) -ne 0 ] && state=$(( $state + 1 ))
    [ $(lsmod | grep $filesystem | wc -l) -ne 0 ] && state=$(( $state + 2 ))
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
} 
test_1.2.1() {
    id=$1
    level=$2
    description="Ensure package manager repositories are configured"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    repolist=$(timeout 30 yum repolist 2>/dev/null)
    [ $(echo "$repolist" | egrep -c '^base/7/') -ne 0 -a $(echo "$repolist" | egrep -c '^updates/7/') -ne 0 ] && result="Pass"
    ## Tests End
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.2.2() {
    id=$1
    level=$2
    description="Ensure GPG keys are configured"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(apt-key list| wc -l) -ne 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.3.2() {
    id=$1
    level=$2
    description="Ensure filesystem integrity is regularly checked"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(grep -Rl 'aide' /var/spool/cron/ /etc/crontab /etc/cron* 2>/dev/null | wc -l) -ne 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.4.2() {
    id=$1
    level=$2
    description="Ensure bootloader password is set"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=1
    
    ## Note: This test includes checking /boot/grub2/user.cfg which is not defined in the standard,
    ##  however this file is created by performing the remediation step in the standard so is
    ##  included in the test here as well.
    [ $(grep '"^set superusers"\|"^password"' /boot/grub/grub.cfg | wc -l) -ne 0 ] && state=0
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.4.4() {
    id=$1
    level=$2
    description="Ensure authentication required for single user mode"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    
    [ "$(grep -Eq '^root:\$[0-9]' /etc/shadow || echo "root is locked")" == "" ] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.5.1() {
    id=$1
    level=$2
    description="Ensure XD/NX support is enabled"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##   
    [ $(journalctl | grep 'protection: active' | wc -l) -e 1 ]  && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.5.2() {
    id=$1
    level=$2
    description="Ensure address space layout randomisation (ASLR) is enabled"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ "$(sysctl kernel.randomize_va_space)" == "kernel.randomize_va_space = 2" ] || state=1
    [ "$(grep -Es "^\s*kernel\.randomize_va_space\s*=\s*([0-1]|[3-9]|[1-9][0-9]+)" /etc/sysctl.conf /etc/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /run/sysctl.d/*.conf)" == "" ] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.5.3() {
    id=$1
    level=$2
    description="Ensure prelink is disabled"
    scored="Scored"
    test_start_time=$(test_start $id)
 
    ## Tests Start ##
    state=0

    [ "$(dpkg -s prelink 2>&1 | grep -E '(Status:|not installed)')" == "dpkg-query: package 'prelink' is not installed and no information is available" ] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.5.4() {
    id=$1
    level=$2
    description="Ensure core dumps are restricted"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    str='ExecStart=-/bin/sh -c "/usr/sbin/sulogin; /usr/bin/systemctl --fail --no-block default"'
    
    [ "$(grep -Es '^(\*|\s).*hard.*core.*(\s+#.*)?$' /etc/security/limits.conf /etc/security/limits.d/*)" == "* hard core 0" ] || state=1
    [ "$(sysctl fs.suid_dumpable)" == "fs.suid_dumpable = 0" ] || state=1
    [ "$(grep "fs.suid_dumpable" /etc/sysctl.conf /etc/sysctl.d/* | uniq)" == "fs.suid_dumpable=0" ] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.6.1.1() {
    id=$1
    level=$2
    description="Ensure AppArmor is installed"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    
    [ "$(dpkg -s apparmor | grep -E '(Status:|not installed)')" == "Status: install ok installed" ] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##

    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.6.1.2() {
    id=$1
    level=$2
    description="Ensure AppArmor is enabled in the bootloader configuration [MANUAL]"
    scored="Scored"
    test_start_time=$(test_start $id)
   
    ## Tests Start ##
    state=0

    [[ "$(grep "^\s*linux" /boot/grub/grub.cfg | grep -v "security=apparmor" | grep -v "apparmor=1")" =~ ^[\s]*linux[\s]* ]] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.6.1.3() {
    id=$1
    level=$2
    description="Ensure all AppArmor Profiles are in enforce or complain mode [MANUAL]"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    
    [[ "$(apparmor_status | grep profiles)" =~ ^[\s]*[1-9][0-9]*[\s]+profiles[\s]+are[\s]+loaded ]] || state=1
    [[ "$(apparmor_status | grep profiles)" =~ ^[\s]*0[\s]+processes[\s]+are[\s]+unconfined ]] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.6.1.4() {
    id=$1
    level=$2
    description="Ensure all AppArmor Profiles are enforcing [MANUAL]"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    
    [[ "$(apparmor_status | grep profiles)" =~ ^[\s]*[1-9][0-9]*[\s]+profiles[\s]+are[\s]+loaded ]] || state=1
    [[ "$(apparmor_status | grep profiles)" =~ ^[\s]*0[\s]+processes[\s]+are[\s]+unconfined ]] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.7.1() {
    id=$1
    level=$2
    description="Ensure message of the day is configured properly"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    
    [ $(egrep '(\\v|\\r|\\m|\\s)' /etc/motd | wc -l) -eq 0 ] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##

    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.7.5() {
    id=$1
    level=$2
    description="Ensure remote login warning banner is configured properly"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    
    [ $(wc -l /etc/issue.net | awk '{print $1}') -gt 0 ] || state=1
    [ $(egrep '(\\v|\\r|\\m|\\s)' /etc/issue.net | wc -l) -eq 0 ] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##

    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.7.6() {
    id=$1
    level=$2
    description="Ensure local login warning banner is configured properly"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    
    [ $(wc -l /etc/issue | awk '{print $1}') -gt 0 ] || state=1
    [ $(egrep '(\\v|\\r|\\m|\\s)' /etc/issue | wc -l) -eq 0 ] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##

    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.8.1() {
    id=$1
    level=$2
    description="Ensure GNOME Display Manager is removed "
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    
    [ "$(dpkg -s gdm3 2>&1 | grep -E '(Status:|not installed)')" == "dpkg-query: package 'gdm3' is not installed and no information is available" ] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##

    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.8.2() {
    id=$1
    level=$2
    description=" Ensure GDM login banner is configured"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [[ "$(grep '# banner-message-enable=true' /etc/gdm3/greeter.dconf-defaults | wc -l)" -eq 0 ]] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.8.3() {
    id=$1
    level=$2
    description="Ensure disable-user-list is enabled [MANUAL]"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    
    [ "$(grep -E '^\s*disable-user-list\s*=\s*true\b'  /etc/gdm3/greeter.dconf-defaults )" == "" ] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##

    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.8.4() {
    id=$1
    level=$2
    description="Ensure XDCMP is not enabled"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    
    [ "$(grep -Eis '^\s*Enable\s*=\s*true' /etc/gdm3/custom.conf)" == "" ] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##

    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_1.9() {
    id=$1
    level=$2
    description="Ensure updates are installed [MANUAL]"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(apt check-update --security &>/dev/null; echo $?) -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}


## Section 2 - Services
test_2.1.x() {
    id=$1
    level=$2
    pkg=$3
    service=$4
    port=$5
    name=$( echo $@ | awk '{$1=$2=$3=$4=""; print $0}' | sed 's/^ *//')
    description="Ensure $name are not installed"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
      if [ $(dpkg -s $pkg &>/dev/null; echo $?) -eq 0 ]; then
        [ $(systemctl is-enabled $service) != "disabled" ] && state=1
        [ $(netstat -tupln | egrep ":$port " | wc -l) -ne 0 ] && state=2
    fi
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_2.1.1.1() {
    id=$1
    level=$2
    description="Ensure time synchronisation is in use"
    scored="Not Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(dpkg -s ntp &>/dev/null; echo $?) -eq 0 -o $(dpkg -s chrony &>/dev/null; echo $?) -eq 0 -o $(systemctl is-enabled systemd-timesyncd &>/dev/null; echo $?) ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_2.1.1.2() {
    id=$1
    level=$2
    description="Ensure systemd-timesyncd is configured  [MANUAL]"
    scored="Not Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(systemctl is-enabled systemd-timesyncd &>/dev/null; echo $?) == "enabled" ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_2.1.1.3() {
    id=$1
    level=$2
    description="Ensure chrony is configured"
    scored="Scored"
    test_start_time="$(test_start $id)"
    state=0
    
    ## Tests Start ##
    if [ $( dpkg -s chrony &>/dev/null; echo $? ) -eq 0 ]; then
        egrep "^(server|pool) .*$" /etc/chrony.conf &>/dev/null || state=$(( $state + 1 ))
        
        if [ -f /etc/sysconfig/chronyd ]; then
            [ $( grep -c 'OPTIONS="-u chrony' /etc/sysconfig/chronyd ) -eq 0 ] && state=$(( $state + 2 ))
        else
            state=$(( $state + 4 ))
        fi
        
        [ $state -eq 0 ] && result="Pass"
        duration="$(test_finish $id $test_start_time)ms"
    else
        scored="Skipped"
        result=""
    fi
    ## Tests End ##
    
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_2.1.1.4() {
    id=$1
    level=$2
    description="Ensure ntp is configured"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    if [ $( dpkg -s ntp &>/dev/null; echo $?) -eq 0 ]; then
        grep "^restrict -4 default kod nomodify notrap nopeer noquery" /etc/ntp.conf &>/dev/null || state=1
        grep "^restrict -6 default kod nomodify notrap nopeer noquery" /etc/ntp.conf &>/dev/null || state=2
        [ $(egrep -c "^(server|pool) .*$" /etc/ntp.conf 2>/dev/null) -ge 2 ] || state=4
        [ -f /etc/systemd/system/ntpd.service ] && file="/etc/systemd/system/ntpd.service" || file="/usr/lib/systemd/system/ntpd.service"
        [ $(grep -c 'OPTIONS="-u ntp:ntp' /etc/sysconfig/ntpd) -ne 0 -o $(grep -c 'ExecStart=/usr/sbin/ntpd -u ntp:ntp $OPTIONS' $file) -ne 0 ] || state=8
        
        [ $state -eq 0 ] && result="Pass"
        duration="$(test_finish $id $test_start_time)ms"
    else
        scored="Skipped"
        result=""
    fi
    ## Tests End ##
    
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_2.1.2() {
    id=$1
    level=$2
    description="Ensure X Window System is not installed"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(dpkg -l xserver-xorg* &>/dev/null | wc -l) -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_2.1.7() {
    id=$1
    level=$2
    description="Ensure NFS are not enabled"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(dpkg -l nfs-kernel-server &>/dev/null | wc -l) -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_2.1.15() {
    id=$1
    level=$2
    description="Ensure mail transfer agent is configured for local-only mode"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(ss -lntu | grep -E ':25\s' | grep -E -v '\s(127.0.0.1|::1):25\s' | wc -l) -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_2.1.x() {
    id=$1
    level=$2
    pkg=$3
    service=$4
    port=$5
    name=$( echo $@ | awk '{$1=$2=$3=$4=""; print $0}' | sed 's/^ *//')
    description="Ensure $name is not installed"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    if [ $(dpkg -s $pkg &>/dev/null; echo $?) -eq 0 ]; then
        [ $(systemctl is-enabled $service) != "disabled" ] && state=1
        [ $(netstat -tupln | egrep ":$port " | wc -l) -ne 0 ] && state=2
    fi
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_2.2.x() {
    id=$1
    level=$2
    pkg=$3
    name=$4
    description="Ensure $name is not installed"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(dpkg -s $pkg &>/dev/null; echo $?) -eq 1 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_2.3() {
    id=$1
    level=$2

    description="Ensure nonessential services are removed or masked [MANUAL]"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(lsof -i -P -n | grep -v "(ESTABLISHED)" &>/dev/null; echo $?) -eq 1 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

## Section 3 - Network Configuration
test_3.x-single() {
    id=$1
    level=$2
    protocol=$3
    sysctl=$4
    val=$5
    description=$( echo $@ | awk '{$1=$2=$3=$4=$5=""; print $0}' | sed 's/^ *//')
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ "$(sysctl net.$protocol.$sysctl)" == "net.$protocol.$sysctl = $val" ] && result="Pass"
    [ "$(grep "net.$protocol.$sysctl" /etc/sysctl.conf /etc/sysctl.d/*.conf | sed -e 's/^.*://' -e 's/\s//g' | uniq)" == "net.$protocol.$sysctl=$val" ] || state=1
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_3.x-double() {
    id=$1
    level=$2
    protocol=$3
    sysctl=$4
    val=$5
    description=$( echo $@ | awk '{$1=$2=$3=$4=$5=""; print $0}' | sed 's/^ *//')
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ "$(sysctl net.$protocol.conf.all.$sysctl)" == "net.$protocol.conf.all.$sysctl = $val" ] || state=1
    [ "$(grep "net.$protocol.conf.all.$sysctl" /etc/sysctl.conf /etc/sysctl.d/*.conf | sed -e 's/^.*://' -e 's/\s//g' | uniq)" == "net.$protocol.conf.all.$sysctl=$val" ] || state=2
    
    [ "$(sysctl net.$protocol.conf.default.$sysctl)" == "net.$protocol.conf.default.$sysctl = $val" ] || state=4
    [ "$(grep "net.$protocol.conf.default.$sysctl" /etc/sysctl.conf /etc/sysctl.d/*.conf | sed -e 's/^.*://' -e 's/\s//g' | uniq)" == "net.$protocol.conf.default.$sysctl=$val" ] || state=8
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_3.1.1() {
    id=$1
    level=$2
    description="Disable IPv6"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    state=1
    [ $(modprobe -c | grep -c 'options ipv6 disable=1') -eq 1 ] && state=0

    linux_lines=$(grep -c "\s+linux" /boot/grub/grub.cfg)
    audit_lines=$(grep -c "\s+linux.*ipv6.disable=1" /boot/grub/grub.cfg)
    [ $linux_lines -eq $audit_lines ] && state=0

    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_3.1.2() {
    id=$1
    level=$2
    description="Ensure wireless interfaces are disabled"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
        
    [ "$(if command -v nmcli >/dev/null 2>&1 ; then nmcli radio all | grep -Eq '\s*\S+\s+disabled\s+\S+\s+disabled\b' && echo "Wireless is not enabled" || nmcli radio all; elif [ -n "$(find /sys/class/net/*/ -type d -name wireless)" ]; then t=0; drivers=$(for driverdir in $(find /sys/class/net/*/ -type d -name wireless | xargs -0 dirname); do basename "$(readlink -f "$driverdir"/device/driver)";done | sort -u); for dm in $drivers; do if grep -Eq "^\s*install\s+$dm\s+/bin/(true|false)" /etc/modprobe.d/*.conf; then /bin/true; else echo "$dm is not disabled"; t=1; fi; done; [[ $t -eq 0 ]] && echo "Wireless is not enabled"; else echo "Wireless is not enabled"; fi)" == "Wireless is not enabled" ] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_3.4.x() {
    id=$1
    level=$2
    protocol=$3
    name=$4
    description="Ensure $name is disabled"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(diff -qsZ <(modprobe -n -v $protocol 2>/dev/null | tail -n1) <(echo "install /bin/true") &>/dev/null; echo $?) -ne 0 ] && state=1
    [ $(lsmod | grep $protocol | wc -l) -ne 0 ] && state=2
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
} 
test_3.5.1.2() {
    id=$1
    level=$2
    description="Ensure iptables-persistent is not installed with ufw"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
        
    [ "$(dpkg-query -s iptables-persistent 2>&1 | grep -E '(Status:|not installed)')" == "dpkg-query: package 'iptables-persistent' is not installed and no information is available" ] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_3.5.1.3() {
    id=$1
    level=$2
    description="Ensure ufw service is enabled"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(systemctl is-enabled ufw) == "enabled" ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_3.5.1.4() {
    id=$1
    level=$2
    description="Ensure loopback traffic is configured"
    scored="Scored"
    test_start_time=$(test_start $id)
    state=0

    ## Tests Start ##
   [ "$(/usr/sbin/ufw status verbose 2>&1 | grep "Anywhere[\s]+DENY[\s]+IN[\s]+127.0.0.0\/8")" == "Anywhere DENY IN 127.0.0.0/8" ] || state=1
   [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
} 
test_3.5.1.5() {
    id=$1
    level=$2
    description="Ensure ufw outbound connections are configured [MANUAL]"
    scored="Scored"
    test_start_time=$(test_start $id)
    state=0

    ## Tests Start ##
   [ "$(ufw status numbered 2>&1 | grep "Anywhere[\s]+DENY[\s]+IN[\s]+127.0.0.0\/8")" == "Anywhere DENY IN 127.0.0.0/8" ] || state=1
   [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
} 
test_3.5.1.6() {
    id=$1
    level=$2
    description="Ensure ufw firewall rules exist for all open ports [MANUAL]"
    scored="Scored"
    test_start_time=$(test_start $id)
    state=0

    ## Tests Start ##
   [ "$(/bin/ss -4tuln; /usr/sbin/ufw status 2>&1 | grep "Anywhere[\s]+DENY[\s]+IN[\s]+127.0.0.0\/8")" == "Anywhere DENY IN 127.0.0.0/8" ] || state=1
   [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
} 
test_3.5.1.7() {
    id=$1
    level=$2
    description="Ensure ufw default deny firewall policy"
    scored="Scored"
    
    ## Tests Start ##
   [ $(ufw status verbose | grep "ufw default deny [a-z]+" | wc -l) -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
} 
test_3.5.2.1() {
    id=$1
    level=$2
    description="Ensure nftables is installed "
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
        
    [ "$(dpkg-query -s nftables &>/dev/null | wc -l)" -eq 1 ] && result="Pass"

    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_3.5.2.2() {
    id=$1
    level=$2
    description="Ensure ufw is uninstalled or disabled with nftables [MANUAL] "
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    [ "$(ufw status | grep 'Status: inactive')" == "Status: inactive" ] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_3.5.2.3() {
    id=$1
    level=$2
    description="Ensure iptables are flushed with nftable [MANUAL] "
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    [ "$(ufw status | grep 'Status: inactive')" == "Status: inactive" ] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_3.5.2.4() {
    id=$1
    level=$2
    description="Ensure a nftables table exists"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    [ "$(nft list tables | grep 'table inet filter')" == "table inet filter" ] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_3.5.2.5() {
    id=$1
    level=$2
    description="Ensure nftables base chains exist "
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(nft list ruleset | grep -c 'hook input') -eq 1 ] || state=1
    [ $(nft list ruleset | grep -c 'hook forward') -eq 1 ] || state=2
    [ $(nft list ruleset | grep -c 'hook output') -eq 1 ] || state=4
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_3.5.2.6() {
    id=$1
    level=$2
    description="Ensure nftables loopback traffic is configured "
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(nft list ruleset | awk '/hook input/,/}/' | grep -c 'iif "lo" accept') -eq 1 ] || state=1
    [ $(nft list ruleset | awk '/hook input/,/}/' | grep -c 'ip saddr') -eq 1 ] || state=2
    [ $(nft list ruleset | awk '/hook input/,/}/' | grep -c 'ip6 saddr') -eq 1 ] || state=4
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_3.5.2.7() {
    id=$1
    level=$2
    description="Ensure nftables outbound and established connections are configured [MANUAL]"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(nft list ruleset | awk '/hook input/,/}/' | grep -E 'ip protocol (tcp|udp|icmp) ct state' | wc -l) -eq 1 ] || state=1
    [ $(nft list ruleset | awk '/hook output/,/}/' | grep -E 'ip protocol (tcp|udp|icmp) ct state' | wc -l) -eq 1 ] || state=2
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_3.5.2.8() {
    id=$1
    level=$2
    description="Ensure nftables default deny firewall policy [MANUAL]"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(nft list ruleset | grep ' hook input priority 0; policy drop' | wc -l) -eq 1 ] || state=1
    [ $(nft list ruleset | grep ' hook forward priority 0; policy drop' | wc -l) -eq 1 ] || state=2
    [ $(nft list ruleset | grep ' hook output priority 0; policy drop' | wc -l) -eq 1 ] || state=4
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_3.5.2.9() {
    id=$1
    level=$2
    description="Ensure nftables service is enabled"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [[ $(systemctl is-enabled nftables) == "enabled" ]] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_3.5.2.10() {
    id=$1
    level=$2
    description="Ensure nftables rules are permanent "
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(grep 'include "/etc/nftables.rules"' /etc/nftables.conf | wc -l) -eq 1 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_3.5.3.1.1() {
    id=$1
    level=$2
    description="Ensure iptables packages are installed"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(dpkg -s iptables 2>&1 | grep -c 'install ok installed') -eq 1 ] || state=1
    [ $(dpkg -s iptables-persistent 2>&1 | grep -c 'install ok installed') -eq 1 ] || state=2
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_3.5.3.1.2() {
    id=$1
    level=$2
    description="Ensure nftables is not installed with iptables "
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(dpkg -s nfstables &>/dev/null; echo $?) -eq 0 ]   
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_3.5.3.1.3() {
    id=$1
    level=$2
    description=" Ensure ufw is uninstalled or disabled with iptables [MANUAL]"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(dpkg-query -s ufw | grep 'package 'ufw' is not installed and no information is available' | wc -l) -eq 1 ] || state=1
    [ $(ufw status | grep 'Status: inactive' | wc -l) -eq 1 ] || state=2
    [ $(systemctl is-enabled ufw | grep 'masked' | wc -l) -eq 1 ] || state=4
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_3.5.3.2.1() {
    id=$1
    level=$2
    description=" Ensure iptables default deny firewall policy [MANUAL]"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(iptables --list | /bin/grep -c 'Chain INPUT (policy DROP)') -eq 1 ] || state=1
    [ $(iptables --list | /bin/grep -c 'Chain FORWARD (policy DROP)') -eq 1 ] || state=2
    [ $(iptables --list | /bin/grep -c 'Chain OUTPUT (policy DROP)') -eq 1 ] || state=4
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_3.5.3.2.2() {
    id=$1
    level=$2
    description=" Ensure iptables loopback traffic is configured  [MANUAL]"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(iptables -L INPUT -v -n | wc -l) -eq 4 ] || state=1
    [ $(iptables -L OUTPUT -v -n | wc -l) -eq 3 ] || state=2
        [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_3.5.3.2.4() {
    id=$1
    level=$2
    description="Ensure iptables firewall rules exist for all open ports [MANUAL]"
    scored="Scored"
    test_start_time=$(test_start $id)
    state=0

    ## Tests Start ##
   [ "$(/bin/ss -4tuln; /usr/sbin/ufw status 2>&1 | grep "Anywhere[\s]+DENY[\s]+IN[\s]+127.0.0.0\/8")" == "Anywhere DENY IN 127.0.0.0/8" ] || state=1
   [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
} 

test_3.5.3.3.1() {
    id=$1
    level=$2
    description=" Ensure ip6tables default deny firewall policy [MANUAL]"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(ip6tables --list | /bin/grep -c 'Chain INPUT (policy DROP)') -eq 1 ] || state=1
    [ $(ip6tables --list | /bin/grep -c 'Chain FORWARD (policy DROP)') -eq 1 ] || state=2
    [ $(ip6tables --list | /bin/grep -c 'Chain OUTPUT (policy DROP)') -eq 1 ] || state=4
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_3.5.3.3.2() {
    id=$1
    level=$2
    description=" Ensure ip6tables loopback traffic is configured  [MANUAL]"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $(ip6tables -L INPUT -v -n | wc -l) -eq 4 ] || state=1
    [ $(ip6tables -L OUTPUT -v -n | wc -l) -eq 3 ] || state=2
        [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_3.5.3.3.4() {
    id=$1
    level=$2
    description="Ensure ip6tables firewall rules exist for all open ports [MANUAL]"
    scored="Scored"
    test_start_time=$(test_start $id)
    state=0

    ## Tests Start ##
   [ "$(/bin/ss -4tuln; /usr/sbin/ufw status 2>&1 | grep "Anywhere[\s]+DENY[\s]+IN[\s]+127.0.0.0\/8")" == "Anywhere DENY IN 127.0.0.0/8" ] || state=1
   [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
} 

## Section 4 - Logging and Auditing
test_4.1.1.3() {
    id=$1
    level=$2
    description="Ensure auditing for processes that start prior to auditd is enabled"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
        [[ $(grep "^\s*linux" /boot/grub/grub.cfg | grep "audit=1" | wc -l) -eq 1 ]] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_4.1.1.4() {
    id=$1
    level=$2
    description="Ensure audit_backlog_limit is sufficient "
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
        [[ $(grep "^\s*linux" /boot/grub/grub.cfg | grep "audit_backlog_limit=" | wc -l) -eq 1 ]] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_4.1.2.1() {
    id=$1
    level=$2
    description="Ensure audit log storage size is configured"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
        [[ $(egrep -c '^max_log_file = [0-9]*' /etc/audit/auditd.conf) -eq 1 ]] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_4.1.2.2() {
    id=$1
    level=$2
    description="Ensure audit logs are not automatically deleted"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
        [[ $( grep -c '^max_log_file_action = keep_logs' /etc/audit/auditd.conf) -eq 1 ]] && result="Pass"
   ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_4.1.2.3() {
    id=$1
    level=$2
    description="Ensure system is disabled when audit logs are full"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
        [[ $( grep -c '^space_left_action = email' /etc/audit/auditd.conf) -eq 1 ]] || state=1
        [[ $( grep -c '^action_mail_acct = root' /etc/audit/auditd.conf) -eq 1 ]] || state=2
        [[ $( grep -c '^admin_space_left_action = halt' /etc/audit/auditd.conf) -eq 1 ]] || state=4
        [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_4.1.2() {
    id=$1
    level=$2
    description="Ensure auditd service is enabled"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ $( systemd is-enabled auditd) == "enabled" ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_4.1.3() {
    id=$1
    level=$2
    description="Ensure events that modify date and time information are collected"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    search_term=time-change
    expected='-a always,exit -F arch=b64 -S adjtimex,settimeofday -F key=time-change\n
        -a always,exit -F arch=b32 -S stime,settimeofday,adjtimex -F key=time-change\n
        -a always,exit -F arch=b64 -S clock_settime -F key=time-change\n
        -a always,exit -F arch=b32 -S clock_settime -F key=time-change\n
        -w /etc/localtime -p wa -k time-change'
        
    diff <(echo -e $expected | sed 's/^\s*//') <(auditctl -l | grep $search_term) &>/dev/null && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_4.1.4() {
    id=$1
    level=$2
    description="Ensure events that modify user/group information are collected"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    search_term="identity"
    expected='-w /etc/group -p wa -k identity\n
        -w /etc/passwd -p wa -k identity\n
        -w /etc/gshadow -p wa -k identity\n
        -w /etc/shadow -p wa -k identity\n
        -w /etc/security/opasswd -p wa -k identity'
        
    diff <(echo -e $expected | sed 's/^\s*//') <(auditctl -l | grep $search_term) &>/dev/null && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_4.1.5() {
    id=$1
    level=$2
    description="Ensure events that modify the system's network environment are collected"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    
    ## Note: Auditctl performs some translation on the rules entered as per the standard, 
    ##  so what we end up testing for here is not what is specified in the standard, but 
    ##  is correct when used in real-world situations.
    search_term="system-locale"
    expected='-a always,exit -F arch=b64 -S sethostname,setdomainname -F key=system-locale\n
        -a always,exit -F arch=b32 -S sethostname,setdomainname -F key=system-locale\n
        -w /etc/issue -p wa -k system-locale\n
        -w /etc/issue.net -p wa -k system-locale\n
        -w /etc/hosts -p wa -k system-locale\n
        -w /etc/sysconfig/network -p wa -k system-locale\n
        -w /etc/sysconfig/network-scripts -p wa -k system-locale'
    
    diff <(echo -e $expected | sed 's/^\s*//') <(auditctl -l | grep $search_term) &>/dev/null && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_4.1.6() {
    id=$1
    level=$2
    description="Ensure events that modify the system's Mandatory Access Controls are collected"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    search_term="MAC-policy"
    expected='-w /etc/selinux -p wa -k MAC-policy\n
        -w /usr/share/selinux -p wa -k MAC-policy'
    
    diff <(echo -e $expected | sed 's/^\s*//') <(auditctl -l | grep $search_term) &>/dev/null && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_4.1.7() {
    id=$1
    level=$2
    description="Ensure login and logout events are collected"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    search_term="logins"
    expected='-w /var/log/lastlog -p wa -k logins\n
        -w /var/run/faillock -p wa -k logins\n
        -w /var/log/wtmp -p wa -k logins\n
        -w /var/log/btmp -p wa -k logins'
    
    diff <(echo -e $expected | sed 's/^\s*//') <(auditctl -l | grep $search_term) &>/dev/null && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_4.1.8() {
    id=$1
    level=$2
    description="Ensure session initiation information is collected"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    search_term="session"
    expected='-w /var/run/utmp -p wa -k session'
    
    diff <(echo -e $expected | sed 's/^\s*//') <(auditctl -l | grep $search_term) &>/dev/null && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_4.1.9() {
    id=$1
    level=$2
    description="Ensure discretionary access control permission modification events are collected"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    search_term="perm_mod"
    expected='-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=-1 -F key=perm_mod\n
        -a always,exit -F arch=b32 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=-1 -F key=perm_mod\n
        -a always,exit -F arch=b64 -S chown,fchown,lchown,fchownat -F auid>=1000 -F auid!=-1 -F key=perm_mod\n
        -a always,exit -F arch=b32 -S lchown,fchown,chown,fchownat -F auid>=1000 -F auid!=-1 -F key=perm_mod\n
        -a always,exit -F arch=b64 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=-1 -F key=perm_mod\n
        -a always,exit -F arch=b32 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=-1 -F key=perm_mod'
    
    diff <(echo -e $expected | sed 's/^\s*//') <(auditctl -l | grep $search_term) &>/dev/null && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_4.1.10() {
    id=$1
    level=$2
    description="Ensure unsuccessful unauthorised file access attempts are collected"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    search_term="access"
    expected='-a always,exit -F arch=b64 -S open,truncate,ftruncate,creat,openat -F exit=-EACCES -F auid>=1000 -F auid!=-1 -F key=access\n
        -a always,exit -F arch=b32 -S open,creat,truncate,ftruncate,openat -F exit=-EACCES -F auid>=1000 -F auid!=-1 -F key=access\n
        -a always,exit -F arch=b64 -S open,truncate,ftruncate,creat,openat -F exit=-EPERM -F auid>=1000 -F auid!=-1 -F key=access\n
        -a always,exit -F arch=b32 -S open,creat,truncate,ftruncate,openat -F exit=-EPERM -F auid>=1000 -F auid!=-1 -F key=access'
    
    diff <(echo -e $expected | sed 's/^\s*//') <(auditctl -l | grep $search_term) &>/dev/null && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_4.1.12() {
    id=$1
    level=$2
    description="Ensure successful filesystem mounts are collected"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    search_term="mounts"
    expected='-a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=-1 -F key=mounts\n
        -a always,exit -F arch=b32 -S mount -F auid>=1000 -F auid!=-1 -F key=mounts'
    
    diff <(echo -e $expected | sed 's/^\s*//') <(auditctl -l | grep $search_term) &>/dev/null && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_4.1.13() {
    id=$1
    level=$2
    description="Ensure file deletion events by users are collected"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    search_term="key=delete"
    expected='-a always,exit -F arch=b64 -S rename,unlink,unlinkat,renameat -F auid>=1000 -F auid!=-1 -F key=delete\n
        -a always,exit -F arch=b32 -S unlink,rename,unlinkat,renameat -F auid>=1000 -F auid!=-1 -F key=delete'
    
    diff <(echo -e $expected | sed 's/^\s*//') <(auditctl -l | grep $search_term) &>/dev/null && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_4.1.14() {
    id=$1
    level=$2
    description="Ensure changes to system administration scope (sudoers) is collected"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    search_term="scope"
    expected='-w /etc/sudoers -p wa -k scope\n
        -w /etc/sudoers.d -p wa -k scope'
    
    diff <(echo -e $expected | sed 's/^\s*//') <(auditctl -l | grep $search_term) &>/dev/null && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_4.1.15() {
    id=$1
    level=$2
    description="Ensure system administrator command executions (sudo) are collected"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    search_term="actions"
    expected='/etc/audit/rules.d/cis.rules:-a exit,always -F arch=b32 -C euid!=uid -F
euid=0 -Fauid>=1000 -F auid!=4294967295 -S execve -k actions\n
    -a always,exit -F arch=b32 -S execve -C uid!=euid -F euid=0 -F auid>=1000 -F auid!=-1 -F key=actions\n
    -a exit,always -F arch=b64 -C euid!=uid -F auid!=4294967295 -S execve -k actions\n
    -a exit,always -F arch=b32 -C euid!=uid -F auid!=4294967295 -S execve -k actions\n
    -a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -F auid>=1000 -F auid!=-1 -F key=actions\n
    -a always,exit -F arch=b32 -S execve -C uid!=euid -F euid=0 -F auid>=1000 -F auid!=-1 -F key=actions'
    
    diff <(echo -e $expected | sed 's/^\s*//') <(auditctl -l | grep $search_term) &>/dev/null && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_4.1.16() {
    id=$1
    level=$2
    description="Ensure kernel module loading and unloading is collected"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    search_term="modules"
    expected='-w /sbin/insmod -p x -k modules\n
        -w /sbin/rmmod -p x -k modules\n
        -w /sbin/modprobe -p x -k modules\n
        -a always,exit -F arch=b64 -S init_module,delete_module -F key=modules'
    
    diff <(echo -e $expected | sed 's/^\s*//') <(auditctl -l | grep $search_term) &>/dev/null && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_4.1.17() {
    id=$1
    level=$2
    description="Ensure the audit configuration is immutable"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [ "$(grep "^\s*[^#]" /etc/audit/audit.rules | tail -n1 | sed 's/^\s*//')" == "-e 2" ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_4.2.1.4() {
    id=$1
    level=$2
    description="Ensure rsyslog default file permissions configured"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [[ "$(grep ^\s*\$FileCreateMode /etc/rsyslog.conf /etc/rsyslog.d/*.conf)" == "$FileCreateMode 0640" ]] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_4.2.1.5() {
    id=$1
    level=$2
    description="Ensure rsyslog is configured to send logs to a remote host"
    scored="Not Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    [[ "$(/bin/grep -E '(^\s*([^#]+\s+)?action\(([^#]+\s+)?\btarget=\"?[^#"]+\"?\b|^[^#]*\s*\S+\s+@)' /etc/rsyslog.conf /etc/rsyslog.d/*.conf | /usr/bin/awk '{print} END {if (NR == 0) print "fail"}')" != "fail" ]] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_4.2.2.1() {
    id=$1
    level=$2
    description="Ensure journald is configured to send logs to rsyslog"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    
    [[ "$(grep '#ForwardToSyslog=yes' /etc/systemd/journald.conf | wc -l)" != 1 ]] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_4.2.2.2() {
    id=$1
    level=$2
    description="Ensure journald is configured to compress large log files"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    
    [[ "$(grep '#Compress=yes' /etc/systemd/journald.conf | wc -l)" != 1 ]] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_4.2.2.3() {
    id=$1
    level=$2
    description="Ensure journald is configured to write logfiles to persistent disk"
    scored="Scored"
    test_start_time=$(test_start $id)
    
    ## Tests Start ##
    state=0
    
    [[ "$(grep '#Storage=persistent' /etc/systemd/journald.conf | wc -l)" != 1 ]] || state=1
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_4.2.3() {
    id=$1
    level=$2
    description="Ensure permissions on log files are configured"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(find /var/log -type f -perm /027 2>/dev/null | wc -l) -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_4.4() {
    id=$1
    level=$2
    description="Ensure permissions on log files are configured"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(fgrep -Es "^\s*create\s+\S+" /etc/logrotate.conf /etc/logrotate.d/* | grep -E -v "\s(0)?[0-6][04]0\s" | wc -l) -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}


## Section 5 - Access, Authentication and Authorization
test_5.1.8() {
    id=$1
    level=$2
    description="Ensure cron is restricted to authorized users"
    scored="Scored"
    test_start_time="$(test_start $id)"
    state=0
    
    ## Tests Start ##
    [ -f /etc/cron.deny ] && state=$(( $state + 2 ))
    if [-f /etc/cron.allow ]; then
        [ "$(stat /etc/cron.allow 2>/dev/null| grep -m1 ^Access:)" == 'Access: (0600/-rw-------)  Uid: (    0/    root)   Gid: (    0/    root)' ] || state=$(( $state + 8 ))
    else
        state=$(( $state + 16 ))
    fi
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.1.9() {
    id=$1
    level=$2
    description="Ensure at is restricted to authorized users"
    scored="Scored"
    test_start_time="$(test_start $id)"
    state=0
    
    ## Tests Start ##
    [ -f /etc/at.deny ] && state=$(( $state + 1 ))
    if [ -f /etc/at.allow ]; then
        [ "$(stat /etc/at.allow 2>/dev/null| grep -m1 ^Access:)" == 'Access: (0600/-rw-------)  Uid: (    0/    root)   Gid: (    0/    root)' ] || state=$(( $state + 4 ))
    else
        state=$(( $state + 16 ))
    fi
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.2.2() {
    id=$1
    level=$2
    description="Ensure sudo commands use pty"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [[ "$(grep -s -E '^[[:space:]]*Defaults[[:space:]]+([^#]+,[[:space:]]*)?use_pty' /etc/sudoers /etc/sudoers.d/* | /usr/bin/awk '{print} END {if (NR != 0) print "pass" ; else print "fail"}')" == "pass" ]] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.2.3() {
    id=$1
    level=$2
    description="Ensure sudo log file exists"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [[ "$(grep -s -E '^[[:space:]]*Defaults[[:space:]]+([^#]+,[[:space:]]*)?logfile=' /etc/sudoers /etc/sudoers.d/* | /usr/bin/awk '{print} END {if (NR != 0) print "pass" ; else print "fail"}')" == "pass" ]] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.2() {
    id=$1
    level=$2
    description="Ensure permissions on SSH private host key files are configured"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(find /etc/ssh -xdev -type f -name 'ssh_host_*_key' -exec stat {} \; | grep -E '(File: |0600)' | wc -l) -eq 8 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.3() {
    id=$1
    level=$2
    description="Ensure permissions on SSH public host key files are configured"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(find /etc/ssh -xdev -type f -name 'ssh_host_*_key.pub' -exec stat {} \; | grep -E '(File:|0644)' | wc -l) -eq 8 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.4() {
    id=$1
    level=$2
    description="Ensure SSH access is limited"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(find /etc/ssh -xdev -type f -name 'ssh_host_*_key.pub' -exec stat {} \; | grep -E '(File:|0644)' | wc -l) -eq 8 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.5() {
    id=$1
    level=$2
    description="Ensure SSH LogLevel is appropriate"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep -c 'loglevel INFO') -eq 1 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.6() {
    id=$1
    level=$2
    description="Ensure SSH X11 forwarding is disabled"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep -c 'x11forwarding no') -eq 1 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.7() {
    id=$1
    level=$2
    description="Ensure SSH MaxAuthTries is set to 4 or less"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep -c '[Mm]ax[Aa]uth[Tt]ries [0-4]') -eq 1 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.8() {
    id=$1
    level=$2
    description="Ensure SSH IgnoreRhosts is enabled"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep -c '[Ii]gnore[Rr]hosts yes') -eq 1 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.9() {
    id=$1
    level=$2
    description="Ensure SSH HostbasedAuthentication is disabled"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep -c '[Hh]ost[Bb]ased[Aa]uthentication no') -eq 1 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.10() {
    id=$1
    level=$2
    description="Ensure SSH root login is disabled"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep -c '[Pp]ermit[Rr]oot[Ll]ogin no') -eq 1 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.11() {
    id=$1
    level=$2
    description="Ensure SSH PermitEmptyPasswords is disabled "
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep -c '[Pp]ermit[Ee]mpty[Pp]asswords no') -eq 1 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.12() {
    id=$1
    level=$2
    description="Ensure SSH PermitUserEnvironment is disabled"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep -c '[Pp]ermit[Uu]ser[Ee]nvironment no') -eq 1 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.13() {
    id=$1
    level=$2
    description="Ensure SSH PermitUserEnvironment is disabled"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(grep -c -Ei '^\s*ciphers\s+([^#]+,)?(3des-cbc|aes128-cbc|aes192-cbc|aes256-cbc|arcfour|arcfour128|arcfour256|blowfish-cbc|cast128-cbc|rijndaelcbc@lysator.liu.se)\b' /etc/ssh/sshd_config) -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.14() {
    id=$1
    level=$2
    description="Ensure only strong MAC algorithms are used"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    state=0
    good_macs="shmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com"
    macs=$(awk '/^MACs / {print $2}' /etc/ssh/sshd_config | sed 's/,/ /g')

    ## Tests Start ##
    for mac in $macs; do
        if [ $( echo "$good_macs" | grep -c "$mac") -eq 1 ]; then
            [ "$state" -eq 0 ] && state=1
            write_debug "5.2.11 - $mac is an approved MAC"
        else
            state=2
            write_debug "5.2.11 - $mac is NOT an approved MAC ($good_macs)"
        fi
    done
    
    case $state in
        1 ) result="Pass";;
        2 ) result="Fail";;
        * ) result="Error"
            write_debug "5.2.11 - Something went wrong" ;;
    esac

    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.15() {
    id=$1
    level=$2
    description="Ensure only strong Key Exchange algorithms are used"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(grep -c -Ei '^\s*kexalgorithms\s+([^#]+,)?(diffie-hellman-group1-sha1|diffiehellman-group14-sha1|diffie-hellman-group-exchange-sha1)\b' /etc/ssh/sshd_config) -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.16() {
    id=$1
    level=$2
    description="Ensure SSH Idle Timeout Interval is configured"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    if [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep -c '[Cc]lient[Aa]live') -eq 2 ]; then
        [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep '[Cc]lient[Aa]live[Cc]ountmax' | awk '{print $2}') -le 900 ] || state=1
        [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep '[Cc]lient[Aa]live[Ii]nterval' | awk '{print $2}') -eq 0 ] || state=1
    else
        state=1
    fi
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.17() {
    id=$1
    level=$2
    description="Ensure SSH LoginGraceTime is set to one minute or less"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    if [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep -c '[Ll]ogin[Gg]race[Tt]ime') -eq 1 ]; then
        [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep '[Ll]ogin[Gg]race[Tt]ime' | awk '{print $2}') -le 60 ] && result="Pass"
    else
        state=1
    fi
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.18() {
    id=$1
    level=$2
    description="Ensure SSH warning banner is configured"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep -c '[Bb]anner /etc/issue.net') -eq 1 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.19() {
    id=$1
    level=$2
    description="Ensure SSH PAM is enabled"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep -i -c '[Uu]se[Pp]am yes') -eq 1 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.20() {
    id=$1
    level=$2
    description="Ensure SSH AllowTcpForwarding is disabled"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep -i -c '[Aa]llow[Tt][Cc][Pp][Ff]orwarding no') -eq 1 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.21() {
    id=$1
    level=$2
    description="Ensure SSH MaxStartups is configured"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [[ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep -i '[Mm]ax[Ss]tartups 10:30:60') -eq 1 ]] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.22() {
    id=$1
    level=$2
    description="Ensure SSH MaxSessions is limited"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(sshd -T -C user=root -C host="$(hostname)" -C addr="$(grep $(hostname) /etc/hosts | awk '{print $1}')" | grep -i '[Mm]ax[Ss]essions' | awk '{print $2}') -le 10 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.3.1() {
    id=$1
    level=$2
    description="Ensure password creation requirements are configured"
    scored="Scored"
    test_start_time="$(test_start $id)"
    state=0
    
    ## Tests Start ##
    ## Notes: Per the standard - Additional module options may be set, recommendation 
    ##   requirements only cover including try_first_pass and minlen set to 14 or more.
    [ "$(grep '^\s*minclass\s*' /etc/security/pwquality.conf | awk '{print $3}')" -eq 4 ] || state=$(( $state + 1 ))
    [ "$(grep -c -E '^\s*password\s+(requisite|required)\s+pam_pwquality\.so\s+(\S+\s+)*retry=[1-3]\s*(\s+\S+\s*)*(\s+#.*)?$' /etc/pam.d/common-password)" -eq 1 ] || state=$(( $state + 2 ))

    minlen="$(awk '/^(\s+)?minlen = / {print $3}' /etc/security/pwquality.conf)"
    minlen=${minlen:=0}
    [ "$minlen" -ge 14 ] || state=$(( $state + 4 ))

    [ $state -eq 0 ]&& result="Pass"
    write_debug "Test $id finished with end state of $state"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"

}
test_5.4.3() {
    id=$1
    level=$2
    description="Ensure password reuse is limited"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
     ## Tests Start ##
    [ $(grep -c -E '^\s*password\s+required\s+pam_pwhistory\.so\s+([^#]+\s+)?remember=([5-9]|[1-9][0-9]+)\b' /etc/pam.d/common-password) -eq 1 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_5.4.4() {
    id=$1
    level=$2
    description="Ensure password hashing algorithm is SHA-512"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
     ## Tests Start ##
    [ $(grep -c -E '^\s*password\s+(\[success=1\s+default=ignore\]|required)\s+pam_unix\.so\s+([^#]+\s+)?sha512\b' /etc/pam.d/common-password) -eq 1 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.5.1.1() {
    id=$1
    level=$2
    description="Ensure minimum days between password changes is configured"
    scored="Scored"
    test_start_time="$(test_start $id)"
    state=0
    
    ## Tests Start ##
    file="/etc/login.defs"
    days=1
    if [ -s $file ]; then
        if [ $(grep -c "^PASS_MIN_DAYS" $file) -eq 1 ]; then
            [ $(awk '/^PASS_MIN_DAYS/ {print $2}' $file) -le $days ] || state=$(( $state + 1))
        fi
    fi
    
    for i in $(egrep ^[^:]+:[^\!*] /etc/shadow | cut -d: -f1); do 
        [ $(chage --list $i 2>/dev/null | awk '/Minimum/ {print $9}') -le $days ] || state=$(( $state + 2 ))
    done
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.5.1.2() {
    id=$1
    level=$2
    description=" Ensure password expiration is 365 days or less"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    file="/etc/login.defs"
    days=365
    if [ -s $file ]; then
        if [ $(grep -c "^PASS_MAX_DAYS" $file) -eq 1 ]; then
            [ $(awk '/^PASS_MAX_DAYS/ {print $2}' $file) -le $days ] || state=1
        fi
    fi
    
    for i in $(egrep ^[^:]+:[^\!*] /etc/shadow | cut -d: -f1); do 
        [ $(chage --list $i 2>/dev/null | awk '/Maximum/ {print $9}') -le $days ] || state=1
    done
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.5.1.3() {
    id=$1
    level=$2
    description="Ensure password expiration warning days is 7 or more"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    file="/etc/login.defs"
    days=7
    if [ -s $file ]; then
        if [ $(grep -c "^PASS_WARN_AGE" $file) -eq 1 ]; then
            [ $(awk '/^PASS_WARN_AGE/ {print $2}' $file) -ge $days ] || state=1
        fi
    fi
    
    for i in $(egrep ^[^:]+:[^\!*] /etc/shadow | cut -d: -f1); do 
        [ $(chage --list $i 2>/dev/null | awk '/warning/ {print $10}') -ge $days ] || state=1
    done
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_5.5.1.4() {
    id=$1
    level=$2
    description="Ensure inactive password lock is 30 days or less"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    max_days=30
    max_seconds=$(( $max_days * 24 * 60 * 60 ))
    
    [ $(useradd -D | grep INACTIVE | sed 's/^.*=//') -gt 0 -a $(useradd -D | grep INACTIVE | sed 's/^.*=//') -le $max_days ] || state=1
    
    for i in $(egrep ^[^:]+:[^\!*] /etc/shadow | cut -d: -f1); do 
        [ $(chage --list $i 2>/dev/null | awk '/Password expires/ {print $4}') != "never" ] && does_password_expire=True || does_password_expire=False
        [ $(chage --list $i 2>/dev/null | awk '/Password inactive/ {print $4}') != "never" ] && does_password_inactive=True || does_password_inactive=False

        if [ "$does_password_expire" == 'True' -a "$does_password_inactive" == 'True' ]; then
            password_expires=$(chage --list $i | sed -n '/Password expires/ s/^.*: //p')
            password_inactive=$(chage --list $i | sed -n '/Password inactive/ s/^.*: //p')
            
            expires_time=$(date +%s -d "$password_expires")
            inactive_time=$(date +%s -d "$password_inactive")
            
            time_difference=$(( $inactive_time - $expires_time ))
            
            [ $time_difference -gt $max_seconds ] && state=1
            
        else
            state=1
        fi
    done
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_5.5.1.5() {
    id=$1
    level=$2
    description="Ensure all users last password change date is in the past"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    state=0
    
    for user in $(cat /etc/shadow | cut -d: -f1); do 
        change_date=$(chage --list $user | sed -n '/Last password change/ s/^.*: //p')
        
        if [ "$change_date" != 'never' ]; then
            [ $(date +%s) -gt $(date -d "$change_date" +%s) ] || state=1
        fi
    done

    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.5.2() {
    id=$1
    level=$2
    description="Ensure system accounts are secured"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(awk -F: '$1!~/(root|sync|shutdown|halt|^\+)/ && $3<'"$(awk '/^\s*UID_MIN/{print $2}' /etc/login.defs)"' && $7!~/((\/usr)?\/sbin\/nologin)/ && $7!~/(\/bin)?\/false/ {print}' /etc/passwd | wc -l) -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_5.5.3() {
    id=$1
    level=$2
    description="Ensure default group for the root account is GID 0 "
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(grep "^root:" /etc/passwd | cut -f4 -d:) -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_5.5.4() {
    id=$1
    level=$2
    description="Ensure default user umask is 027 or more restrictive"
    scored="Scored"
    test_start_time="$(test_start $id)"
    state=0
    
    ## Tests Start ##
    masks=$(grep -RPi '(^|^[^#]*)\s*umask\s+([0-7][0-7][01][0-7]\b|[0-7][0-7][0-7][0-6]\b|[0-7][01][0-7]\b|[0-7][0-7][0-6]\b|(u=[rwx]{0,3},)?(g=[rwx]{0,3},)?o=[rwx]+\b|(u=[rwx]{1,3},)?g=[^rx]{1,3}(,o=[rwx]{0,3})?\b)' /etc/login.defs /etc/profile* /etc/bash.bashrc* | awk '{print $2}')
    [ -z "$masks" ] && state=1

    for mask in $masks; do
        bits=($(echo $mask | grep -o .))
        
        [ ${bits[0]} -lt 0 ] && state=2
        [ ${bits[1]} -lt 2 ] && state=2
        [ ${bits[2]} -lt 7 ] && state=2
    done

    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_5.7() {
    id=$1
    level=$2
    description="Ensure access to the su command is restricted"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(egrep -c "^auth\s+required\s+pam_wheel.so\s+use_uid" /etc/pam.d/su) -eq 1 ] || state=1
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}


## Section 6 - System Maintenance
test_6.1.1() {
    id=$1
    level=$2
    description="Audit system file permissions"
    scored="Not Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(dpkg -s /bin/bash | wc -l) -eq 0 ] || state=1
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.1.10() {
    id=$1
    level=$2
    description="Ensure no world writable files exist"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(df --local -P | awk 'NR!=1 {print $6}' | xargs -I '{}' find '{}' -xdev -type f -perm -0002 | wc -l) -eq 0 ] || state=1
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.1.11() {
    id=$1
    level=$2
    description="Ensure no unowned files or directories exist"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(df --local -P | awk 'NR!=1 {print $6}' | xargs -I '{}' find '{}' -xdev -nouser 2>/dev/null | wc -l) -eq 0 ] || state=1
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.1.12() {
    id=$1
    level=$2
    description="Ensure no ungrouped files or directories exist"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(df --local -P | awk 'NR!=1 {print $6}' | xargs -I '{}' find '{}' -xdev -nogroup 2>/dev/null | wc -l) -eq 0 ] || state=1
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}

test_6.2.1() {
    id=$1
    level=$2
    description="Ensure accounts in /etc/passwd use shadowed passwords"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(awk -F: '($2 != "x" )' /etc/passwd | wc -l) -eq 0 ] || state=1
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.2.2() {
    id=$1
    level=$2
    description="Ensure password fields are not empty"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(awk -F: '($2 == "" )' /etc/shadow | wc -l) -eq 0 ] || state=1
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.2.3() {
    id=$1
    level=$2
    description="Ensure all groups in /etc/passwd exist in /etc/group"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    for i in $(cut -s -d: -f4 /etc/passwd | sort -u ); do 
        grep -q -P "^.*?:[^:]*:$i:" /etc/group
        [ $? -eq 0 ] || state=1
    done
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.2.4() {
    id=$1
    level=$2
    description="Ensure all users' home directories exist"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    awk -F: '{ print $1" "$3" "$6 }' /etc/passwd |\
        while read user uid dir; do
            [ $uid -ge 1000 -a ! -d "$dir" -a $user != "nfsnobody" ] && state=1
        done 
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.2.5() {
    id=$1
    level=$2
    description="Ensure users own their own home directories"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    awk -F: '{ print $1 " " $3 " " $6 }' /etc/passwd | while read user uid dir; do
        if [ $uid -ge 1000 -a -d "$dir" -a $user != "nfsnobody" ]; then 
            owner=$(stat -L -c "%U" "$dir")
            [ "$owner" == "$user" ] || state=1
        fi
    done
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.2.6() {
    id=$1
    level=$2
    description="Ensure users' home directories permissions are 750 or more restrictive"
    scored="Scored"
    test_start_time="$(test_start $id)"
    state=0
    
    ## Tests Start ##
    for dir in $(egrep -v '(halt|sync|shutdown|/sbin/nologin|vboxadd)' /etc/passwd | awk -F: '{print $6}'); do
        perms=$(stat $dir | awk 'NR==4 {print $2}' )

        [ $(echo $perms | cut -c12) == "-" ] || state=$(( $state + 1 ))
        [ $(echo $perms | cut -c14) == "-" ] || state=$(( $state + 2 ))
        [ $(echo $perms | cut -c15) == "-" ] || state=$(( $state + 4 ))
        [ $(echo $perms | cut -c16) == "-" ] || state=$(( $state + 8 ))
    done
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.2.7() {
    id=$1
    level=$2
    description="Ensure users' dot files are not group or world writable"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    for dir in `cat /etc/passwd | egrep -v '(sync|halt|shutdown)' | awk -F: '($7 != "/sbin/nologin") { print $6 }'`; do
        for file in $dir/.[A-Za-z0-9]*; do
            if [ ! -h "$file" -a -f "$file" ]; then
                fileperm=`ls -ld $file | cut -f1 -d" "`
                
                [ `echo $fileperm | cut -c6` == "-" ] || state=1
                [ `echo $fileperm | cut -c9`  == "-" ] || state=1
            fi
        done
    done
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.2.8() {
    id=$1
    level=$2
    description="Ensure no users have .netrc files"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    for dir in $(egrep -v '(root|sync|halt|shutdown|/sbin/nologin)' /etc/passwd | awk -F: '{print $6}'); do
        file=$dir/.netrc
        if [ ! -h "$file" -a -f "$file" ]; then
            fileperm=`ls -ld $file | cut -f1 -d" "`
            [ `echo $fileperm | cut -c5`  != "-" ] || state=1
            [ `echo $fileperm | cut -c6`  != "-" ] || state=1
            [ `echo $fileperm | cut -c7`  != "-" ] || state=1
            [ `echo $fileperm | cut -c8`  != "-" ] || state=1
            [ `echo $fileperm | cut -c9`  != "-" ] || state=1
            [ `echo $fileperm | cut -c10`  != "-" ] || state=1
        fi
    done
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.2.9() {
    id=$1
    level=$2
    description="Ensure no users have .forward files"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    for dir in $(awk -F: '{ print $6 }' /etc/passwd); do
        [ -e "$dir/.forward" ] && state=1
    done
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.2.10() {
    id=$1
    level=$2
    description="Ensure no users have .rhosts files"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    for dir in $(awk -F: '{ print $6 }' /etc/passwd); do
        [ -e "$dir/.rhosts" ] && state=1
    done
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.2.11() {
    id=$1
    level=$2
    description="Ensure root is the only UID 0 account"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(awk -F: '$3 == 0' /etc/passwd | wc -l) -eq 1 ] || state=1
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.2.12() {
    id=$1
    level=$2
    description="Ensure root PATH integrity"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(echo $PATH | grep -c '::') -eq 0 ] || state=$(( $state + 1 ))
    [ $(echo $PATH | grep -c ':$') -eq 0 ] || state=$(( $state + 2 ))
    
    if [ $state -eq 0 ]; then
        for p in $(echo $PATH | sed -e 's/::/:/' -e 's/:$//' -e 's/:/ /g'); do 
            if [ -d $p ]; then
                if [ "$p" != "." ]; then
                    perms=$(ls -hald "$p/")
                    [ "$(echo $perms | cut -c6)" == '-' ] || state=$(( $state + 4 ))
                    [ "$(echo $perms | cut -c9)" == '-' ] || state=$(( $state + 8 ))
                    [ "$(echo $perms | awk '{print $3}')" == "root" ] || state=$(( $state + 16 ))
                else
                    state=$(( $state + 32 ))
                fi
            fi
        done
    fi
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.2.13() {
    id=$1
    level=$2
    description="Ensure no duplicate UIDs exist"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(cut -f3 -d: /etc/passwd | sort | uniq -c | awk '$1 > 1' | wc -l) -eq 0 ] || state=1
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.2.14() {
    id=$1
    level=$2
    description="Ensure no duplicate GIDs exist"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(cut -f3 -d: /etc/group | sort | uniq -c | awk '$1 > 1' | wc -l) -eq 0 ] || state=1
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.2.15() {
    id=$1
    level=$2
    description="Ensure no duplicate user names exist"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(cut -f1 -d: /etc/passwd | sort | uniq -c | awk '$1 > 1' | wc -l) -eq 0 ] || state=1
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.2.16() {
    id=$1
    level=$2
    description="Ensure no duplicate group names exist"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(cut -f1 -d: /etc/group | sort | uniq -c | awk '$1 > 1' | wc -l) -eq 0 ] || state=1
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}
test_6.2.17() {
    id=$1
    level=$2
    description="Ensure shadow group is empty"
    scored="Scored"
    test_start_time="$(test_start $id)"
    
    ## Tests Start ##
    [ $(grep ^shadow:[^:]*:[^:]*:[^:]+ /etc/group | wc -l) -eq 0 ] || state=1
    
    [ $state -eq 0 ] && result="Pass"
    ## Tests End ##
    
    duration="$(test_finish $id $test_start_time)ms"
    write_result "$id,$description,$scored,$level,$result,$duration"
}


### Main ###
## Main script execution starts here

## Parse arguments passed in to the script
parse_args $@

## Run setup function
echo "LOADING" > $tmp_file_base-stage
setup
progress & 

## Run Tests
## These tests could've been condensed using loops but I left it exploded for
## ease of understanding / updating in the future.

## Section 1 - Initial Setup
if [ $(is_test_included 1; echo $?) -eq 0 ]; then   write_cache "1,Initial Setup"
    
    ## Section 1.1 - Filesystem Configuration
    if [ $(is_test_included 1.1; echo $?) -eq 0 ]; then   write_cache "1.1,Filesystem Configuration"
        
        ## Section 1.1.1 - Disable unused filesystems
        if [ $(is_test_included 1.1.1; echo $?) -eq 0 ]; then   write_cache "1.1.1,Disable unused filesystems"
            run_test 1.1.1.1 1 test_1.1.1.x cramfs   ##  Ensure mounting of cramfs filesystems is disabled
            run_test 1.1.1.2 1 test_1.1.1.x freevxfs    ## Ensure mounting of freevxfs filesystems is disabled 
            run_test 1.1.1.3 1 test_1.1.1.x jffs2   ##  Ensure mounting of jffs2 filesystems is disabled 
            run_test 1.1.1.4 1 test_1.1.1.x hfs   ##  Ensure mounting of hfs filesystems is disabled
            run_test 1.1.1.5 1 test_1.1.1.x hfsplus   ## Ensure mounting of hfsplus filesystems is disabled
            run_test 1.1.1.6 1 test_1.1.1.x udf   ## Ensure mounting of udf filesystems is disabled 
        fi
        run_test 1.1.2 1 test_1.1.x-check_partition /tmp   ## 1.1.2 Ensure /tmp is configured  [change]
        run_test 1.1.3 1 test_1.1.x-check_fs_opts /tmp nodev   ## 1.1.3 Ensure nodev option set on /tmp
        run_test 1.1.4 1 test_1.1.x-check_fs_opts /tmp nosuid   ## 1.1.4 Ensure nosuid option set on /tmp
        run_test 1.1.5 1 test_1.1.x-check_fs_opts /tmp noexec   ## 1.1.5 Ensure noexec option set on /tmp
        run_test 1.1.6 1 test_1.1.x-check_partition /dev/shm   ## 1.1.6 Ensure /dev/shm is configured [change]
        run_test 1.1.7 1 test_1.1.x-check_fs_opts /dev/shm nodev   ## 1.1.7 Ensure nodev option set on /dev/shm partition [change]
        run_test 1.1.8 1 test_1.1.x-check_fs_opts /dev/shm nosuid   ## 1.1.8 Ensure nosuid option set on /dev/shm partition [change]
        run_test 1.1.9 1 test_1.1.x-check_fs_opts /dev/shm noexec   ## 1.1.9 Ensure noexec option set on /dev/shm partition [change]
        run_test 1.1.10 2 test_1.1.x-check_partition /var   ## 1.1.10 Ensure separate partition exists for /var [change]
        run_test 1.1.11 2 test_1.1.x-check_partition /var/tmp    ## 1.1.11 Ensure separate partition exists for /var/tmp [change]
        run_test 1.1.12 1 test_1.1.x-check_fs_opts /var/tmp nodev  ## 1.1.12 Ensure /var/tmp partition includes the nodev option [change]
        run_test 1.1.13 1 test_1.1.x-check_fs_opts /var/tmp nosuid   ## 1.1.13 Ensure /var/tmp partition includes the nosuid option [change]
        run_test 1.1.14 1 test_1.1.x-check_fs_opts /var/tmp noexec   ## 1.1.14 Ensure /var/tmp partition includes the noexec option [change]
        run_test 1.1.15 2 test_1.1.x-check_partition /var/log    ## 1.1.15 Ensure separate partition exists for /var/log [change]
        run_test 1.1.16 2 test_1.1.x-check_partition /var/log/audit   ## 1.1.16 Ensure separate partition exists for /var/log/audit [change]
        run_test 1.1.17 2 test_1.1.x-check_partition /home   ## 1.1.17 Ensure separate partition exists for /home [change]
        run_test 1.1.18 1 test_1.1.x-check_fs_opts /var/tmp nodev ## 1.1.18 Ensure /home partition includes the nodev option [change]
        run_test 1.1.19 1 test_1.1.x-check_removable nodev  ## 1.1.19 Ensure nodev option set on removable media partitions [change]
        run_test 1.1.20 1 test_1.1.x-check_removable nosuid  ## 1.1.20 Ensure nosuid option set on removable media partitions [change]
        run_test 1.1.21 1 test_1.1.x-check_removable noexec  ## 1.1.21 Ensure noexec option set on removable media partitions [change]
        run_test 1.1.22 1 test_1.1.22   ## 1.1.22 Ensure Sticky bit is set on all world-writable dirs
        run_test 1.1.23 1 test_1.1.23   ## 1.1.23 Disable Automounting
        run_test 1.1.24 1 test_1.1.24 usb-storage   ## 1.1.24 Disable USB Storage
    fi
    
    ## Section 1.2 - Configure Software Updates
    if [ $(is_test_included 1.2; echo $?) -eq 0 ]; then   write_cache "1.2,Configure Software Updates"
        #run_test 1.2.1 1 test_1.2.1   ## 1.2.1 Ensure package manager repositories are configured
        run_test 1.2.1 1 skip_test "Ensure package manager repositories are configured" ## 1.2.1 Ensure package manager repositories are configured
        run_test 1.2.2 1 skip_test "Ensure GPG keys are configured" ## 1.2.2 Ensure GPG keys are configured [script must change]
    fi
    
    ## Section 1.3 - Filesystem Integrity Checking
    if [ $(is_test_included 1.3; echo $?) -eq 0 ]; then   write_cache "1.3,Filesystem Integrity Checking"
        run_test 1.3.1 1 test_is_installed aide AIDE   ## 1.3.1 Ensure AIDE is installed [script change]
        run_test 1.3.2 1 test_1.3.2   ## 1.3.2 Ensure filesystem integrity is regularly checked
    fi
    
    ## Section 1.4 - Secure Boot Settings
    if [ $(is_test_included 1.4; echo $?) -eq 0 ]; then   write_cache "1.4,Secure Boot Settings"
        run_test 1.4.1 1 test_perms 400 /boot/grub/grub.cfg   ## 1.4.1 Ensure permissions on bootloader config are not overridden [change]
        run_test 1.4.2 1 test_1.4.2   ## 1.4.2 Ensure bootloader password is set [script change]
        run_test 1.4.3 1 test_perms 400 /boot/grub/grub.cfg   ## 1.4.3 Ensure permissions on bootloader config are configured [new]
        run_test 1.4.4 1 test_1.4.4   ## 1.4.4 Ensure authentication requires for single user mode [change]
    
    fi
    
    ## Section 1.5 - Additional Process Hardening
    if [ $(is_test_included 1.5; echo $?) -eq 0 ]; then   write_cache "1.5,Additional Process Hardening"
        run_test 1.5.1 1 test_1.5.1   ## 1.5.1 Ensure XD/NX support is enabled
        run_test 1.5.2 1 test_1.5.2   ## 1.5.2 Ensure address space layout randomisation (ASLR) is enabled [script change]
        run_test 1.5.3 1 test_1.5.3   ## 1.5.3 Ensure prelink is disabled [script change]
        run_test 1.5.4 1 test_1.5.4   ## 1.5.4 Ensure core dumps are restricted [script change]
    
    fi
    
    ## Section 1.6 - Mandatory Access Control
    if [ $(is_test_included 1.6; echo $?) -eq 0 ]; then   write_cache "1.6,Mandatory Access Control"
        if [ $(is_test_included 1.6.1; echo $?) -eq 0 ]; then   write_cache "1.6.1,Configure AppArmor"
            run_test 1.6.1.1 1 test_1.6.1.1   ## 1.6.1.1 Ensure AppArmor is installed [new]
            run_test 1.6.1.2 1 test_1.6.1.2   ## 1.6.1.2 Ensure AppArmor is enabled in the bootloader configuration [script change]
            run_test 1.6.1.3 1 test_1.6.1.3   ## 1.6.1.3 Ensure all AppArmor Profiles are in enforce or complain mode [script change]
            run_test 1.6.1.4 2 test_1.6.1.4   ## 1.6.1.4 Ensure all AppArmor Profiles are enforcing [script change]
        fi
        run_test 1.6.2 2 skip_test "not applicable on ubuntu"   ## 1.6.2 Ensure SELinux is installed
    fi
    
    ## Section 1.7 - Command Line Warning Banners
    if [ $(is_test_included 1.7; echo $?) -eq 0 ]; then   write_cache "1.7,Command Line Warning Banners"
        run_test 1.7.1 1 test_1.7.1   ## 1.7.1 Ensure message of the day is configured properly (Scored)
        run_test 1.7.2 1 test_perms 644 /etc/issue.net   ## 1.7.2 Ensure permissions on /etc/issue.net are configured (Not Scored) [change]
        run_test 1.7.3 1 test_perms 644 /etc/issue   ## 1.7.3 Ensure permissions on /etc/issue are configured (Scored) [change]
        run_test 1.7.4 1 test_perms 644 /etc/motd   ## 1.7.4 Ensure permissions on /etc/motd are configured (Not Scored) [change]
        run_test 1.7.5 1 test_1.7.5   ## 1.7.5 Ensure remote login warning banner is configured properly (Not Scored) [change]
        run_test 1.7.6 1 test_1.7.6   ## 1.7.6 Ensure local login warning banner is configured properly (Not Scored) [change]
    fi
    
    ## Section 1.8 - GNOME Display Manager
    if [ $(is_test_included 1.8; echo $?) -eq 0 ]; then   write_cache "1.8,GNOME Display Manager"
        run_test 1.8.1 2 test_1.8.1   ## 1.8.1 Ensure GNOME Display Manager is removed (Scored) [new]
        run_test 1.8.2 1 test_1.8.2   ## 1.8.2 Ensure GDM login banner is configured  [new]
        run_test 1.8.3 1 test_1.8.3   ## 1.8.3 Ensure disable-user-list is enabled  [new]
        run_test 1.8.4 1 test_1.8.4   ## 1.8.4 Ensure XDCMP is not enabled [new]
    fi
    run_test 1.9 1 test_1.9   ## 1.9 Ensure updates, patches, and additional security software are installed (Not Scored) 
fi

## Section 2 - Services
if [ $(is_test_included 2; echo $?) -eq 0 ]; then   write_cache "2,Services"
     if [ $(is_test_included 2.1; echo $?) -eq 0 ]; then   write_cache "2.1,Special Purpose Services"
        if [ $(is_test_included 2.1.1; echo $?) -eq 0 ]; then   write_cache "2.1.1,Time Synchronisation"
            run_test 2.1.1.1 1 test_2.1.1.1   ## 2.1.1.1 Ensure time synchronization is in use (Not Scored) [change]
            run_test 2.1.1.2 1 test_2.1.1.2   ## 2.1.1.2 Ensure systemd-timesyncd is configured (Scored) [change]
            run_test 2.1.1.3 1 test_2.1.1.3   ## 2.2.1.3 Ensure chrony is configured (Scored)
        fi
        run_test 2.1.2 1 test_2.1.2   ## 2.1.2 Ensure X Window System is not installed (Scored) [change]
        run_test 2.1.3 1 test_2.1.x avahi-daemon avahi-daemon.service "5353" Avahi Server   ## 2.1.3 Ensure Avahi Server is not installed  (Scored)
        run_test 2.1.4 1 test_2.1.x cups cups.service "631" CUPS ## 2.1.4 Ensure CUPS is not installed  (Scored) [change]
        run_test 2.1.5 1 test_2.1.x isc-dhcp-server dhcpd.service "67" DHCP Server ## 2.1.5 Ensure DHCP Server is not installed (Scored)
        run_test 2.1.6 1 test_2.1.x slapd slapd.service "583|:636" LDAP Server ## 2.1.6 Ensure LDAP server is not installed (Scored) [change]
        run_test 2.1.7 1 test_2.1.7 ## 2.1.7 Ensure NFS is not installed (Scored)
        run_test 2.1.8 1 test_2.1.x bind9 named.service "53" DNS Server ## 2.1.8 Ensure DNS Server is not installed (Scored) [change]
        run_test 2.1.9 1 test_2.1.x vsftpd vsftpd.service "21" FTP Server ## 2.1.9 Ensure FTP Server is not installed (Scored) [change]
        run_test 2.1.10 1 test_2.1.x apache2 httpd.service "80|:443" HTTP Server  ## 2.1.10 Ensure HTTP server is not installed (Scored) [change]
        run_test 2.1.11 1 test_2.1.x dovecot-imapd dovecot.service "110|:143|:587|:993|:995" IMAP and POP3  ## 2.1.11 Ensure IMAP and POP3 server are not installed  (Scored) [change]
        run_test 2.1.12 1 test_2.1.x samba smb.service "445" Samba ## 2.1.12 Ensure Samba is not installed (Scored) [change]
        run_test 2.1.13 1 test_2.1.x squid squid.service "3128|:80|:443" HTTP Proxy Server ## 2.1.13 Ensure HTTP Proxy Server is not installed (Scored) [change]
        run_test 2.1.14 1 test_2.1.x snmpd snmpd.service "161" SNMP ## 2.1.14 Ensure SNMP Server is not installed  (Scored) [change]
        run_test 2.1.15 1 test_2.1.15   ## 2.1.15 Ensure mail transfer agent is configured for local-only mode (Scored) [change]
        run_test 2.1.16 1 test_2.1.x rsync rsyncd.service "873" rsync ## 2.1.16 Ensure rsync service is not installed (Scored) [change]
        run_test 2.1.17 1 test_2.1.x nis ## 2.1.17 Ensure NIS Server is not installed (Scored)

    fi
    if [ $(is_test_included 2.2; echo $?) -eq 0 ]; then   write_cache "2.2,Service Clients"
        run_test 2.2.1 1 test_2.2.x nis nis  ### 2.2.1 Ensure NIS Client is not installed (Scored) [change]
        run_test 2.2.2 1 test_2.2.x rsh-client rsh-client  ### 2.2.2 Ensure rsh client is not installed (Scored) [change]
        run_test 2.2.3 1 test_2.2.x talk talk  ## 2.2.3 Ensure talk client is not installed (Scored) [change]
        run_test 2.2.4 1 test_2.2.x telnet telnet   ## 2.2.4 Ensure telnet client is not installed (Scored) [change]
        run_test 2.2.5 1 test_2.2.x ldap-utils LDAP   ## 2.2.5 Ensure LDAP client is not installed  (Scored) [change]
        run_test 2.2.6 1 test_2.2.x rpcbind RPC   ## 2.2.6 Ensure RPC is not installed   (Scored) [change]
    fi
    run_test 2.3 1 test_2.3   ## 2.3 Ensure nonessential services are removed or masked (Not Scored) [new]
fi

## Section 3 - Network Configuration 
if [ $(is_test_included 3; echo $?) -eq 0 ]; then   write_cache "3,Network Configuration"
    if [ $(is_test_included 3.1; echo $?) -eq 0 ]; then   write_cache "3.1,Disable unused network protocols and devices"
        run_test 3.1.1 2 test_3.1.1   ## 3.1.1 Disable IPv6 (Not Scored) [new]
        run_test 3.1.2 1 test_3.1.2   ## 3.1.2 Ensure wireless interfaces are disabled  (Not Scored) [new]
    fi

    if [ $(is_test_included 3.2; echo $?) -eq 0 ]; then   write_cache "3.2,Network Parameters (Host Only)"
        run_test 3.2.1 1 test_3.x-double ipv4 send_redirects 0 "Ensure packet redirect sending is not allowed"   ## 3.2.1 Ensure packet redirect sending is disabled (Scored)
        run_test 3.2.2 1 test_3.x-single ipv4 ip_forward 0 "Ensure IP forwarding is disabled"   ## 3.2.2 Ensure IP forwarding is disabled  (Scored) [change]
    fi

    if [ $(is_test_included 3.3; echo $?) -eq 0 ]; then   write_cache "3.3,Network Parameters (Host and Router)"
        run_test 3.3.1 1 test_3.x-double ipv4 accept_source_route 0 "Ensure source routed packets are not accepted"   ## 3.3.1 Ensure source routed packets are not accepted (Scored) [change]
        run_test 3.3.2 1 test_3.x-double ipv4 accept_redirects 0 "Ensure ICMP redirects are not accepted"   ## 3.3.2 Ensure ICMP redirects are not accepted  (Scored) [change]
        run_test 3.3.3 1 test_3.x-double ipv4 secure_redirects 0 "Ensure secure ICMP redirects are not accepted"   ##3.3.3 Ensure secure ICMP redirects are not accepted (Scored) [change]
        run_test 3.3.4 1 test_3.x-double ipv4 log_martians 1 "Ensure suspicious packages are logged"   ## 3.3.4 Ensure suspicious packets are logged (Scored) [change]
        run_test 3.3.5 1 test_3.x-single ipv4 icmp_echo_ignore_broadcasts 1 "Ensure broadcast ICMP requests are ignored"   ## 3.3.5 Ensure broadcast ICMP requests are ignored (Scored) [change]
        run_test 3.3.6 1 test_3.x-single ipv4 icmp_ignore_bogus_error_responses 1 "Ensure bogus ICMP responses are ignored"   ## 3.3.6 Ensure bogus ICMP responses are ignored (Scored) [change]
        run_test 3.3.7 1 test_3.x-double ipv4 rp_filter 1 "Ensure Reverse Path Filtering is enabled"   ## 3.3.7 Ensure Reverse Path Filtering is enabled (Scored) [change]
        run_test 3.3.8 1 test_3.x-single ipv4 tcp_syncookies 1 "Ensure TCP SYN Cookies are enabled"   ## 3.3.8 Ensure TCP SYN Cookies is enabled  (Scored) [change]
        run_test 3.3.9 1 test_3.x-double ipv6 accept_ra 1 "Ensure IPv6 router advertisements are not accepted "   ## 3.3.9 Ensure IPv6 router advertisements are not accepted  (Scored) [change]
    fi

    if [ $(is_test_included 3.4; echo $?) -eq 0 ]; then   write_cache "3.4,Uncommon Network Protocols"
        run_test 3.4.1 2 test_3.4.x dccp DCCP   ### 3.4.1 Ensure DCCP is disabled (Not Scored) [change]
        run_test 3.4.2 2 test_3.4.x sctp SCTP   ### 3.5.2 Ensure SCTP is disabled (Not Scored)
        run_test 3.4.3 2 test_3.4.x rds RDS   ### 3.5.3 Ensure RDS is disabled (Not Scored)
        run_test 3.4.4 2 test_3.4.x tipc TIPC   ### 3.5.4 Ensure DCCP is disabled (Not Scored)
    fi

        if [ $(is_test_included 3.5; echo $?) -eq 0 ]; then   write_cache "3.5,Firewall Configuration"
            if [ $(is_test_included 3.5.1; echo $?) -eq 0 ]; then   write_cache "3.5.1,Configure Uncomplicated Firewall"
                run_test 3.5.1.1 1 test_is_installed ufw ufw   ## 3.5.1.1 Ensure ufw is installed  (Scored) [change]
                run_test 3.5.1.2 1 test_3.5.1.2   ## 3.5.1.2 Ensure iptables-persistent is not installed with ufw (Scored) [new]
                run_test 3.5.1.3 1 test_3.5.1.3   ## 3.5.1.3 Ensure ufw service is enabled (Scored) [new]
                run_test 3.5.1.4 1 test_3.5.1.4   ## 3.5.1.4 Ensure ufw loopback traffic is configured (Scored) [change]
                run_test 3.5.1.5 1 test_3.5.1.5   ## 3.5.1.5 Ensure ufw outbound connections are configured (Not Scored) [change]
                run_test 3.5.1.6 1 test_3.5.1.6   ## 3.5.1.6 Ensure ufw firewall rules exist for all open ports  (Not Scored) [change]
                run_test 3.5.1.7 1 test_3.5.1.7   ## 3.5.1.7 Ensure ufw default deny firewall policy (Scored) [change]
         
            fi
            if [ $(is_test_included 3.5.2; echo $?) -eq 0 ]; then   write_cache "3.5.2,Configure nftables"
                run_test 3.5.2.1 1 test_3.5.2.1   ## 3.5.2.1 Ensure nftables is installed  (Scored) [new]
                run_test 3.5.2.2 1 test_3.5.2.2   ## 3.5.2.2 Ensure ufw is uninstalled or disabled with nftables (Scored) [new]
                run_test 3.5.2.3 1 test_3.5.2.3   ## 3.5.2.3 Ensure iptables are flushed with nftables (Scored) [new]
                run_test 3.5.2.4 1 test_3.5.2.4   ## 3.5.2.4 Ensure a nftables table exists(Scored) [new]
                run_test 3.5.2.5 1 test_3.5.2.5   ## 3.5.2.5 Ensure nftables base chains exist(Scored) [new]
                run_test 3.5.2.6 1 test_3.5.2.6   ## 3.5.2.6 Ensure nftables loopback traffic is configured (Scored) [new]
                run_test 3.5.2.7 1 test_3.5.2.7   ## 3.5.2.7 Ensure nftables outbound and established connections are configured (Scored) [new]
                run_test 3.5.2.8 1 test_3.5.2.8   ## 3.5.2.8 Ensure nftables default deny firewall policy (Scored) [new]
                run_test 3.5.2.9 1 test_3.5.2.9   ## 3.5.2.9 Ensure nftables service is enabled (Scored) [new]
                run_test 3.5.2.10 1 test_3.5.2.10   ## 3.5.2.10 Ensure nftables rules are permanent  (Scored) [new]
            fi
            if [ $(is_test_included 3.5.3; echo $?) -eq 0 ]; then   write_cache "3.5.3,Configure iptables"
                if [ $(is_test_included 3.5.3.1; echo $?) -eq 0 ]; then   write_cache "3.5.3.1,Configure iptables softwares"
                    run_test 3.5.3.1.1 1 test_3.5.3.1.1   ## 3.5.3.1.1 Ensure iptables packages are installed (Scored) [new]
                    run_test 3.5.3.1.2 1 test_3.5.3.1.2   ## 3.5.3.1.2 Ensure nftables is not installed with iptables (Scored) [new]
                    run_test 3.5.3.1.3 1 test_3.5.3.1.3   ## 3.5.3.1.3 Ensure ufw is uninstalled or disabled with iptables (Scored) [new]
                fi
                if [ $(is_test_included 3.5.3.2; echo $?) -eq 0 ]; then   write_cache "3.5.3.2,Configure IPv4 iptables"
                    run_test 3.5.3.2.1 1 test_3.5.3.2.1   ## 3.5.3.2.1 Ensure iptables default deny firewall policy (Scored) [new]
                    run_test 3.5.3.2.2 1 test_3.5.3.2.2   ## 3.5.3.2.2 Ensure iptables loopback traffic is configuredy (Scored) [new]
                    run_test 3.5.3.2.3 1 skip_test   ## 3.5.3.2.3  Ensure iptables outbound and established connections are configured (Scored) [new]
                    run_test 3.5.3.2.4 1 skip_test   ## 3.5.3.2.4 Ensure iptables firewall rules exist for all open ports (Scored) [new]
                fi
                 if [ $(is_test_included 3.5.3.3; echo $?) -eq 0 ]; then   write_cache "3.5.3.3,Configure IPv6 iptables"
                    run_test 3.5.3.3.1 1 test_3.5.3.3.1   ## 3.5.3.3.1 Ensure ip6tables default deny firewall policy (Scored) [new]
                    run_test 3.5.3.3.2 1 test_3.5.3.3.2   ## 3.5.3.3.2 Ensure ip6tables loopback traffic is configuredy (Scored) [new]
                    run_test 3.5.3.3.3 1 skip_test   ## 3.5.3.3.3 Ensure ip6tables outbound and established connections are configured (Scored) [new]
                    run_test 3.5.3.3.4 1 skip_test   ## 3.5.3.3.4 Ensure ip6tables firewall rules exist for all open ports (Scored) [new]
                fi
            fi
        fi

    ## This test deviates from the benchmark's audit steps. The assumption here is that if you are on a server
    ## then you shouldn't have the wireless-tools installed for you to even use wireless interfaces
  
fi

## Section 4 - Logging and Auditing
if [ $(is_test_included 4; echo $?) -eq 0 ]; then   write_cache "4,Logging and Auditing"
    if [ $(is_test_included 4.1; echo $?) -eq 0 ]; then   write_cache "4.1,Configure System Accounting (auditd)"
         if [ $(is_test_included 4.1.1; echo $?) -eq 0 ]; then   write_cache "4.1.1,Ensure auditing is enabled"
            run_test 4.1.1.1 2 test_is_installed auditd audispd-plugins  ##4.1.1.1 Ensure auditd is installed (Not Scored) [change]
            run_test 4.1.1.2 2 test_is_enabled auditd auditd    ## 4.1.1.2 Ensure auditd service is enabled (Scored) [change]
            run_test 4.1.1.3 2 test_4.1.1.3   ## 4.1.1.3 Ensure auditing for processes that start prior to auditd is enabled (Scored)[change]
            run_test 4.1.1.4 2 test_4.1.1.4   ## 4.1.1.4 Ensure audit_backlog_limit is sufficient (Scored)[change]
        fi
        if [ $(is_test_included 4.1.2; echo $?) -eq 0 ]; then   write_cache "4.1.2,Configure Data Retention"
            run_test 4.1.2.1 2 test_4.1.2.1   ## 4.1.2.1 Ensure audit log storage size is configured  (Not Scored)
            run_test 4.1.2.2 2 test_4.1.2.2   ## 4.1.2.2 Ensure audit logs are not automatically deleted (Scored)
            run_test 4.1.2.3 2 test_4.1.2.3   ## 4.1.2.3 Ensure system is disabled when audit logs are full (Scored)  
        fi
        run_test 4.1.3 2 test_4.1.3   ## 4.1.3 Ensure events that modify date and time information are collected (Scored) [change]
        run_test 4.1.4 2 test_4.1.4   ##4.1.4 Ensure events that modify user/group information are collected (Scored) [change]
        run_test 4.1.5 2 test_4.1.5   ## 4.1.5 Ensure events that modify the system's network environment are collected (Scored) [change]
        run_test 4.1.6 2 test_4.1.6   ## 4.1.6 Ensure events that modify the system's Mandatory Access Controls are collected (Scored) [change]
        run_test 4.1.7 2 test_4.1.7   ## 4.1.7 Ensure login and logout events are collected  (Scored) [change]
        run_test 4.1.8 2 test_4.1.8   ## 4.1.8 Ensure session initiation information is collected (Scored) [change]
        run_test 4.1.9 2 test_4.1.9   ## 4.1.9 Ensure discretionary access control permission modification events are collected  (Scored) [change]
        run_test 4.1.10 2 test_4.1.10   ## 4.1.10 Ensure unsuccessful unauthorized file access attempts are collected (Scored) [change]
        run_test 4.1.11 2 skip_test "Ensure use of privileged commands is collected"   ## 4.1.11 Ensure use of privileged commands is collected (Scored)
        run_test 4.1.12 2 test_4.1.12   ## 4.1.12 Ensure successful file system mounts are collected (Scored)
        run_test 4.1.13 2 test_4.1.13   ## 4.1.13 Ensure file deletion events by users are collected (Scored)
        run_test 4.1.14 2 test_4.1.14   ## 4.1.14 Ensure changes to system administration scope (sudoers) is collected (Scored)
        run_test 4.1.15 2 test_4.1.15   ## 4.1.15 Ensure system administrator command executions (sudo) are collected (Scored)
        run_test 4.1.16 2 test_4.1.16   ## 4.1.16 Ensure kernel module loading and unloading is collected (Scored)
        run_test 4.1.17 2 test_4.1.17   ## 4.1.17 Ensure the audit configuration is immutable (Scored)
        
    fi
    if [ $(is_test_included 4.2; echo $?) -eq 0 ]; then   write_cache "4.2,Configure Logging"
        if [ $(is_test_included 4.2.1; echo $?) -eq 0 ]; then
            if [ $(dpkg -s rsyslog &>/dev/null; echo $?) -eq 0 ]; then   write_cache "4.2.1,Configure rsyslog"
                run_test 4.2.1.1 1 test_is_installed rsyslog rsyslog   ## 4.2.1.1 Ensure rsyslog is installed (Scored)
                run_test 4.2.1.2 1 test_is_enabled rsyslog rsyslog   ## 4.2.1.2 Ensure rsyslog Service is enabled (Scored)
                run_test 4.2.1.3 1 skip_test "Ensure logging is configured"   ## 4.2.1.3 Ensure logging is configured (Scored)
                run_test 4.2.1.4 1 test_4.2.1.4   ## 4.2.1.4 Ensure rsyslog default file permissions configured (Scored)
                run_test 4.2.1.5 1 test_4.2.1.5   ## 4.2.1.5 Ensure rsyslog is configured to send logs to a remote log host (Scored)
                run_test 4.2.1.6 1 skip_test "Ensure remote rsyslog messages are only accepted on designated log hosts"   ## 4.2.1.6 Ensure remote rsyslog messages are only accepted on designated log hosts (Not Scored)
            fi
        fi
        if [ $(is_test_included 4.2.2; echo $?) -eq 0 ]; then
            if [ $(dpkg -s systemd &>/dev/null; echo $?) -eq 0 ]; then   write_cache "4.2.2,Configure journald"
                run_test 4.2.2.1 1 test_4.2.2.1  ## 4.2.2.1 Ensure journald is configured to send logs to rsyslog (scored) [new]
                run_test 4.2.2.2 1 test_4.2.2.2  ## 4.2.2.2 Ensure journald is configured to compress large log files (Scored)
                run_test 4.2.2.3 1 test_4.2.2.3   ## 4.2.2.3 Ensure journald is configured to write logfiles to persistent disk (Scored)
            fi
        fi
        run_test 4.2.3 1 test_4.2.3   ## 4.2.3 Ensure permissions on all logfiles are configured (Scored)
    fi
    run_test 4.3 1 skip_test "Ensure logrotate is configured"   ## 4.3 Ensure logrotate is configured (Not Scored)
    run_test 4.4 1 test_4.4 ## 4.4 Ensure logrotate assigns appropriate permissions (Not Scored)
fi

## Section 5 - Access, Authentication and Authorization
if [ $(is_test_included 5; echo $?) -eq 0 ]; then   write_cache "5,Access Authentication and Authorization"
    if [ $(is_test_included 5.1; echo $?) -eq 0 ]; then   write_cache "5.1,Configure time-based job schedulers"
        run_test 5.1.1 1 test_is_enabled cron "cron daemon"   ## 5.1.1 Ensure cron daemon is enabled and running (Scored)
        run_test 5.1.2 1 test_perms 600 /etc/crontab   ## 5.1.2 Ensure permissions on /etc/crontab are configured (Scored)
        run_test 5.1.3 1 test_perms 700 /etc/cron.hourly   ## 5.1.3 Ensure permissions on /etc/cron.hourly are configured (Scored)
        run_test 5.1.4 1 test_perms 700 /etc/cron.daily   ## 5.1.4 Ensure permissions on /etc/cron.daily are configured (Scored)
        run_test 5.1.5 1 test_perms 700 /etc/cron.weekly   ## 5.1.4 Ensure permissions on /etc/cron.daily are configured (Scored)
        run_test 5.1.6 1 test_perms 700 /etc/cron.monthly   ## 5.1.6 Ensure permissions on /etc/cron.monthly are configured (Scored)
        run_test 5.1.7 1 test_perms 700 /etc/cron.d   ## 5.1.7 Ensure permissions on /etc/cron.d are configured (Scored)
        run_test 5.1.8 1 test_5.1.8   ## 5.1.8 Ensure cron is restricted to authorized users (Scored)
        run_test 5.1.9 1 test_5.1.9   ## 5.1.9 Ensure at is restricted to authorized users  (Scored)
    fi
    if [ $(is_test_included 5.2; echo $?) -eq 0 ]; then   write_cache "5.2,Configure sudo schedulers"
        run_test 5.2.1 1 test_is_installed sudo sudo   ## 5.2.1 Ensure sudo is installed (Scored)
        run_test 5.2.2 1 test_5.2.2  ## 5.2.2 Ensure sudo commands use pty (Scored)
        run_test 5.2.3 1 test_5.2.3  ## 5.2.3 Ensure sudo log file exists (Scored)
    fi
    if [ $(is_test_included 5.3; echo $?) -eq 0 ]; then   write_cache "5.3,Configure SSH Server"
        run_test 5.3.1 1 test_perms 600 /etc/ssh/sshd_config   ## 5.3.1 Ensure permissions on /etc/ssh/sshd_config are configured (Scored)
        run_test 5.3.2 1 test_5.3.2   ## 5.3.2 Ensure permissions on SSH private host key files are configured (Scored)
        run_test 5.3.3 1 test_5.3.3   ## 5.3.3 Ensure permissions on SSH public host key files are configured (Scored)
        run_test 5.3.4 1 skip_test "Ensure SSH access is limited"   ## 5.3.4 Ensure SSH access is limited (Scored)
        run_test 5.3.5 1 test_5.3.5   ## 5.3.5 Ensure SSH LogLevel is appropriate  (Scored)
        run_test 5.3.6 1 test_5.3.6   ## 5.3.6 Ensure SSH X11 forwarding is disabled (Scored)
        run_test 5.3.7 1 test_5.3.7   ## 5.3.7 Ensure SSH MaxAuthTries is set to 4 or less (Scored)
        run_test 5.3.8 1 test_5.3.8   ## 5.3.8 Ensure SSH IgnoreRhosts is enabled (Scored)
        run_test 5.3.9 1 test_5.3.9   ## 5.3.9 Ensure SSH HostbasedAuthentication is disabled (Scored)
        run_test 5.3.10 1 test_5.3.10   ## 5.3.10 Ensure SSH root login is disabled (Scored)
        run_test 5.3.11 1 test_5.3.11   ## 5.3.11 Ensure SSH PermitEmptyPasswords is disabled (Scored)
        run_test 5.3.12 1 test_5.3.12   ## 5.3.12 Ensure SSH PermitUserEnvironment is disabled (Scored)
        run_test 5.3.13 1 test_5.3.13   ## 5.3.13 Ensure only strong Ciphers are used (Scored)
        run_test 5.3.14 1 test_5.3.14   ## 5.3.14 Ensure only strong MAC algorithms are used (Scored)
        run_test 5.3.15 1 test_5.3.15   ## 5.3.15 Ensure only strong Key Exchange algorithms are used (Scored)
        run_test 5.3.16 1 test_5.3.16   ## 5.3.16 Ensure SSH Idle Timeout Interval is configured (Scored)
        run_test 5.3.17 1 test_5.3.17   ## 5.3.17 Ensure SSH LoginGraceTime is set to one minute or less (Scored)
        run_test 5.3.18 1 test_5.3.18   ## 5.3.18 Ensure SSH warning banner is configured (Scored)
        run_test 5.3.19 1 test_5.3.19   ## 5.3.19 Ensure SSH PAM is enabled (Scored)
        run_test 5.3.20 2 test_5.3.20   ## 5.3.20 Ensure SSH AllowTcpForwarding is disabled  (Scored)
        run_test 5.3.21 1 test_5.3.21   ## 5.3.21 Ensure SSH MaxStartups is configured (Scored)
        run_test 5.3.22 1 test_5.3.22   ## 5.3.22 Ensure SSH MaxSessions is limited (Scored)
    fi
    if [ $(is_test_included 5.4; echo $?) -eq 0 ]; then   write_cache "5.4,Configure PAM"
        run_test 5.4.1 1 test_5.3.1   ## 5.4.1 Ensure password creation requirements are configured (Scored)
        run_test 5.4.2 1 skip_test "Ensure lockout for failed password attempts is configured"   ## 5.4.2 Ensure lockout for failed password attempts is configured (Scored)
        run_test 5.4.3 1 test_5.4.3   ## 5.4.3 Ensure password reuse is limited (Scored)
        run_test 5.4.4 1 test_5.4.4   ## 5.4.4 Ensure password hashing algorithm is SHA-512 (Scored)
    fi
    if [ $(is_test_included 5.5; echo $?) -eq 0 ]; then   write_cache "5.5,User Accounts and Environment"
        if [ $(is_test_included 5.5.1; echo $?) -eq 0 ]; then   write_cache "5.5.1,Set Shadow Password Suite Passwords"
            run_test 5.5.1.1 1 test_5.5.1.1   ## 5.5.1.1 Ensure minimum days between password changes is configured (Scored)
            run_test 5.5.1.2 1 test_5.5.1.2   ## 5.5.1.2 Ensure password expiration is 365 days or less (Scored)
            run_test 5.5.1.3 1 test_5.5.1.3   ## 5.5.1.3 Ensure password expiration warning days is 7 or more (Scored)
            run_test 5.5.1.4 1 test_5.5.1.4   ## 5.5.1.4 Ensure inactive password lock is 30 days or less (Scored)
            run_test 5.5.1.5 1 test_5.5.1.5   ## 5.5.1.5 Ensure all users last password change date is in the past (Scored)
        fi
        run_test 5.5.2 1 test_5.5.2   ## 5.5.2 Ensure system accounts are secured  (Scored)
        run_test 5.5.3 1 test_5.5.3   ## 5.5.3 Ensure default group for the root account is GID 0  (Scored)
        run_test 5.5.4 1 test_5.5.4   ## 5.5.4 Ensure default user umask is 027 or more restrictive (Scored)
        run_test 5.5.5 1 skip_test "Ensure default user shell timeout is 900 seconds or less"   ## 5.5.5 Ensure default user shell timeout is 900 seconds or less (Scored)
    fi
    run_test 5.6 1 skip_test "Ensure root login is restricted to system console"   ## 5.6 Ensure root login is restricted to system console (Not Scored)
    run_test 5.7 1 test_5.7   ## 5.7 Ensure access to the su command is restricted (Scored)
fi

## Section 6 - System Maintenance 
if [ $(is_test_included 6; echo $?) -eq 0 ]; then   write_cache "6,System Maintenance"
    if [ $(is_test_included 6.1; echo $?) -eq 0 ]; then   write_cache "6.1,System File Permissions"
        run_test 6.1.1 1 skip_test "Audit system file permissions"   ## 6.1.1 Audit system file permissions (Not Scored)
        run_test 6.1.2 1 test_perms 644 /etc/passwd   ## 6.1.2 Ensure permissions on /etc/passwd are configured (Scored)
        run_test 6.1.3 1 test_perms 644 /etc/passwd-   ## 6.1.3 Ensure permissions on /etc/passwd- are configured (Scored)
        run_test 6.1.4 1 test_perms 644 /etc/group   ## 6.1.4 Ensure permissions on /etc/group are configured (Scored)
        run_test 6.1.5 1 test_perms 644 /etc/group-   ## 6.1.5 Ensure permissions on /etc/group- are configured (Scored)
        run_test 6.1.6 1 test_perms 640 /etc/shadow   ## 6.1.6 Ensure permissions on /etc/shadow are configured (Scored)
        run_test 6.1.7 1 test_perms 640 /etc/shadow-   ## 6.1.7 Ensure permissions on /etc/shadow- are configured (Scored)
        run_test 6.1.8 1 test_perms 640 /etc/gshadow   ## 6.1.8 Ensure permissions on /etc/gshadow are configured (Scored)
        run_test 6.1.9 1 test_perms 640 /etc/gshadow-   ## 6.1.9 Ensure permissions on /etc/gshadow- are configured (Scored)
        run_test 6.1.10 1 test_6.1.10   ## Ensure no world-writable files exist (Scored)
        run_test 6.1.11 1 test_6.1.11   ## Ensure no unowned files or directories exist (Scored)
        run_test 6.1.12 1 test_6.1.12   ## Ensure no ungrouped files or directories exist (Scored)
        run_test 6.1.13 1 skip_test "Audit SUID executables"   ## 6.1.13 Audit SUID executables (Not Scored)
        run_test 6.1.14 1 skip_test "Audit SGID executables"   ## 6.1.14 Audit SGID executables (Not Scored)
    fi
    if [ $(is_test_included 6.2; echo $?) -eq 0 ]; then   write_cache "6.2,User and Group Settings"
        run_test 6.2.1 1 test_6.2.1   ## 6.2.1 Ensure accounts in /etc/passwd use shadowed passwords (Scored)
        run_test 6.2.2 1 test_6.2.2   ## 6.2.2 Ensure password fields are not empty (Scored)
        run_test 6.2.3 1 test_6.2.3   ## 6.2.3 Ensure all groups in /etc/passwd exist in /etc/group (Scored)
        run_test 6.2.4 1 test_6.2.4   ## 6.2.4 Ensure all users' home directories exist (Scored)
        run_test 6.2.5 1 test_6.2.5   ## 6.2.5 Ensure users own their home directories (Scored)
        run_test 6.2.6 1 test_6.2.6   ## 6.2.6 Ensure users' home directories permissions are 750 or more restrictive (Scored)
        run_test 6.2.7 1 test_6.2.7   ## 6.2.7 Ensure users' dot files are not group or world writable (Scored)
        run_test 6.2.8 1 test_6.2.8   ## 6.2.8 Ensure no users have .netrc files (Scored)
        run_test 6.2.9 1 test_6.2.9   ## 6.2.9 Ensure no users have .forward files (Scored)
        run_test 6.2.10 1 test_6.2.10   ## 6.2.10 Ensure no users have .rhosts files (Scored)
        run_test 6.2.11 1 test_6.2.11   ## 6.2.11 Ensure root is the only UID 0 account (Scored)
        run_test 6.2.12 1 test_6.2.12   ## 6.2.12 Ensure root PATH Integrity (Scored)
        run_test 6.2.13 1 test_6.2.13   ## 6.2.13 Ensure no duplicate UIDs exist
        run_test 6.2.14 1 test_6.2.14   ## 6.2.14 Ensure no duplicate GIDs exist (Scored)
        run_test 6.2.15 1 test_6.2.15   ## 6.2.15 Ensure no duplicate user names exist (Scored)
        run_test 6.2.16 1 test_6.2.16   ## 6.2.16 Ensure no duplicate group names exist (Scored)
        run_test 6.2.17 1 test_6.2.17   ## 6.2.17 Ensure shadow group is empty (Scored)
    fi
fi


## Wait while all tests exit
echo "RUNNING" > $tmp_file_base-stage
wait
echo "FINISHED" > $tmp_file_base-stage
write_debug "All tests have completed"

## Output test results
outputter
tidy_up

write_debug "Exiting with code $exit_code"
exit $exit_code