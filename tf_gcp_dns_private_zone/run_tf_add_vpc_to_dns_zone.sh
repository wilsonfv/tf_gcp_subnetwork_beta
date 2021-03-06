#!/bin/bash

function log()  {
    STAMP=$(date +'%Y-%m-%d %H:%M:%S %Z')
    LEVEL=$1
    case ${LEVEL} in
    ERROR)
        printf "%s %s    %s\n" "${STAMP}" "${LEVEL}" "$2" >&2
        ;;
    *)
        printf "%s %s    %s\n" "${STAMP}" "${LEVEL}" "$2"
        ;;
    esac
}

function get_tf_binary() {
    ROOT_DIR=$1
    PRODUCT=$2
    PRODUCT_VERSION=$3
    OS_VERSION=$4

    FILE_NAME=${PRODUCT}_${PRODUCT_VERSION}_${OS_VERSION}.zip
    URL=https://releases.hashicorp.com/${PRODUCT}/${PRODUCT_VERSION}/${FILE_NAME}

    log INFO "downloading ${URL}"
    curl -k -s ${URL} \
        -o ${ROOT_DIR}/${FILE_NAME}

    unzip -q -o ${ROOT_DIR}/${FILE_NAME} -d ${ROOT_DIR}
    rm -f ${ROOT_DIR}/${FILE_NAME}
}

function tidy_up() {
    if [[ -d ${SCRIPT_DIR}/.terraform ]]; then
        log INFO "terraform destroy"
        ${TF_BINARY_DIR}/terraform destroy \
            -no-color \
            -auto-approve \
            ${SCRIPT_DIR}

        log INFO "clean up terraform dir"
        if [[ -d ${SCRIPT_DIR}/.terraform ]]; then
            rm -rf ${SCRIPT_DIR}/.terraform
        fi
        if [[ -f ${SCRIPT_DIR}/terraform.tfstate ]]; then
            rm -f ${SCRIPT_DIR}/terraform.tfstate
        fi
        if [[ -f ${SCRIPT_DIR}/terraform.tfstate.backup ]]; then
            rm -f ${SCRIPT_DIR}/terraform.tfstate.backup
        fi
    fi

    for VPC_NAME in $(gcloud compute networks list \
                        --project=${GCP_PROJECT_ID} \
                        --format="value(NAME)")
    do
        for SUBNET in $(gcloud compute networks subnets list --filter="NETWORK:${VPC_NAME}" --format="csv(NAME,REGION)[no-heading]")
        do
            SUBNET_NAME=$(echo -n ${SUBNET} | cut -d, -f1)
            SUBNET_REGION=$(echo -n ${SUBNET} | cut -d, -f2)

            gcloud compute networks subnets delete ${SUBNET_NAME} --region ${SUBNET_REGION} -q
        done

        gcloud compute networks delete ${VPC_NAME} --project=${GCP_PROJECT_ID} -q
    done
}
# **********************************************************************************************
# Main Flow
# **********************************************************************************************

export SCRIPT_DIR=$(dirname "$0")
export TF_BINARY_DIR=${SCRIPT_DIR}/tf_binary
export GCP_PROJECT_ID=$(gcloud config list --format='value(core.project)')
export VPC_SUBNET_REGION="europe-west2"

if [[ ! -f ${GOOGLE_APPLICATION_CREDENTIALS} ]]; then
    log ERROR "Environment variable GOOGLE_APPLICATION_CREDENTIALS is not defined or file ${GOOGLE_APPLICATION_CREDENTIALS} does not exist"
    exit 1
fi
gcloud auth activate-service-account --key-file ${GOOGLE_APPLICATION_CREDENTIALS}

log INFO "download terraform binary"
if [[ -d ${TF_BINARY_DIR} ]]; then
    rm -rf ${TF_BINARY_DIR}
fi
mkdir -p ${TF_BINARY_DIR}
get_tf_binary ${TF_BINARY_DIR} terraform                        0.12.13 darwin_amd64
get_tf_binary ${TF_BINARY_DIR} terraform-provider-google        3.1.0 darwin_amd64
get_tf_binary ${TF_BINARY_DIR} terraform-provider-google-beta   3.1.0 darwin_amd64

