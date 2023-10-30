#!/bin/bash

set -e

# This script is the research attempt on "mysterious performance values" displayed here: https://cspr.live/validators

# Please do not convert this to python or whatever using ChatGPT
# Do not try to adjust this by any AI thingy without understanding the exact math and whats going on

public_id="<VALIDATOR PUBLIC HEX>"

eras_to_check=360 # how much eras to check. Assume 360 is approximatly one month '(360*2)/24'

# skip bogus eras array excluded_eras=(123 456 789) 'Make sure excluded eras are in range'
excluded_eras=(11081) # 11081 is known to be missleading

log_file=log.txt # log everything in to this file

# our current performance source
chain_api='https://event-store-api-clarity-mainnet.make.services'

# We need 360 era here to mimic cspr.live, lets grap last completed era first
era_end=$(curl -sS "https://mainnet.cspr.art3mis.net/era" -H 'accept: application/json' | jq -r '.[] | .id')

# check if API respond
if ! [[ $era_end =~ ^[0-9]+$ ]]; then
    echo && echo " Failed to retrive last completed era, exiting ..." && exit 1
fi

echo && echo " Last completed era: $era_end" && echo

# check how many eras we decided to skip
number_of_excluded_eras="${#excluded_eras[@]}"

# if no era excluded set number of excluded eras to zero. Also set $era_start accordingly.
if [[ $number_of_excluded_eras -eq 0 ]]; then

        # we 'don not' want last x before current, but 'last x eras' <==========
        era_start=$((era_end - eras_to_check + 1)) # start crawler from here

        # check if API failed to respond
        if ! [[ $era_end =~ ^[0-9]+$ ]]; then
                echo " Starting era calculation error !" && exit 1
        fi

        echo " No eras specified in excluded_eras array, setting num_excluded_eras to 0" && echo
        echo " We want exact $eras_to_check eras, crawler will start from era: $era_start" && echo && sleep 1
        num_excluded_eras=0

# if we exclude eras from calculation for whatever reason, then probably need to add same amount in to the sequence, as we want to crawl exactly $eras_to_check ( debatable )
# Assume excluded era have zero length and will not contribute in to time measurement
else
        echo " Exluding $number_of_excluded_eras era from calculation: ${excluded_eras[@]}" && echo
        echo " We want exact $eras_to_check eras to crawl, adding $number_of_excluded_eras era in to our sequence, because $number_of_excluded_eras era is excluded." && echo && sleep 1

        # correction point !
        # adjusting value, so amount of eras specified in $eras_to_check stay the same
        # this only here because we are trying to replicate cspr.live values
        # we do not necesserely need this, or do we ? Trying to go different ways in hope metrics will match
        exclusion_modifier=$((number_of_excluded_eras + 1))

        # we should get exact $eras_to_check here
        era_start=$((era_end - eras_to_check + exclusion_modifier)) # start crawler from here

        echo " Crawler will start from era: $era_start" && echo && sleep 1

fi

# check if eras specified inside excluded_eras array are in range and integer as well
for era in "${excluded_eras[@]}"; do

    # check what is inside
    if ! [[ $era =~ ^[0-9]+$ ]]; then
        echo " ERROR: There is something strange inside the excluded_eras array: ${excluded_eras[@]}" && echo && exit 1
    fi

    # we need to be sure excluded era is in crawler range, otherwise it will produce nonsense
    if [ $era -lt $era_start ] || [ $era -gt $era_end ]; then
        echo " ERROR: Era we trying to exclude is outside of the frame ! Range is $era_start - $era_end and we are trying to exclude era $era" && echo && exit 1
    fi

done

# This stay valid 'only' if bogus eras properly excluded from calculation
# Otherwise "not in consensus" counter will be incremented for nothing
total_score=0 # final score
equivocated=0 # eras equivacated
zero_score=0  # not in consensus ( about to fail )

echo > ${log_file} # wipe log file

# main loop
for ((i=era_start; i<=era_end; i++)); do

  # Skip excluded eras
  if [[ " ${excluded_eras[@]} " =~ " ${i} " ]]; then
    echo " Era: $i ==> [ excluded ]"
    # echo " Era: $i ==> [ excluded ]" >>${log_file} # uncomment to include in to log file
    continue
  fi

  # current score source
  era_score=$(curl -s "${chain_api}"/validators/"$public_id"/relative-performances?era_id="$i" | jq -r '.data | .[].score')

  # detect zero [ validator is not participating in consensus ]
  # If this continue for 2 eras ( ~4h ) it will lead to equivacation
  if [[ "$era_score" == 0 ]]; then
    ((++zero_score))
    echo " Era: $i ==> $era_score ==> [ validator is not participating in consensus ]"
    echo "$i $era_score" >>${log_file}

  # Then validator equivacated, pub key will vanish from API response. This will happen 'only if' previous condition is true for as long as two eras ( ~4h )
  # This why <=
  elif [ -z "$era_score" ]; then
    era_score=0
    ((++equivocated))
    echo " Era: $i ==> $era_score ==> [ validator equivocated ]"
    echo "$i $era_score" >>${log_file}

  # normal validator routine
  else
    echo " Era: $i ==> $era_score"
    echo "$i $era_score" >>${log_file}

  fi

  # accumulate sum
  total_score=$(echo "$total_score + $era_score" | bc -l)

done

# final score calculation. This is average sum of all score in range ( $total_score ) devided on $eras_to_check
# Score to compare https://cspr.live/validators
final_score=$(echo "$total_score / $eras_to_check" | bc -l)

echo >>${log_file} && echo
echo " Skipped eras: $zero_score">>${log_file}
echo " Skipped eras: $zero_score"
echo " Equivocated: $equivocated" >>${log_file}
echo " Equivocated: $equivocated" && echo

echo " Number Of Excluded Eras: $number_of_excluded_eras" >>${log_file}
echo " Number Of Excluded Eras: $number_of_excluded_eras"

echo >>${log_file} && echo

echo "   Final Score: $final_score" >>${log_file}
echo "   Final Score: $final_score" && echo
