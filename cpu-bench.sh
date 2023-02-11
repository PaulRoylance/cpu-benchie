#!/bin/bash

# todo license

#########################################
# GLOBAL VARIABLES
#########################################

TEST_CODE=false # todo remove

# default list of threads to test
THREAD_TESTS=(1 2 4 6 8 12 16 24 32)

AUTO_ACCEPT=false # todo remove

CPU_SPEEDS=()
LATENCY_MINIMUMS=()
LATENCY_AVERAGES=()
LATENCY_MAXIMUMS=()

LINUX_DISTRIBUTION=$(lsb_release -is) # todo remove

DELAY=0
DURATION=10

LOWER=1
UPPER=$(nproc)
INCREMENT=8

OUTPUT_MODE='SERIAL' # other options: TABLE JSON YAML
TEST_CASE='FREQUENT' # other options: COMPLETE
STATE='LOADING'      # other options: TEST WAIT

START_TIME=0
END_TIME=0


#########################################
# FUNCTIONS
#########################################

function debug
{
	section 'DEBUG'
	echo "TEST_CODE          : $TEST_CODE"
	echo "THREAD_TESTS       : ${THREAD_TESTS[@]}"
	echo "CPU_SPEEDS         : ${CPU_SPEEDS[@]}"
	echo "AUTO_ACCEPT        : $AUTO_ACCEPT"
	echo "LATENCY_MINIMUMS   : ${LATENCY_MINIMUMS[@]}"
	echo "LATENCY_AVERAGES   : ${LATENCY_AVERAGES[@]}"
	echo "LATENCY_MAXIMUMS   : ${LATENCY_MAXIMUMS[@]}"
	echo "LINUX_DISTRIBUTION : $LINUX_DISTRIBUTION"
	echo "DELAY              : $DELAY"
	echo "LOWER              : $LOWER"
	echo "UPPER              : $UPPER"
	echo "TEST_CASE          : $TEST_CASE"
	echo "OUTPUT_MODE        : $OUTPUT_MODE"
}

function check_dependencies
{
	if ! command -v sysbench &> /dev/null
	then
		abort 'Dependency "sysbench" is not installed.'
	fi
}

# todo broken
function set_flags
{
	echo 'broken'
}

# todo test this
# todo use this
function is_integer
{
	result=0
	case $1 in
	*[!0-9]* | '')
		result=1
		;;
	esac
	return $result
}

# todo refactor
function time_estimate
{
	local test_count=${#THREAD_TESTS[@]}
	local delay_count=$(( $test_count - 1 ))
	local estimate=$(( $test_count * $DURATION + $delay_count * $DELAY ))
	echo $estimate
}

function abort
{
	local message=$@
	printf '%s\n' "$message" >&2
	exit 1
}

function yes_or_no
{
	local reply
	read -p "$@" reply
	
	local result=2
	case $reply in
	[Yy]* | '')
		result=0
		;;
	[Nn]*)
		result=1
		;;
	esac
	return $result
}

#todo rename for time confirmation
function confirmation
{
	if ! $AUTO_ACCEPT
	then
		echo "Testing duration: `time_estimate` seconds"
		yes_or_no 'Continue? [Y/n]: '
		local result=$?
		if [[ $result -ne 0 ]]
		then
			abort $result
		fi
	fi
}

#########################################
# ARRAY FUNCTIONS
#########################################

