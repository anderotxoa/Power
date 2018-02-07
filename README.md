# Power
Power architecture  &amp; Linux related stuff

VIOclone2.sh

This script creates a config file to store (and backup) a VIO server configuration.
It then creates teh necessary commands to recreate the config in case you need it.

VIOclone2                      #Shows this output.
VIOclone2 -b                   #Builds the master config file on local filesystem.
VIOclone2 -s [ SANMASTERfile ] #Creates a text file with COMMANDS to replicate the STORAGE config located in the master file.
VIOclone2 -n [ NETMASTERfile ] #Creates a text file with COMMANDS to replicate the NETWORK config located in the master file.
