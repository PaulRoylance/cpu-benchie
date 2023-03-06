#!/bin/bash

#########################################
# GLOBAL VARIABLES
#########################################

TEST_CODE=false # TODO remove

# default list of threads to test
THREAD_TESTS=(1 2 4 6 8 12 16 24 32)

CPU_SPEEDS=()
LATENCY_MINIMUMS=()
LATENCY_AVERAGES=()
LATENCY_MAXIMUMS=()

DELAY=0
DURATION=10

LOWER=1
UPPER=$(nproc)
INCREMENT=8

SILENT=false

OUTPUT_SETS=0

OUTPUT_MODE='SERIAL' # other options: TABLE JSON YAML
TEST_CASE='FREQUENT' # other options: COMPLETE

STATE='LOAD' # other options: TEST WAIT
STATE_FILE=''
BACKGROUND_JOBS=() # TODO may be replaced by jobs command due to shell instance.

START_TIME=0
END_TIME=0


#########################################
# FUNCTIONS
#########################################

function Debug
{
	Section 'DEBUG'
	echo "TEST_CODE          : $TEST_CODE"
	echo "THREAD_TESTS       : ${THREAD_TESTS[@]}"
	echo "CPU_SPEEDS         : ${CPU_SPEEDS[@]}"
	echo "LATENCY_MINIMUMS   : ${LATENCY_MINIMUMS[@]}"
	echo "LATENCY_AVERAGES   : ${LATENCY_AVERAGES[@]}"
	echo "LATENCY_MAXIMUMS   : ${LATENCY_MAXIMUMS[@]}"
	echo "STATE FILE         : $STATE_FILE"
	echo "DELAY              : $DELAY"
	echo "DURATION           : $DURATION"
	echo "LOWER              : $LOWER"
	echo "UPPER              : $UPPER"
	echo "TEST_CASE          : $TEST_CASE"
	echo "OUTPUT_MODE        : $OUTPUT_MODE"
	echo "OUTPUT_SET         : $OUTPUT_SET"
}

function Assert # <token> <token> <message>
{
	local measured="$1"
	local expected="$2"
	local message="$3"

	if [[ "$measured" != "$expected" ]]
	then
		Abort "$message"
	fi
}

function Section
{
	local message="$@"
	local length=$(max 28 ${#message})
	local bridge="##$(repeat '#' $length)##"
	
	printf "\n$bridge\n"
	printf "# %-${length}s #" "$@"
	printf "\n$bridge\n"
}

# TODO tput column mktemp
function check_dependencies
{
	if ! command -v sysbench &> /dev/null
	then
		Abort 'Dependency "sysbench" is not installed.'
	fi
}

# TODO test that this works to capture flags correctly and returns correct values
# TODO -asdf flags
# TODO input safety
# TODO function to abort on command formatting issues
function CheckFlags # <flags> <flag argument>...
{
	local checking=true
	while [[ checking && $# -gt 0 ]]
	do
		case $1 in
		--all|-a)
			TEST_CASE='COMPLETE'
			;;
		--lower|-l)
			LOWER=$2
			shift
			;;
		--upper|-u)
			UPPER=$2
			shift
			;;
			
		--delay|-D)
			DELAY=$2
			shift
			;;
		--duration|-d)
			DURATION=$2
			shift
			;;
			
		--json|-j)
			OUTPUT_MODE='JSON'
			(( OUTPUT_SETS += 1 ))
			;;
		--table|-t)
			OUTPUT_MODE='TABLE'
			(( OUTPUT_SETS += 1 ))
			;;
		--yaml|-y)
			OUTPUT_MODE='YAML'
			(( OUTPUT_SETS += 1 ))
			;;
			
		--silent|-s)
			SILENT=true
			;;
		--) # might not handle alternate flags well
			checking=false
			;;
		*)	# TODO write this message
			Abort "format error message goes here"
			;;
		esac
		
		shift
	done
	
	if [[ $OUTPUT_SETS -gt 1 ]]
	then
		Abort 'Multiple data display methods requested.'
	fi
	
	if [[ $LOWER -lt 1 ]]
	then
		Abort 'Lower thread limit cannot be below 1.' # TODO should automatically handle instead maybe?
	fi
	
	if [[ $UPPER -gt 8192 ]]
	then
		Abort 'Upeer thread limit cannot exceed 8192.'
	fi
	
	if [[ $UPPER -lt $LOWER ]]
	then
		Abort "Impossible threads range ($LOWER-$UPPER)."
	fi
	