# trim tests down to range
function trim_array
{
	local second=$(( $# - 2 ))
	local  third=$(( $# - 1 ))

	local array=($@)
	local low=${array[$second]}
	local high=${array[$third]}

	unset array[$second]
	unset array[$third]

	for key in ${!array[@]}
	do
		if [[ ${array[$key]} -lt $low || ${array[$key]} -gt $high ]]
		then
			unset array[$key]
		fi
	done
	
	echo ${array[@]}
}

function fill_array
{
	local low=$1
	local high=$2
	
	seq $low 1 $high
}

# extend tests to maximum
# todo clean
function extend_array
{
	local last=$(( $# - 1 ))

	local array=($@)
	local next=$INCREMENT
	local limit=${array[$last]}

	unset array[$last]	

	# determine next
	if [[ $# -gt 1 ]]
	then
		next=$(( ${array[-1]} + $INCREMENT ))
	fi
	
	# extend
	while [[ $next -le $limit ]]
	do
		array+=($next)
		(( next += $INCREMENT ))
	done
	
	echo ${array[@]}
}

# todo rename
function add_array_limits
{
	local array=($@)
	
	if [[ $# -eq 0 ]]
	then
		return 1
	fi
	
	if [[ $LOWER -lt ${array[0]} && $LOWER -gt 0 ]]
	then
		echo "$LOWER "
	fi
	
	echo ${array[@]}
	
	if [[ $UPPER -gt ${array[-1]} ]]
	then
		echo " $UPPER"
	fi
}

function max
{
	if [[ $1 -gt $2 ]]
	then
		echo $1
	else
		echo $2
	fi
}

function max_item_size
{
	local array=($@)
	local max_size=0
	for item in ${array[@]}
	do
		max_size=$(max $max_size ${#item})
	done
	echo $max_size
}

# todo something???
function prepare_tests
{
	case "$TEST_CASE" in
	FREQUENT)
		THREAD_TESTS=(`extend_array ${THREAD_TESTS[@]} $UPPER`)
		THREAD_TESTS=(`trim_array ${THREAD_TESTS[@]} $LOWER $UPPER`)
		THREAD_TESTS=(`add_array_limits ${THREAD_TESTS[@]}`)
		;;
	COMPLETE)
		THREAD_TESTS=(`fill_array $LOWER $UPPER`)
		;;
	esac
}

#########################################
# BENCHMARK FUNCTIONS
#########################################

function benchmark
{
	local threads=$1
	sysbench cpu --threads=$threads --time=$DURATION run
}

# todo awk?
function get_float
{
	local phrase=$@
	echo $phrase | grep -o '[0-9]\+.[0-9]\+'
}

function get_speed
{
	local benchmark=$@
	local speed=$(echo "$benchmark" | grep 'events per second')
	get_float $speed
}

function get_minimum
{
	local benchmark=$@
	local minimum=$(echo "$benchmark" | grep 'min:')
	get_float $minimum
}

function get_average
{
	local benchmark=$@
	local average=$(echo "$benchmark" | grep 'avg:')
	get_float $average
}

function get_maximum
{
	local benchmark=$@
	local maximum=$(echo "$benchmark" | grep 'max:')
	get_float $maximum
}

function run_tests
{
	for threads in ${THREAD_TESTS[@]}
	do
		local result=$(benchmark $threads)
		CPU_SPEEDS+=(`get_speed "$result"`)
		LATENCY_MINIMUMS+=(`get_minimum "$result"`)
		LATENCY_AVERAGES+=(`get_average "$result"`)
		LATENCY_MAXIMUMS+=(`get_maximum "$result"`)
		
		if [[ $threads -ne ${THREAD_TESTS[-1]} ]]
		then
			sleep $DELAY
		fi
	done
}

#########################################
# PRINTING FUNCTIONS
#########################################

function plural
{
	if [[ $1 -gt 1 ]]
	then
		echo "s"
	fi
}

function section
{
	echo ''
	echo '################################'
	printf "# %-28s #\n" "$@"
	echo '################################'
	echo ''
}

# todo more verbose name???
# overall time left
# operation time left
# current operation
# clear_status
function erase
{
	printf "\033[1K\r"
}

function repeat
{
	local item=$1
	local times=$2
	for (( i = 0; i < $times; ++i ))
	do
		printf "$item"
	done
}

function progress_bar
{
	local progress=$1
	local total=$2
	local length=$3
	
	local parts=$(bc <<< "$progress * $length / $total" )
	
	printf "[%-${length}s]" $(repeat "=" $parts)
}

function timestamp
{
	local time=$(date +"%s.%N")
	printf "%.3f" $time
}

function status
{
	local duration=$(time_estimate)
	local start=$(timestamp)
	local time_elapsed=0
	local time_left=$duration
	
	while [[ $(bc <<< "$time_elapsed < $duration") -eq 1 ]]
	do
		# get state
		bar=$(progress_bar $time_elapsed $duration 30)
		
		erase
		printf "STATE %s %${#duration}.0fs" "$bar" $time_left

		sleep 0.05
		
		time_elapsed=$(bc <<< "$(timestamp) - $start")
		time_left=$(bc <<< "$duration - $time_elapsed")
	done
	erase
}

# todo more verbose name??? other versions???
function print
{
	local threads=$1
	local result=$2
	local s=$(plural $threads)
	echo "$threads Thread$s - $result"
}

function print_serial
{
	for key in ${!THREAD_TESTS[@]}
	do
		print ${THREAD_TESTS[$key]} ${CPU_SPEEDS[$key]}
	done
}

function print_table
{
	local speed_width=$(max_item_size "${CPU_SPEEDS[@]}")
	      speed_width=$(max $speed_width 5)
	local divider="--------+-$(repeat '-' $speed_width)-+---------+---------+---------"
	
	printf "THREADS | %-${speed_width}s | MINIMUM | AVERAGE | MAXIMUM\n" 'SPEED'
	
	for key in ${!THREAD_TESTS[@]}
	do
		echo "$divider"
		printf "%7d" ${THREAD_TESTS[$key]}
		printf " | %$speed_width.2f" ${CPU_SPEEDS[$key]}
		printf " | %7.2f" ${LATENCY_MINIMUMS[$key]}
		printf " | %7.2f" ${LATENCY_AVERAGES[$key]}
		printf " | %7.2f" ${LATENCY_MAXIMUMS[$key]}
		printf '\n'
	done
}

function print_json
{
	printf '{\n'
	printf '  "threads": [\n'
	for key in ${!THREAD_TESTS[@]}
	do
		printf '    {\n'
		printf "      \"${THREAD_TESTS[$key]}\": {\n"
		printf "        \"speed\": ${CPU_SPEEDS[$key]},\n"
		printf '        "latency": {\n'
		printf "          \"minimum\": ${LATENCY_MINIMUMS[$key]},\n"
		printf "          \"average\": ${LATENCY_AVERAGES[$key]},\n"
		printf "          \"maximum\": ${LATENCY_MAXIMUMS[$key]}\n"
		printf '        }\n'
		printf '      }\n'
		printf '    }'
		if [[ ${THREAD_TESTS[$key]} -ne ${THREAD_TESTS[-1]} ]]
		then
			printf ','
		fi
		printf '\n'
	done
	printf '  ]\n'
	printf '}\n'
}

function print_yaml
{
	echo "threads:"
	for key in ${!THREAD_TESTS[@]}
	do
		echo "- ${THREAD_TESTS[$key]}:"
		echo "    speed: ${CPU_SPEEDS[$key]}"
		echo '    latency:'
		echo "        minimum: ${LATENCY_MINIMUMS[$key]}"
		echo "        average: ${LATENCY_AVERAGES[$key]}"
		echo "        maximum: ${LATENCY_MAXIMUMS[$key]}"
	done
}

function print_results
{
	case $OUTPUT_MODE in
	SERIAL)
		print_serial
		;;
	TABLE)
		print_table
		;;
	JSON)
		print_json
		;;
	YAML)
		print_yaml
		;;
	esac
}

#########################################
# TESTING CODE
#########################################

if $TEST_CODE; then

section 'TESTING'

if is_installed sysbench
then
	echo 'is_installed success!'
fi

extend_array 90
extend_array 1 90

printf "## %4s ##\n" 'TESTS'

printf '#####'
printf '\033[1K'
printf '\r==\n'
printf "\068\n"

timestamp

total=100
length=30
for i in $(seq 1 $total); do
#	printf "\rProgress: %3d%%" $((i * 100 / total))
	printf "\r%s" $(( $i * $length / $total ))
	progress_bar $i $total $length
	sleep 0.25
done
erase

abort 'Testing section of code'

debug

exit 0

fi

#########################################
# SCRIPT MAIN BODY
#########################################

check_dependencies

# todo silent
# korn shell reference
# Set flags
while getopts 'D:d:al:u:jtyY' OPTION
do
	#todo check if number
	case "$OPTION" in
	D)
		DELAY=$OPTARG
		;;
	d) 
		DURATION=$OPTARG
		;;
	a)
		TEST_CASE='COMPLETE'
		;;
	l)
		LOWER=$OPTARG
		;;
	u)
		UPPER=$OPTARG
		;;
	j)
		OUTPUT_MODE='JSON'
		;;
	t)
		OUTPUT_MODE='TABLE'
		;;
	y)
		OUTPUT_MODE='YAML'
		;;
	Y) # todo unnecessary feature, communicate time left instead
		AUTO_ACCEPT=true
		;;
	*) # todo update and what is standard practice?
		abort "script usage: $(basename \$0) [-d <integer>] [-l <integer>] [-u <integer>] [-e] [-j] [-t]"
		;;
	esac
done

shift "$(( $OPTIND - 1 ))"

prepare_tests

confirmation

status

run_tests

# todo status and clear status
# todo remove confirmation
# todo add --verbose flags
# todo remove unused functions
# todo remove testing section
# todo error when reseting output mode 2+ times
# todo fail when upper and lower limits exceeded
# todo fail when no tests

print_results

exit 0
