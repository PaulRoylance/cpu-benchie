#!/bin/bash

# GLOBAL VARIABLES =============================================================

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


# FUNCTIONS ====================================================================

function Debug # no arguments
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

function Abort # <string>
{
	local message="$@"
	echo "ABORT - $message" >&2 # TODO ensure stderr output
	exit 1
}

function Assert # <token> <token> <message>
{
	local measured="$1"
	local expected="$2"
	local message="$3"

	if [[ "$measured" != "$expected" ]]
	then
		echo "Measured: '$measured'"
		echo "Expected: '$expected'"
		Abort "$message"
	fi
}

function Help # no arguments
{
	echo "Usage: bash $0"
	echo "-a | --all        Test with every thread count in range"
	echo "-l | --lower      Set lower thread count bound"
	echo "-u | --upper      Set upper thread count bound"
	echo "-d | --duration   Set seconds of test duration"
	echo "-D | --delay      Set seconds of delay between tests"
	echo "-j | --json       Results output in JSON format"
	echo "-y | --yaml       Results output in YAML format"
	echo "-t | --table      Results output as an ASCII table"
	echo "-s | --silent     Suppress output during testing"
}

function Section # <string>
{
	local message="$@"
	local length=$(Maximum 28 ${#message})
	local bridge="##$(Repeat '#' $length)##"
	
	printf "\n$bridge\n"
	printf "# %-${length}s #" "$@"
	printf "\n$bridge\n"
}

# TODO tput column mktemp
function CheckDependencies # no arguments
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
	while $checking && [[ $# -gt 0 ]]
	do
		case $1 in
		-a|--all)
			TEST_CASE='COMPLETE'
			;;
		-l|--lower)
			LOWER=$2
			shift
			;;
		-u|--upper)
			UPPER=$2
			shift
			;;
			
		-D|--delay)
			DELAY=$2
			shift
			;;
		-d|--duration)
			DURATION=$2
			shift
			;;
		-j|--json)
			OUTPUT_MODE='JSON'
			(( OUTPUT_SETS += 1 ))
			;;
		-t|--table)
			OUTPUT_MODE='TABLE'
			(( OUTPUT_SETS += 1 ))
			;;
		-y|--yaml)
			OUTPUT_MODE='YAML'
			(( OUTPUT_SETS += 1 ))
			;;
			
		-s|--silent)
			SILENT=true
			;;
		--) # might not handle alternate flags well
			echo 'no more flags'
			checking=false
			;;
		*)	# TODO write this message
			#Help >&2
			#exit 1
			Abort "bash cpu-bench.sh [-a | --all] [-s | --silent] [--delay <seconds>] [--duration <seconds>] [-l <pos int>] [-u <pos int>] [--json | --table | --yaml] [--] [<threads>]"
			;;
		esac
		
		shift
	done
	
	TestGlobals
	
#	echo $@ # TODO do something with leftover arguments??
}

function TestGlobals
{
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
		Abort 'Upper thread limit cannot exceed 8192.'
	fi
	
	if [[ $UPPER -lt $LOWER ]]
	then
		Abort "Impossible threads range ($LOWER-$UPPER)."
	fi
}

# TODO move functions around to better consider call order
function GetInteger # <string>
# stdout <integer> or nothing 
{
	local integers=(`echo $@ | grep -o '\-\?[0-9]\+'`)
	echo $integers # only the first item
}

function IsInteger # <integer?>
{
	local input="$1"
	local result=0
	if [[ "$input" != "$(GetInteger $input)" ]]
	then
		result=1
	fi
	return $result
}

IsInteger 0
Assert $? 0 "IsInteger: Can't match single integer."

IsInteger 123
Assert $? 0 "IsInteger: Can't match multiple integer."

IsInteger 9.0
Assert $? 1 "IsInteger: Matched a float"

IsInteger a00a
Assert $? 1 "IsInteger: Matched mixed number."

IsInteger "asdf movie"
Assert $? 1 "IsInteger: Matched string."

IsInteger -1
Assert $? 0 "IsInteger: Can't match negative number."