#	echo $@ # TODO do something with leftover arguments??
}

# TODO test this
# TODO use this
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

function TimeEstimate
{
	local test_count=${#THREAD_TESTS[@]}
	local delay_count=$(( $test_count - 1 ))
	echo $(( $DURATION * $test_count + $DELAY * $delay_count ))
}

function Abort
{
	local message="$@"
	echo $message >&2
	echo 'Aborting.'
	exit 1
}

# TODO trap temp file
function CreateState
{
	if [[ ! -e $STATE_FILE ]]
	then
		STATE_FILE=$(mktemp)
	fi
	trap 'ClearState' SIGINT # TODO what is the best place for a SIGINT trap?
}

function ClearState
{
	if [[ -e $STATE_FILE ]]
	then
		rm $STATE_FILE
	fi
	STATE_FILE=''
}

function GetState
{
	if [[ -e $STATE_FILE ]]
	then
		local state=(`cat $STATE_FILE`)
		case ${state[0]} in
		TEST)
			local threads=${state[1]}
			local size=$(max_item_size ${THREAD_TESTS[@]})
			printf "Threads: %-${size}d" $threads
			;;
		WAIT)
			printf 'Waiting'
			;;
		*)
			printf 'Loading..'
			;;
	esac
	fi
}

function SetState # <task name> <thread number>
{
	if [[ -e $STATE_FILE ]]
	then
		echo "$@" > $STATE_FILE
	fi
}

