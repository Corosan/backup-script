  [Purpose]

How to backup an ordinary linux system? Usually it's enough to boot from some life CD, find
partitions where efi, boot and system areas are located and to make tarballs on them (possibly with
storing various extended attributes of the files). The task for searching and mounting the
partitions can be annoying a little bit. Furthermore the partitions can be located on encrypted
drive, which make these things even more annoying. This script is intended to execute these steps
automatically based on a description in simple ini file.

Created tarballs are placed into another 'area' which can be the same disk inside the machine or for
instance a removable drive for storing backups.

The script works according to description from a configuration 'profile.ini' file which a user has
to create from a sample provided. See the sample for an explanation of existing options.


  [Proposal for implementation]

1. Create temporary dir [d1] for mounts in TMPDIR.

2. Find efi partition by uuid and ensure it's mounted.
2.1. Check if it's mounted already. If not, mount and memorize [mount_point_1] for unmounting later.

3. Find boot partition by uuid and ensure it's mounted.
3.1. If not found, check if there is an additional info about crypto-partition where it's located
3.1.1 If the crypto-partition is specified, whether it's opened? If not, open it (asking a password)
and memorize [crypt_part_to_close] for closing it later. Don't forget to deactivate all volume
groups on it before closing.
3.2. Check if it's mounted already. If not, mount and memorize [mount_point_2] for unmounting later.

3. Find system partition by uuid and ensure it's mounted. Similarly to p.2.

4. Find destitation partition by uuid and ensure it's mounted. Similarly to p.2.

5. Check that backup partition has at least 15Gb. If not, aborting.

6. Archive efi, boot and system partitions one by one into backup partition.

7. Execute all memorized actions in reverse order.


  [Current state]

Now the script is powered by a configuration file having any number of 'area' description blocks,
not just 'efi', 'boot' and 'system'. A user doesn't need to modify the script itself.
