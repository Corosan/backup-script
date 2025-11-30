# Purpose

How to backup an ordinary linux system? Usually it's enough to boot from some life CD, find
partitions where efi, boot and system areas are located and to make tarballs on them (possibly with
storing various extended attributes of the files). The task for searching and mounting the
partitions can be annoying a little bit. Furthermore the partitions can be located on encrypted
drive, which make these things even more annoying. This script is intended to execute these steps
automatically based on a description in a simple ini file. Or, more precisely, semi-automatically,
because entering a password for encrypted device is still manual operation.

Created tarballs are placed into another 'area' which can be the same disk inside the machine or
for instance a removable drive for storing backups.

The script works in accordance with a description from the configuration 'profile.ini' file which a
user has to create from provided sample file. See the sample for an explanation of existing
options.

The script is not intended to be run on a live system. Typical scenario is to place the script
together with the configuration file onto a removable drive having some Linux LiveCD, boot from it
and run the script.