function RunJobs # <string>...
{
	while [[ $# -gt 0 ]]
	do
		$1 &
		BACKGROUND_JOBS=${!}
		shift
	done
}

function WaitJobs
{
	for pid in ${BACKGROUND_JOBS[@]}
	do
		wait $pid
	done
}

# TODO look into proper job control to kill all on SIGINT
function KillJobs
{
	for pid in ${BACKGROUND_JOBS[@]}
	do
		kill $pid
	done
}

#########################################
# ARRAY FUNCTIONS
#########################################

function TrimArray # "<array> " <integer> <integer>
{
	local array=($1)
	local low=$2
	local high=$3

	for key in ${!array[@]}
	do
		if [[ ${array[$key]} -lt $low || ${array[$key]} -gt $high ]]
		then
			unset array[$key]
		fi
	done
	
	echo ${array[@]}
}

function FillArray # <integer> <integer>
{
	local low=$1
	local high=$2
	
	seq $low 1 $high
}

function ExtendArray # "<array> " <integer>
{
	local array=($1)
	local limit=$2
	
	local next=$INCREMENT

	# determine next
	if [[ ${#array[@]} -gt 0 ]]
	then
		(( next += ${array[-1]} ))
	fi
	
	# extend
	while [[ $next -le $limit ]]
	do
		array+=($next)
		(( next += $INCREMENT ))
	done
	
	echo ${array[@]}
}

# TODO change expect parameters?
function ArrayAddLimits # <array>
{
	local array=($@)
	
	if [[ $# -gt 0 ]]
	then
		if [[ $LOWER -lt ${array[0]} && $LOWER -gt 0 ]]
		then
			echo "$LOWER "
		fi

		echo ${array[@]}

		if [[ $UPPER -gt ${array[-1]} ]]
		then
			echo " $UPPER"
		fi
	fi
}

function Length # <any>...
{
	local input="$@"
	echo ${#input}
}

function max # <integer> <integer>
{
	if [[ $(bc <<< "$1 > $2") -eq 1 ]]
	then
		echo $1
	else
		echo $2
	fi
}

# TODO n items
# array all the items
# default min to first
# for each check if lower
function min # <integer|float> <integer|float>
{
	if [[ $(bc <<< "$1 < $2") -eq 1 ]]
	then
		echo $1
	else
		echo $2
	fi
}

function max_item_size # <any>...
{
	local array=($@)
	local max_size=0
	for item in ${array[@]}
	do
		max_size=$(max $max_size ${#item})
	done
	echo $max_size
}

function PrepareTests
{
	case "$TEST_CASE" in
	FREQUENT)
		THREAD_TESTS=(`ExtendArray "${THREAD_TESTS[*]} " $UPPER`)
		THREAD_TESTS=(`TrimArray "${THREAD_TESTS[*]} " $LOWER $UPPER`)
		THREAD_TESTS=(`ArrayAddLimits ${THREAD_TESTS[@]}`)
		;;
	COMPLETE)
		THREAD_TESTS=(`FillArray $LOWER $UPPER`)
		;;
	esac
}

#########################################
# BENCHMARK FUNCTIONS
#########################################

function benchmark
{
	local threads=$1
	SetState "TEST $threads"
	sysbench cpu --threads=$threads --time=$DURATION run
}

# TODO awk?
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

function RunTests # empty
{
	for threads in ${THREAD_TESTS[@]}
	do
		local result=$(benchmark $threads)
		CPU_SPEEDS+=(`get_speed "$result"`)
		LATENCY_MINIMUMS+=(`get_minimum "$result"`)
		LATENCY_AVERAGES+=(`get_average "$result"`)
		LATENCY_MAXIMUMS+=(`get_maximum "$result"`)
		
		if [[ $DELAY -gt 0 && $threads -ne ${THREAD_TESTS[-1]} ]]
		then
			SetState 'WAIT'
			sleep $DELAY
		fi
	done
}

#########################################
# PRINTING FUNCTIONS
#########################################

function plural # <integer>
{
	if [[ $1 -ne 1 ]]
	then
		printf 's'
	fi
}

function plural_gap # <integer>
{
	if [[ $1 -eq 1 ]]
	then
		printf ' '
	fi
}

# TODO more verbose name???
# overall time left
# operation time left
# current operation
# clear_status
function erase # empty
{
	printf "\033[1K\r"
}

function repeat # <string> <integer>
{
	local item=$1
	local times=$2
	for (( i = 0; i < $times; ++i ))
	do
		printf "$item"
	done
}

function ceiling # <float>
{
	local float=$(bc <<< "$1 + 0.5")
	echo $(printf "%.0f" $float)
}

function floor # <float>
{
	local float=$(bc <<< "$1 - 0.5")
	echo $(printf "%.0f" $float)
}

# TODO global precision??
function ProgressBar # <float> <float> <integer>
{
	local progress=$1
	local total=$2
	local length=$3
	
	local parts=$(bc <<< "$length * $progress / $total")
	      parts=$(min $parts $length)
	
	printf "[%-${length}s]" $(repeat "=" $parts)
}

function timestamp
{
	local time=$(date +"%s.%N")
	printf "%.3f" $time
}

# TODO refactor
# TODO fix magic numbers
function state_width
{
	local size=$(max_item_size ${THREAD_TESTS[@]})
	echo $(( 9 + size )) 
}

# TODO progress bar dynamic width
# TODO status ordering and appearance
function status
{
	local duration=$(TimeEstimate)
	local start=$(timestamp)
	local time_elapsed=0
	local time_left=$duration
	
	local state_width=$(state_width)
	
	local continue=true
	
#	while [[ $(bc <<< "$time_elapsed < $duration") -eq 1 ]]
	while $continue
	do
		local state=$(GetState)
		local width=$(( `tput cols` - 30 )) # TODO magic number
		local bar=$(ProgressBar $time_elapsed $duration $width)
		
		erase
		printf "%-${state_width}s" "$state"
		printf " $bar"
		printf " %${#duration}ds" $(ceiling $time_left)

		sleep 0.0625
		
		if [[ $(bc <<< "$time_elapsed < $duration") -ne 1 ]]
		then
			continue=false
		else
			time_elapsed=$(bc <<< "$(timestamp) - $start")
			time_left=$(bc <<< "$duration - $time_elapsed")
		fi
	done
	erase
}

function PrintSerial
{
	for key in ${!THREAD_TESTS[@]}
	do
		local threads=${THREAD_TESTS[$key]}
		local s=$(plural $threads)
		echo "$threads Thread$s - ${CPU_SPEEDS[$key]}"
	done
}

# TODO use column command maybe
function PrintTable
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

function PrintJson
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

function PrintYaml
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
		PrintSerial
		;;
	TABLE)
		PrintTable
		;;
	JSON)
		PrintJson
		;;
	YAML)
		PrintYaml
		;;
	esac
}

#########################################
# TESTING CODE
#########################################

if $TEST_CODE; then

Section 'TESTING'

wide=$(tput cols)
(( wide -= 20 ))
echo "columns: $wide"

CheckFlags $@

Section 'IS INTEGER TESTING'

# TODO is_integer Assert

if ! is_integer 0
then
	echo "bad 0"
fi
if ! is_integer 123
then
	echo "bad missed number"
fi
if ! is_integer -1
then
	echo "bad negatives"
fi
if is_integer 9.0
then
	echo "bad float"
fi
if is_integer a00a
then
	echo "bad mixed middle"
fi
if is_integer aa00
then
	echo "bad mixed beginning"
fi
if is_integer 00aa
then
	echo "bad mixed end"
fi
if is_integer "asdf movie"
then
	echo "bad string"
fi

Section 'CASE FUNCTIONALITY'

input=4
printf 'case '
case $input in
	1)
		echo '1'
		;;
	2 | 3)
		echo '2 or 3'
		;;
	4)
		printf '4 or '
		;&
	5)
		echo '5'
		;;