tidy_up

log INFO "prepare network.tf"
cat >${SCRIPT_DIR}/network.tf<<EOF
module "default-network" {
  source = "terraform-google-modules/network/google"

  project_id   = var.project
  network_name = "default-network"
  routing_mode = "REGIONAL"

  subnets = [
    {
      subnet_name               = "net1"
      subnet_ip                 = "192.168.0.0/20"
      subnet_region             = var.region
      subnet_flow_logs          = "true"
      subnet_flow_logs_interval = "INTERVAL_10_MIN"
      subnet_flow_logs_sampling = 0.7
      subnet_flow_logs_metadata = "INCLUDE_ALL_METADATA"
      subnet_private_access     = "true"
    },
    {
      subnet_name               = "net2"
      subnet_ip                 = "192.168.16.0/20"
      subnet_region             = var.region
      subnet_flow_logs          = "true"
      subnet_flow_logs_interval = "INTERVAL_10_MIN"
      subnet_flow_logs_sampling = 0.7
      subnet_flow_logs_metadata = "INCLUDE_ALL_METADATA"
      subnet_private_access     = "true"
    }
  ]

  delete_default_internet_gateway_routes = true
}
EOF
cat ${SCRIPT_DIR}/network.tf

log INFO "prepare dns.tf"
cat >${SCRIPT_DIR}/dns.tf<<EOF
module "dns-private-zone" {
  source = "terraform-google-modules/cloud-dns/google"

  project_id = var.project
  type       = "private"
  name       = "private-access"
  domain     = "dot."

  private_visibility_config_networks = concat([module.default-network.network_self_link], compact(var.other_vpc_list))

  recordsets = [
    {
      name    = "restricted.googleapis.com"
      type    = "A"
      ttl     = 300
      records = ["199.36.153.4", "199.36.153.5", "199.36.153.6", "199.36.153.7"]
    },
    {
      name    = "gcr.io"
      type    = "A"
      ttl     = 300
      records = ["199.36.153.4", "199.36.153.5", "199.36.153.6", "199.36.153.7"]
    }
  ]
}
EOF
cat ${SCRIPT_DIR}/dns.tf

log INFO "prepare vars.tf"
cat >${SCRIPT_DIR}/vars.tf<<EOF
variable "project" {
  description = "project ID"
  type        = string
}

variable "region" {
  description = "subnet region"
  type        = string
}

variable "other_vpc_list" {
  description = "vpc network url to be added into Cloud DNS private access dot zone, separated by comma, vpc other than default-network"
  type        = list(string)
}
EOF
cat ${SCRIPT_DIR}/vars.tf

export OTHER_VPC_LIST=$(printf "\"%s\"," $(gcloud compute networks list \
                                            --project=${GCP_PROJECT_ID} \
                                            --format="value(selfLink)" \
                                            --filter="name!=default-network"))

log INFO "prepare terraform.tfvars"
cat >${SCRIPT_DIR}/terraform.tfvars<<EOF
project = "${GCP_PROJECT_ID}"
region = "${VPC_SUBNET_REGION}"
other_vpc_list = [${OTHER_VPC_LIST}]
EOF
cat ${SCRIPT_DIR}/terraform.tfvars

log INFO "list vpc"
gcloud compute networks list --project=${GCP_PROJECT_ID}

log INFO "terraform version"
${TF_BINARY_DIR}/terraform version

log INFO "terraform init"
${TF_BINARY_DIR}/terraform init \
    -no-color \
    ${SCRIPT_DIR}

log "terraform-google-modules/cloud-dns/google this module has a bug in the outputs.tf if none of zones exists, it would raise exception"

log "display original buggy version of outputs.tf"
cat ${SCRIPT_DIR}/.terraform/modules/dns-private-zone/outputs.tf

