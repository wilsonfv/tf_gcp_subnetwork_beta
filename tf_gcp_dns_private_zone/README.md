# Introduction
This script [run_tf_add_vpc_to_dns_zone](run_tf_add_vpc_to_dns_zone.sh) is to test 
we could pass vpc self links as input variable to terraform module and add these VPCs
into Cloud DNS private zone

# Conclusion
As we can see from the [log file](run_tf_add_vpc_to_dns_zone.log), 
we can prepare a terraform input variable with a list of vpc network URLs to be passed into [terraform gcp cloud dns module](https://registry.terraform.io/modules/terraform-google-modules/cloud-dns/google/latest) <br/>

terraform variable to add vpc network into private zone looks like below 
```
project = "..."
region = "europe-west2"
vpc_list = ["https://www.googleapis.com/compute/v1/projects/.../global/networks/vpc1",
            "https://www.googleapis.com/compute/v1/projects/gke-eu-1/global/networks/vpc2",]
```

#### GCP Cloud DNS Bug
There is a bug in GCP Cloud DNS, if an obsolete VPC record is contained in private zone, 
when updating such private zone's network URL with new VPC, 
it would raise exception. <br/>

there are 2 kinds of workaround to bypass this exception
* Workaround 1: manually restore obsolete VPC with the same vpc name, remove vpc from private zone then delete vpc
* Workaround 2: with an amended version of terraform gcp dns module outputs.tf, manually delete private zone then run terraform apply again

Workaround 1 requires more manual steps and not straight forward.
While workaround 2 is less manual and more straight forward 
however it requires us to enhance existing gcp tf cloud dns module. <br/>
We will need to amend the outputs.tf like below
```
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
```