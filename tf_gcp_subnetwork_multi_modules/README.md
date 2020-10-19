# Introduction 
This script [run_tf_subnetwork_multiple_modules.sh](run_tf_subnetwork_multiple_modules.sh) is to test 
how we could create a proxy-only subnet re-using existing module and do not break existing infrastructure

# Conclusion 
Since BACKUP proxy-only subnets depend on ACTIVE proxy-only subnets, 
that's why we have two new modules to create proxy-only-subnets, one for ACTIVE and the other for BACKUP.  