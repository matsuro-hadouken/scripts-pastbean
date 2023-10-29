#!/bin/bash

# Check which deploys are 'present, but not allocated'
# We need approximate 'names' of the subgraphs and current 'sync status' for better recoignition
# We don't want to allocate on subgraphs which are far behind, as this can become long neverending story
# Rotten subgraphs do not generate fees and can become deprecated over time. This can lead to the 'undesirable procedure of zero POI removal'.
# By running this script, we can gain insights into the activities of the indexing department and 'make informed decisions' directly from the console.

# Get data status
status=$(graph indexer status --network arbitrum-one -o json)

# Get the indexerDeployments and indexerAllocations using jq
indexerDeployments=$(echo "$status" | jq -r '.indexerDeployments[].subgraphDeployment')
indexerAllocations=$(echo "$status" | jq -r '.indexerAllocations[].subgraphDeployment')

function parse_yaml() {

  local prefix=""
  local s='[[:space:]]*'
  local w='[a-zA-Z0-9_]*'
  local fs=$'\034'

  curl_output=$(curl -s "https://ipfs.network.thegraph.com/ipfs/api/v0/cat?arg=$1")

  # Parse ipfs yaml https://stackoverflow.com/a/21189044 by Stefan Farestam
  echo "$curl_output" | sed -ne "s|^\($s\):|\1|p" \
    -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
    -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p" |
    awk -F$fs '{
    indent = length($1) / 2;
    vname[indent] = $2;
    for (i in vname) {
      if (i > indent) { delete vname[i] }
    }
    if (length($3) > 0) {
      vn = "";
      for (i = 0; i < indent; i++) {
        vn = (vn)(vname[i])("_")
      }
      values[vname[indent], $2] = $3;
    }
  }
  END {
    for (i in values) {
      printf("%s%s=\"%s\"\n", "'$prefix'", i, values[i]);
    }
  }'
}

function get_required_values() {

messy_respond="$(parse_yaml ${1})"

# It was very tough process to put grep in to work, probably here is better solutions around
name=$(grep -oP 'name="\K[^"]+' <<< "${messy_respond%x}")
network=$(grep -oP 'network="\K[^"]+' <<< "${messy_respond%x}")
startBlock=$(grep -oP 'startBlock="\K[^"]+' <<< "${messy_respond%x}")
address=$(grep -oP 'address="\K[^"]+' <<< "${messy_respond%x}")

echo

    if [[ $sync_current_state == "true" ]]; then
        echo -e " Subgraph name: \e[32m$1\e[0m"
    else
        echo -e " Subgraph name: $1"
    fi

# Print the parsed values
echo -e "   sync: $sync_current_state"
echo -e "   name: $name"
echo -e "   network: \e[34m$network\e[0m"
echo -e "   startBlock: $startBlock"
echo -e "   address: $address"

}

function check_status() {

  # Check which deployments are not allocated
  unallocated_deployments=()
  for deployment in $indexerDeployments; do

    allocated=false

    for allocation in $indexerAllocations; do

      if [[ "$allocation" == "$deployment" ]]; then
        allocated=true
        break
      fi

    done

    if ! $allocated; then
      unallocated_deployments+=("$deployment")
    fi

  done

  for deployment in "${unallocated_deployments[@]}"; do

    sync_status=$(echo "$status" | jq -r --arg deployment "$deployment" '.indexerDeployments[] | select(.subgraphDeployment == $deployment) | .synced')

    if [[ "$sync_status" == "true" ]]; then
      sync_current_state="true"
      get_required_values "$deployment"
    else
      sync_current_state="false"
      get_required_values "$deployment"
    fi

  done

}

check_status

echo
