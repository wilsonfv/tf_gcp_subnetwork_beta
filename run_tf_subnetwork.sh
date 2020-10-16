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

function clean_up_vpc() {
    if [[ $(gcloud compute networks list \
            --project=${GCP_PROJECT_ID} \
            --filter="name=${VPC_NAME}" \
            --format="csv(NAME)[no-heading]") ]]; then
        for subnet in $(gcloud compute networks subnets list --filter="NETWORK:${VPC_NAME}" --format="csv(NAME,REGION)[no-heading]")
        do
            SUBNET_NAME=$(echo -n ${subnet} | cut -d, -f1)
            SUBNET_REGION=$(echo -n ${subnet} | cut -d, -f2)

            gcloud compute networks subnets delete ${SUBNET_NAME} --region ${SUBNET_REGION} -q
        done

        gcloud compute networks delete ${VPC_NAME} --project=${GCP_PROJECT_ID} -q
    fi
}
# **********************************************************************************************
# Main Flow
# **********************************************************************************************

export SCRIPT_DIR=$(dirname "$0")
export TF_BINARY_DIR=${SCRIPT_DIR}/tf_binary

log INFO "download terraform binary"
if [[ -d ${TF_BINARY_DIR} ]]; then
    rm -rf ${TF_BINARY_DIR}
fi
mkdir -p ${TF_BINARY_DIR}
get_tf_binary ${TF_BINARY_DIR} terraform                        0.12.13 darwin_amd64
get_tf_binary ${TF_BINARY_DIR} terraform-provider-google        2.17.0 darwin_amd64
get_tf_binary ${TF_BINARY_DIR} terraform-provider-google-beta   2.17.0 darwin_amd64

log INFO "terraform version"
${TF_BINARY_DIR}/terraform version

export GCP_PROJECT_ID=$(gcloud config list --format='value(core.project)')

if [[ ! -f ${GOOGLE_APPLICATION_CREDENTIALS} ]]; then
    log ERROR "Environment variable GOOGLE_APPLICATION_CREDENTIALS is not defined or file ${GOOGLE_APPLICATION_CREDENTIALS} does not exist"
    exit 1
fi
gcloud auth activate-service-account --key-file ${GOOGLE_APPLICATION_CREDENTIALS}

log INFO "create a vpc network"
export VPC_NAME="vpc-tfbeta"
export VPC_SUBNET_REGION="europe-west2"

clean_up_vpc
gcloud compute networks create ${VPC_NAME} \
    --project=${GCP_PROJECT_ID} \
    --bgp-routing-mode="regional" \
    --description=${VPC_NAME} \
    --subnet-mode=custom

log INFO "clean up terraform dir"
if [[ -d ${SCRIPT_DIR}/.terraform ]]; then
    rm -rf ${SCRIPT_DIR}/.terraform
fi

log INFO "prepare main.tf, 1st version of this file does not have properties: purpose and role which are explicitly for proxy-only subnet"
cat >${SCRIPT_DIR}/main.tf<<EOF
locals {
  subnets = {
    for subnet, value in var.subnets :
    subnet => {
      name : format("%s-%s-%s", value.network, value.region, subnet)
      description : value.description
      region : value.region
      network : value.network
      ip_cidr_range : value.ip_cidr_range
      private_ip_google_access : value.private_ip_google_access
      enable_flow_logs : true
      secondary_ip_ranges : [
        for name, cidr in value.secondary_ip_ranges :
        {
          range_name : name,
          ip_cidr_range : cidr
        }
      ]
    }
  }
}

resource "google_compute_subnetwork" "subnet" {
  for_each = local.subnets

  project                  = var.project
  network                  = each.value.network
  name                     = each.value.name
  description              = each.value.description
  region                   = each.value.region
  ip_cidr_range            = each.value.ip_cidr_range
  secondary_ip_range       = each.value.secondary_ip_ranges
  private_ip_google_access = each.value.private_ip_google_access
  enable_flow_logs         = each.value.enable_flow_logs
}
EOF
cat ${SCRIPT_DIR}/main.tf

log INFO "prepare vars.tf, 1st version of this file does not have properties: purpose and role which are explicitly for proxy-only subnet"
cat >${SCRIPT_DIR}/vars.tf<<EOF
variable "project" {
  description = "project ID"
  type        = string
}

variable "subnets" {
  description = "subnet objects"
  type = map(object(
    {
      network : string
      region : string
      description : string
      ip_cidr_range : string
      private_ip_google_access : bool
      secondary_ip_ranges : map(string)
    }
  ))
}
EOF
cat ${SCRIPT_DIR}/vars.tf

log INFO "prepare subnets.auto.tfvars.json which will create 2 normal subnets"
cat >${SCRIPT_DIR}/subnets.auto.tfvars.json<<EOF
{
    "subnets": {
        "gkenodes": {
            "network": "${VPC_NAME}",
            "region": "${VPC_SUBNET_REGION}",
            "description": "gkenodes",
            "ip_cidr_range": "192.168.192.0/23",
            "private_ip_google_access": true,
            "secondary_ip_ranges": {
                "gkepods": "192.168.128.0/19",
                "gkeservices": "192.168.208.0/21"
            }
        },
        "net1": {
            "network": "${VPC_NAME}",
            "region": "${VPC_SUBNET_REGION}",
            "description": "net1",
            "ip_cidr_range": "192.168.0.0/20",
            "private_ip_google_access": true,
            "secondary_ip_ranges": {}
        }
    }
}
EOF
cat ${SCRIPT_DIR}/subnets.auto.tfvars.json

log INFO "terraform init"
${TF_BINARY_DIR}/terraform init ${SCRIPT_DIR}