function TimeEstimate # no arguments
{
	local test_count=${#THREAD_TESTS[@]}
	local delay_count=$(( $test_count - 1 ))
	echo $(( $DURATION * $test_count + $DELAY * $delay_count ))
}

# TODO trap temp file
function CreateState # no arguments
{
	trap 'Clean' SIGINT
	trap 'Clean' SIGTERM
	if [[ ! -e $STATE_FILE ]]
	then
		STATE_FILE=$(mktemp)
	fi
}

function ClearState # no arguments
{
	if [[ -e $STATE_FILE ]]
	then
		rm $STATE_FILE
	fi
	STATE_FILE=''
}

function GetState # no arguments
{
	if [[ -e $STATE_FILE ]]
	then
		local state=(`cat $STATE_FILE`)
		case ${state[0]} in
		TEST)
			local threads=${state[1]}
			local size=$(MaxItemSize ${THREAD_TESTS[@]})
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

# TODO look into proper job control to kill all on SIGINT
function Clean # no entries
{
#	for pid in ${BACKGROUND_JOBS[@]}
#	do
#		kill $pid
#	done
	Erase
	killall -s SIGINT
	ClearState
}

# ARRAY FUNCTIONS ==============================================================

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

function Maximum # <integer> <integer>
{
	if [[ $(bc <<< "$1 > $2") -eq 1 ]]
	then
		echo $1
	else
		echo $2
	fi
}

function Minimum # <integer|float> <integer|float>
{
	if [[ $(bc <<< "$1 < $2") -eq 1 ]]
	then
		echo $1
	else
		echo $2
	fi
}

function MaxItemSize # <any>...
{
	local array=($@)
	local max_size=0
	for item in ${array[@]}
	do
		max_size=$(Maximum $max_size ${#item})
	done
	echo $max_size
}

function PrepareTests # no arguments
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

# BENCHMARK FUNCTIONS ==========================================================

function Benchmark # <integer>
{
	local threads=$1
	SetState "TEST $threads"
	sysbench cpu --threads=$threads --time=$DURATION run
}

# TODO awk?
function GetFloat # <string>
{
	local phrase=$@
	echo $phrase | grep -o '[0-9]\+.[0-9]\+'
}

function GetInteger # <string>
# stdout <integer> or nothing 
{
	local integers=(`echo $@ | grep -o '\-\?[0-9]\+'`)
	echo $integers # only the first item
}

Assert " $(GetInteger 'empty phrase')" ' ' 'Found something in an empty phrase.'
Assert " $(GetInteger Phrase 34 holds a number)" ' 34' 'Cannot catch positive number.'
Assert " $(GetInteger 'You have -34 apples')"   ' -34' 'Cannot catch negative number.'
Assert " $(GetInteger 'Here are 34.56 apples')"  ' 34' 'Catches multiple numbers.'

function GetSpeed # <string>
{
	local benchmark=$@
	local speed=$(echo "$benchmark" | grep 'events per second')
	GetFloat $speed
}

function GetMinimum # <string>
{
	local benchmark=$@
	local minimum=$(echo "$benchmark" | grep 'min:')
	GetFloat $minimum
}

function GetAverage # <string>
{
	local benchmark=$@
	local average=$(echo "$benchmark" | grep 'avg:')
	GetFloat $average
}

function GetMaximum # <string>
{
	local benchmark=$@
	local maximum=$(echo "$benchmark" | grep 'max:')
	GetFloat $maximum
}

function RunTests # no arguments
{
	for threads in ${THREAD_TESTS[@]}
	do
		local result=$(Benchmark $threads)
		CPU_SPEEDS+=(`GetSpeed "$result"`)
		LATENCY_MINIMUMS+=(`GetMinimum "$result"`)
		LATENCY_AVERAGES+=(`GetAverage "$result"`)
		LATENCY_MAXIMUMS+=(`GetMaximum "$result"`)
		
		if [[ $DELAY -gt 0 && $threads -ne ${THREAD_TESTS[-1]} ]]
		then
			SetState 'WAIT'
			sleep $DELAY
		fi
	done
}

# PRINTING FUNCTIONS ===========================================================

function Plural # <integer>
{
	if [[ $1 -ne 1 ]]
	then
		printf 's'
	fi
}

function EssGap # <integer>
{
	if [[ $1 -eq 1 ]]
	then
		printf ' '
	fi
}

function EraseLine # no arguments
{
	printf "\033[1K\r"
}

function Repeat # <string> <integer>
{
	local item=$1
	local times=$2
	for (( i = 0; i < $times; ++i ))
	do
		printf "$item"
	done
}

function Ceiling # <float>
{
	local float=$(bc <<< "$1 + 0.5")
	echo $(printf "%.0f" $float)
}

function Floor # <float>
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
	      parts=$(Minimum $parts $length)
	
	printf "[%-${length}s]" $(Repeat "=" $parts)
}

function Timestamp
{
	local time=$(date +"%s.%N")
	printf "%.3f" $time
}

# TODO refactor
# TODO fix magic numbers
function StateWidth
{
	local size=$(MaxItemSize ${THREAD_TESTS[@]})
	echo $(( 9 + size )) 
}

# TODO progress bar dynamic width
# TODO status ordering and appearance
function Status
{
	local duration=$(TimeEstimate)
	local start=$(Timestamp)
	local time_elapsed=0
	local time_left=$duration
	
	local state_width=$(StateWidth)
	
	local continue=true
	
#	while [[ $(bc <<< "$time_elapsed < $duration") -eq 1 ]]
	while $continue
	do
		local state=$(GetState)
		local width=$(( `tput cols` - 30 )) # TODO magic number
		local bar=$(ProgressBar $time_elapsed $duration $width)
		
		EraseLine
		printf "%-${state_width}s" "$state"
		printf " $bar"
		printf " %${#duration}ds" $(Ceiling $time_left)

		sleep 0.0625
		
		if [[ $(bc <<< "$time_elapsed < $duration") -ne 1 ]]
		then
			continue=false
		else
			time_elapsed=$(bc <<< "$(Timestamp) - $start")
			time_left=$(bc <<< "$duration - $time_elapsed")
		fi
	done
	EraseLine
}

function PrintSerial
{
	for key in ${!THREAD_TESTS[@]}
	do
		local threads=${THREAD_TESTS[$key]}
		local s=$(Plural $threads)
		echo "$threads Thread$s - ${CPU_SPEEDS[$key]}"
	done
}

# TODO use column command maybe
function PrintTable
{
	local speed_width=$(MaxItemSize "${CPU_SPEEDS[@]}")
	      speed_width=$(Maximum $speed_width 5)
	local divider="--------+-$(Repeat '-' $speed_width)-+---------+---------+---------"
	
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

function PrintResults
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

# TESTING CODE =================================================================

if $TEST_CODE; then

Section 'TESTING'

wide=$(tput cols)
(( wide -= 20 ))
echo "columns: $wide"

CheckFlags $@

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
Repeat 'o' 3
printf '\n'

echo $(Timestamp)

Debug

Abort "End of testing."

fi

# SCRIPT MAIN BODY =============================================================

CheckDependencies

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
	Status &
fi

RunTests

wait
ClearState

# TODO restyle function names
# TODO remove unused functions
# TODO remove testing section
# TODO script usage function
# TODO test IsInteger
# TODO use format

PrintResults

exit 0
