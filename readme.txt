  [Purpose]

1. To make archives from disk partitions responsible for system loading. These are: efi, boot,
system. Wherever they are located (too widely, so as far I know where they are).

2. Fixed list of exclusions from the system partition would be hard-coded inside the script. Upd:
now they are provided as properties of 'area' definition in a profile.ini (see comments in
profile.ini.sample).

3. The archives should be placed on an additional encrypted volume (by default) or on external
drive.


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