log INFO "terraform plan"
${TF_BINARY_DIR}/terraform plan \
    -var="project=${GCP_PROJECT_ID}" \
    ${SCRIPT_DIR}

log INFO "terraform apply"
${TF_BINARY_DIR}/terraform apply \
    -var="project=${GCP_PROJECT_ID}" \
    -auto-approve \
    ${SCRIPT_DIR}

log INFO "list subnets"
gcloud compute networks subnets list --filter="NETWORK:${VPC_NAME}"

log INFO "change terraform module to add support for proxy-only subnets"
log INFO "prepare main.tf, add google beta provider to main.tf"
cat >${SCRIPT_DIR}/main.tf<<EOF
locals {
  subnets = {
    for subnet, value in var.subnets :
    subnet => {
      name : format("%s-%s-%s", value.network, value.region, subnet)
      description : value.description
      region : value.region
      network : value.network
      ip_cidr_range : value.ip_cidr_range
      private_ip_google_access : value.private_ip_google_access
      enable_flow_logs : value.purpose == "INTERNAL_HTTPS_LOAD_BALANCER" ? false : true
      secondary_ip_ranges : [
        for name, cidr in value.secondary_ip_ranges :
        {
          range_name : name,
          ip_cidr_range : cidr
        }
      ]
      purpose: value.purpose
      role: value.role
    }
  }
}

resource "google_compute_subnetwork" "subnet" {
  provider = google-beta
  for_each = local.subnets

  project                  = var.project
  network                  = each.value.network
  name                     = each.value.name
  description              = each.value.description
  region                   = each.value.region
  ip_cidr_range            = each.value.ip_cidr_range
  secondary_ip_range       = each.value.secondary_ip_ranges
  private_ip_google_access = each.value.private_ip_google_access
  enable_flow_logs         = each.value.enable_flow_logs
  purpose                  = each.value.purpose
  role                     = each.value.role
}
EOF
cat ${SCRIPT_DIR}/main.tf

log INFO "prepare vars.tf, add properties purpose and role"
cat >${SCRIPT_DIR}/vars.tf<<EOF
variable "project" {
  description = "project ID"
  type        = string
}

variable "subnets" {
  description = "subnet objects"
  type = map(object(
    {
      network : string
      region : string
      description : string
      ip_cidr_range : string
      private_ip_google_access : bool
      secondary_ip_ranges : map(string)
      purpose : string
      role : string
    }
  ))
}
EOF
cat ${SCRIPT_DIR}/vars.tf

log INFO "prepare subnets.auto.tfvars.json which will maintain existing 2 normal subnets, create 1 normal and 2 proxy-only subnets"
cat >${SCRIPT_DIR}/subnets.auto.tfvars.json<<EOF
{
    "subnets": {
        "gkenodes": {
            "network": "${VPC_NAME}",
            "region": "${VPC_SUBNET_REGION}",
            "description": "gkenodes",
            "ip_cidr_range": "192.168.192.0/23",
            "private_ip_google_access": true,
            "secondary_ip_ranges": {
                "gkepods": "192.168.128.0/19",
                "gkeservices": "192.168.208.0/21"
            },
            "purpose": "",
            "role": ""
        },
        "net1": {
            "network": "${VPC_NAME}",
            "region": "${VPC_SUBNET_REGION}",
            "description": "net1",
            "ip_cidr_range": "192.168.0.0/20",
            "private_ip_google_access": true,
            "secondary_ip_ranges": {},
            "purpose": "",
            "role": ""
        },
        "net2": {
            "network": "${VPC_NAME}",
            "region": "${VPC_SUBNET_REGION}",
            "description": "net2",
            "ip_cidr_range": "192.168.32.0/20",
            "private_ip_google_access": true,
            "secondary_ip_ranges": {},
            "purpose": "",
            "role": ""
        },
        "lb1": {
            "network": "${VPC_NAME}",
            "region": "${VPC_SUBNET_REGION}",
            "description": "lb1",
            "ip_cidr_range": "192.168.230.0/24",
            "private_ip_google_access": false,
            "secondary_ip_ranges": {},
            "purpose": "INTERNAL_HTTPS_LOAD_BALANCER",
            "role": "ACTIVE"
        },
        "lb2": {
            "network": "${VPC_NAME}",
            "region": "${VPC_SUBNET_REGION}",
            "description": "lb2",
            "ip_cidr_range": "192.168.231.0/24",
            "private_ip_google_access": false,
            "secondary_ip_ranges": {},
            "purpose": "INTERNAL_HTTPS_LOAD_BALANCER",
            "role": "BACKUP"
        }
    }
}
EOF
cat ${SCRIPT_DIR}/subnets.auto.tfvars.json

#log INFO "upgrade terraform to support proxy-only subnet"
#get_tf_binary ${TF_BINARY_DIR} terraform-provider-google        2.17.0 darwin_amd64
#get_tf_binary ${TF_BINARY_DIR} terraform-provider-google-beta   2.17.0 darwin_amd64

log INFO "terraform version"
${TF_BINARY_DIR}/terraform version

log INFO "terraform init"
${TF_BINARY_DIR}/terraform init ${SCRIPT_DIR}

log INFO "terraform plan"
${TF_BINARY_DIR}/terraform plan \
    -var="project=${GCP_PROJECT_ID}" \
    ${SCRIPT_DIR}

log INFO "terraform apply"
${TF_BINARY_DIR}/terraform apply \
    -var="project=${GCP_PROJECT_ID}" \
    -auto-approve \
    ${SCRIPT_DIR}

log INFO "list subnets"
gcloud compute networks subnets list --filter="NETWORK:${VPC_NAME}"

clean_up_vpc