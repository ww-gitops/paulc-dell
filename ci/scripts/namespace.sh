#!/usr/bin/env bash

# Utility to run in ci job to generate flux objects required to deploy an application namespace to a cluster
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug]" >&2
    echo "This script will generate flux objects required to deploy an application namespace to a cluster" >&2
    echo "  --debug: emmit debugging information" >&2
}

function args() {
  wait=1
  install="-- install"
  bootstrap=0
  reset=0
  debug_str=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x; debug_str="--debug";;
               "-h") usage; exit;;
           "--help") usage; exit;;
               "-?") usage; exit;;
        *) if [ "${arg_list[${arg_index}]:0:2}" == "--" ];then
               echo "invalid argument: ${arg_list[${arg_index}]}" >&2
               usage; exit
           fi;
           break;;
    esac
    (( arg_index+=1 ))
  done
}

args "$@"

# Get Region and Account ID
export AWS_REGION="${AWS_REGION:-eu-west-1}"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

# Login to ECR
ecr_pass="$(aws ecr get-login-password --region $AWS_REGION)"
docker login --username AWS --password $ecr_pass $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Use GitopsSet to generate yaml files to create and configure each application namespace
rm -rf /tmp/${clusterName}
cat ci/gitopssets/namespaces.yaml | envsubst > /tmp/namespaces.yaml
mkdir -p /tmp/manifests
gitops generate gitopsset /tmp/namespaces.yaml > /tmp/manifests/namespaces.yaml

#  Clone the Cluster repository and copy the generated manifests into the cluster folder in that repository
rm -rf /tmp/clusters 
git clone https://github.com/ww-gitops/clusters.git /tmp/clusters
mkdir -p /tmp/clusters/${clusterName}
cp -rf /tmp/${clusterName}/manifests /tmp/clusters/${clusterName}

# Commit and push the changes to the cluster repository, note this could create a PR for review prior to merging
# Review process could include execution of CI tests and manual approval
pushd /tmp/clusters
git add ${clusterName}/manifests
if [[ `git status --porcelain` ]]; then
  git commit -m "Update application manifests for cluster $clusterName"
  git pull
  git push
fi

# Build a manifest image and push to ECR repository for this cluster, this image will be used by the cluster to deploy the applications
# If manual approval is required, this could be done by a separate Jenkins job parameter

flux push artifact oci://$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/cluster-${clusterName}:latest --path ./${clusterName}/manifests  --source github.com/ww-gitops/clusters --revision main --provider aws --debug
popd
