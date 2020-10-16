# Introduction 
This script [run_tf_subnetwork.sh](run_tf_subnetwork.sh) is to test when terraform google provider plugin switches to beta version, 
what would happen to existing infrastructure created by [google_compute_subnetwork](https://www.terraform.io/docs/providers/google/r/compute_subnetwork.html)

# Conclusion 
Existing infrastructure created by [google_compute_subnetwork](https://www.terraform.io/docs/providers/google/r/compute_subnetwork.html) will remain unchanged when a terraform apply runs  