log "replace a new version of outputs.tf "
cat > ${SCRIPT_DIR}/.terraform/modules/dns-private-zone/outputs.tf<<EOF
/**
 * Copyright 2019 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

output "type" {
  description = "The DNS zone type."
  value       = var.type
}

output "name" {
  description = "The DNS zone name."

  value = length(concat(
    google_dns_managed_zone.peering.*.name,
    google_dns_managed_zone.forwarding.*.name,
    google_dns_managed_zone.private.*.name,
    google_dns_managed_zone.public.*.name)) == 0 ? "" : element(
    concat(
      google_dns_managed_zone.peering.*.name,
      google_dns_managed_zone.forwarding.*.name,
      google_dns_managed_zone.private.*.name,
      google_dns_managed_zone.public.*.name
    ),
    0,
  )
}

output "domain" {
  description = "The DNS zone domain."

  value = length(concat(
    google_dns_managed_zone.peering.*.dns_name,
    google_dns_managed_zone.forwarding.*.dns_name,
    google_dns_managed_zone.private.*.dns_name,
    google_dns_managed_zone.public.*.dns_name
    )) == 0 ? "" : element(
    concat(
      google_dns_managed_zone.peering.*.dns_name,
      google_dns_managed_zone.forwarding.*.dns_name,
      google_dns_managed_zone.private.*.dns_name,
      google_dns_managed_zone.public.*.dns_name
    ),
    0,
  )
}

output "name_servers" {
  description = "The DNS zone name servers."

  value = length(concat(
    google_dns_managed_zone.peering.*.name_servers,
    google_dns_managed_zone.forwarding.*.name_servers,
    google_dns_managed_zone.private.*.name_servers,
    google_dns_managed_zone.public.*.name_servers
    )) == 0 ? [] : flatten(
    concat(
      google_dns_managed_zone.peering.*.name_servers,
      google_dns_managed_zone.forwarding.*.name_servers,
      google_dns_managed_zone.private.*.name_servers,
      google_dns_managed_zone.public.*.name_servers
    ),
  )
}
EOF
cat ${SCRIPT_DIR}/.terraform/modules/dns-private-zone/outputs.tf

log INFO "terraform plan"
${TF_BINARY_DIR}/terraform plan \
    -no-color \
    ${SCRIPT_DIR}

log INFO "terraform apply"
${TF_BINARY_DIR}/terraform apply \
    -no-color \
    -auto-approve \
    ${SCRIPT_DIR}

log INFO "list vpc"
gcloud compute networks list --project=${GCP_PROJECT_ID}

log INFO "list vpc in Cloud DNS private-access zone"
gcloud dns managed-zones describe private-access \
    --project=${GCP_PROJECT_ID} \
    --format="table(name,dnsName,privateVisibilityConfig.networks[].networkUrl)"

log INFO "add 2 new vpc"
gcloud compute networks create vpc1 \
    --project=${GCP_PROJECT_ID} \
    --bgp-routing-mode="regional" \
    --subnet-mode=custom
gcloud compute networks create vpc2 \
    --project=${GCP_PROJECT_ID} \
    --bgp-routing-mode="regional" \
    --subnet-mode=custom

log INFO "list vpc"
gcloud compute networks list --project=${GCP_PROJECT_ID}

log INFO "list vpc in Cloud DNS private-access zone"
gcloud dns managed-zones describe private-access \
    --project=${GCP_PROJECT_ID} \
    --format="table(name,dnsName,privateVisibilityConfig.networks[].networkUrl)"

export OTHER_VPC_LIST=$(printf "\"%s\"," $(gcloud compute networks list \
                                            --project=${GCP_PROJECT_ID} \
                                            --format="value(selfLink)" \
                                            --filter="name!=default-network"))

log INFO "prepare terraform.tfvars, new vpc will be passed into tf variable"
cat >${SCRIPT_DIR}/terraform.tfvars<<EOF
project = "${GCP_PROJECT_ID}"
region = "${VPC_SUBNET_REGION}"
other_vpc_list = [${OTHER_VPC_LIST}]
EOF
cat ${SCRIPT_DIR}/terraform.tfvars

log INFO "terraform version"
${TF_BINARY_DIR}/terraform version

log INFO "terraform init"
${TF_BINARY_DIR}/terraform init \
    -no-color \
    ${SCRIPT_DIR}

log INFO "terraform plan"
${TF_BINARY_DIR}/terraform plan \
    -no-color \
    ${SCRIPT_DIR}

log INFO "terraform apply"
${TF_BINARY_DIR}/terraform apply \
    -no-color \
    -auto-approve \
    ${SCRIPT_DIR}

log INFO "list vpc"
gcloud compute networks list --project=${GCP_PROJECT_ID}

log INFO "list vpc in Cloud DNS private-access zone"
gcloud dns managed-zones describe private-access \
    --project=${GCP_PROJECT_ID} \
    --format="table(name,dnsName,privateVisibilityConfig.networks[].networkUrl)"

log INFO "remove one vpc, add a new vpc and run terraform apply"
gcloud compute networks delete vpc1 --project=${GCP_PROJECT_ID} -q
gcloud compute networks create vpc3 \
    --project=${GCP_PROJECT_ID} \
    --bgp-routing-mode="regional" \
    --subnet-mode=custom

log INFO "list vpc"
gcloud compute networks list --project=${GCP_PROJECT_ID}

export OTHER_VPC_LIST=$(printf "\"%s\"," $(gcloud compute networks list \
                                            --project=${GCP_PROJECT_ID} \
                                            --format="value(selfLink)" \
                                            --filter="name!=default-network"))

log INFO "prepare terraform.tfvars, new vpc will be passed into tf variable"
cat >${SCRIPT_DIR}/terraform.tfvars<<EOF
project = "${GCP_PROJECT_ID}"
region = "${VPC_SUBNET_REGION}"
other_vpc_list = [${OTHER_VPC_LIST}]
EOF
cat ${SCRIPT_DIR}/terraform.tfvars

log INFO "terraform version"
${TF_BINARY_DIR}/terraform version

log INFO "terraform init"
${TF_BINARY_DIR}/terraform init \
    -no-color \
    ${SCRIPT_DIR}

log INFO "terraform plan"
${TF_BINARY_DIR}/terraform plan \
    -no-color \
    ${SCRIPT_DIR}

log INFO "terraform apply"
${TF_BINARY_DIR}/terraform apply \
    -no-color \
    -auto-approve \
    ${SCRIPT_DIR}

log INFO "list vpc"
gcloud compute networks list --project=${GCP_PROJECT_ID}

log INFO "list vpc in Cloud DNS private-access zone"
gcloud dns managed-zones describe private-access \
    --project=${GCP_PROJECT_ID} \
    --format="table(name,dnsName,privateVisibilityConfig.networks[].networkUrl)"

log INFO "as we can see from above 403 error, there is a bug in Cloud DNS private zone"
log INFO "if an obsolete VPC record is contained in private zone"
log INFO "when updating such private zone's network URL with new VPC, it would raise exception"
log INFO "there are 2 kinds of workaround to bypass this exception"
log INFO "Workaround 1: manually restore obsolete VPC with the same vpc name, remove vpc from private zone then delete vpc"
log INFO "Workaround 2: with an amended version of terraform gcp dns module outputs.tf, manually delete private zone then run terraform apply again"
log INFO "we are going to demonstrate workaround 2"
log INFO "Demonstrating workaround 2: delete the private zone"
touch empty-file
gcloud dns record-sets import -z private-access \
    --project=${GCP_PROJECT_ID} \
    --delete-all-existing \
    empty-file
rm empty-file
gcloud dns managed-zones delete private-access --project=${GCP_PROJECT_ID} -q

log INFO "Demonstrating workaround 2: run terraform plan and apply again"

log INFO "terraform plan"
${TF_BINARY_DIR}/terraform plan \
    -no-color \
    ${SCRIPT_DIR}

log INFO "terraform apply"
${TF_BINARY_DIR}/terraform apply \
    -no-color \
    -auto-approve \
    ${SCRIPT_DIR}


log INFO "list vpc"
gcloud compute networks list --project=${GCP_PROJECT_ID}

log INFO "list vpc in Cloud DNS private-access zone"
gcloud dns managed-zones describe private-access \
    --project=${GCP_PROJECT_ID} \
    --format="table(name,dnsName,privateVisibilityConfig.networks[].networkUrl)"

log INFO "tidy up"
tidy_up