esac

Section 'SHARED STATE SYSTEM'

CreateState
echo $STATE_FILE
CreateState
echo $STATE_FILE
SetState 'TEST' '5'
GetState
ClearState
echo $STATE_FILE


printf 'REPEAT TEST '
repeat 'o' 3
printf '\n'

echo $(timestamp)

Debug

Abort "End of testing."

fi

#########################################
# SCRIPT MAIN BODY
#########################################

check_dependencies

# Set flags
#while getopts 'D:d:al:u:jtyY' OPTION
#do
#	#TODO check if number
#	case "$OPTION" in
#	D)
#		DELAY=$OPTARG
#		;;
#	d) 
#		DURATION=$OPTARG
#		;;
#	a)
#		TEST_CASE='COMPLETE'
#		;;
#	l)
#		LOWER=$OPTARG
#		;;
#	u)
#		UPPER=$OPTARG
#		;;
#	j)
#		OUTPUT_MODE='JSON'
#		(( OUTPUT_SETS += 1 ))
#		;;
#	t)
#		OUTPUT_MODE='TABLE'
#		(( OUTPUT_SETS += 1 ))
#		;;
#	y)
#		OUTPUT_MODE='YAML'
#		(( OUTPUT_SETS += 1 ))
#		;;
#	*) # TODO update and what is standard practice?
#		Abort "script usage: $(basename \$0) [-d <integer>] [-l <integer>] [-u <integer>] [-e] [-j] [-t]"
#		;;
#	esac
#done

#shift "$(( $OPTIND - 1 ))"

#if [[ $OUTPUT_SETS -gt 1 ]]
#then
#	Abort 'Multiple data display methods requested.'
#fi

CheckFlags $@

PrepareTests

if ! $SILENT
then
	CreateState
	RunJobs status
fi

RunTests

WaitJobs
ClearState

# TODO restyle function names
# TODO remove unused functions
# TODO remove testing section
# TODO script usage function
# TODO test is_integer
# TODO use format

print_results

exit 0
