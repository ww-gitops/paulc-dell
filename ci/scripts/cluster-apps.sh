#!/usr/bin/env bash

# Utility to run in ci job to generate flux objects required to deploy applications to a cluster
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] --cluster <cluster name>" >&2
    echo "This script will generate flux objects required to deploy applications to a cluster" >&2
    echo "The script assumes you have a kubeconfig file for the cluster you want to use" >&2
    echo "The --cluster option is required to indicate the cluster to generate artefacts for" >&2
    echo "  --debug: emmit debugging information" >&2
}

function args() {
  clusterName=""
  debug_str=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x; debug_str="--debug";;
          "--cluster") (( arg_index+=1 ));clusterName=${arg_list[${arg_index}]};;
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

  if [ -z "${clusterName}" ]; then
    echo "cluster name is required" >&2
    usage; exit
  fi
}

args "$@"

top_level=$(git rev-parse --show-toplevel)
pushd ${top_level}

# Get Region and Account ID
export AWS_REGION="${AWS_REGION:-eu-west-1}"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

# Login to ECR
ecr_pass="$(aws ecr get-login-password --region $AWS_REGION)"
docker login --username AWS --password $ecr_pass $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

#  Clone the Cluster repository so we can access the namespaces and applications configuration yaml files
rm -rf ./build/clusters
git clone https://github.com/ww-gitops/clusters.git ./build/clusters

# Use GitopsSet to generate OCIRepository, Reciever and Kustomization yaml files for each application namespace assigned to this cluster
rm -rf ./build/${clusterName}
cat ci/gitopssets/cluster-namespaces.yaml | sed s/clusterName/${clusterName}/g > ./build/${clusterName}-namespaces.yaml
mkdir -p ./build/${clusterName}/manifests
gitopssets-cli generate ./build/${clusterName}-namespaces.yaml -d --repository-root ./build > ./build/${clusterName}/manifests/namespaces.yaml

# Use GitopsSet to generate OCIRepository, Reciever and Kustomization yaml files for each application in each namespace assigned to this cluster
cat ci/gitopssets/cluster-apps.yaml | sed s/clusterName/${clusterName}/g > ./build/${clusterName}-apps.yaml
gitopssets-cli generate  ./build/${clusterName}-apps.yaml -d --enabled-generators GitRepository --repository-root ./build > ./build/${clusterName}/gen-apps.yaml
gitopssets-cli generate  ./build/${clusterName}/gen-apps.yaml -d --enabled-generators GitRepository --repository-root ./build  > ./build/${clusterName}/manifests/apps.yaml

#  Copy the generated manifests into the cluster folder in that repository
mkdir -p ./build/clusters/${clusterName}
cp -rf ./build/${clusterName}/manifests ./build/clusters/${clusterName}

# Commit and push the changes to the cluster repository, note this could create a PR for review prior to merging
# Review process could include execution of CI tests and manual approval
pushd ./build/clusters
git add ${clusterName}/manifests

if [[ `git status --porcelain` ]]; then
  git commit -m "Update application manifests for cluster $clusterName"
  git pull
  git push
fi

# Build a manifest image and push to ECR repository for this cluster, this image will be used by the cluster to deploy the applications
# If manual approval is required, this could be done by a separate pipeline job

flux push artifact oci://$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/cluster-${clusterName}:latest --path ./${clusterName}/manifests  --source github.com/ww-gitops/clusters --revision main --provider aws --debug
popd
