#!/bin/bash

# (c) 2023 Vyacheslav V. Grigoryev <armagvvg@gmail.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of version 3 of the GNU General Public
# License published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

set -e
set -o pipefail

declare -r prog_name=$(basename "$BASH_SOURCE")
declare -r cfg_path=$(dirname "$BASH_SOURCE")/profile.ini

declare -A mountpoints=()
declare -a finalizers=()
keep_tmp_dir=0
debug_mode=0
tmpdir_for_mounts=

function die {
  echo "$1" >&2
  exit 1
}

# Usage scenario doesn't describe a --debug option intended for internal usage:
#  --debug N  - do not make real archiving, simulate. N=1 do not even make
#               operations requiring root privileges like mounting. N=2 - make
#               mounting/unmounting but do not make archiving. Instead of archiving
#               a dummy script is created and executed which dumps expected
#               archving command line, sleeps and fails in a couple of scenarios

function usage {
  cat <<EOF
Simple backup utility for archiving a number of 'areas'. The 'area' term means
a partition containing some filesystem structure which needs to be archived. There
can be a few areas on the same partition. All parameters including areas are
described in a properties file 'profile.ini' located near this script.

                             (c) 2023 Vyacheslav V. Grigoryev <armagvvg@gmail.com>

Usage: ${prog_name} [OPTIONS]

Options:
  -h, --help - this help message
EOF
  }

# Return a value for a key $1 from a ini-like properties file. If $2 is specified it points to
# a section inside the file.
function get_prop_value {
  local key=$1 k
  local section=$2
  local curr_section= v
  local line_n=0

  [[ -n $key ]] || return

  while read line; do
    line_n=$(( line_n + 1 ))
    [[ $line =~ ^[[:space:]]*# || -z $line ]] && continue
    [[ $line == "["*"]" ]] && { \
      curr_section=${line#"["}
      curr_section=${curr_section%"]"}
      continue
    }
    [ "$curr_section" != "$section" ] && continue
    if [[ ! $line =~ = ]]; then
      echo "wrong line $line_n in the config '$cfg_path' - there is no key-value separator '='" >&2
      return 1
    fi
    k=${line%%=*}
    [ "$key" = "${k%${k##*[! ]}}" ] || continue
    v=${line#*=}
    echo "${v#${v%%[! ]*}}"
    break
  done < "$cfg_path"
}

# Split an input string $1 by a separator $3 or comma by default. Separate values can't contain
# a separator even escaped. An output is assigned to an array variable which name is placed into $2
function split_by_sep {
  local str=$1
  local out_var=$2
  local sep=$3
  local old_ifs v
  local -a v_out=()

  [[ -n $out_var ]] || return
  [[ -n $sep ]] || sep=,

  local old_ifs=$IFS
  IFS=$sep
  for v in $str; do
    v="${v#${v%%[! ]*}}"
    v="${v%${v##*[! ]}}"
    v_out+=("$v")
  done
  IFS=$old_ifs
  eval $out_var='("${v_out[@]}")'
}

function expand_classified_number {
  local str=$1
  local mult=1

  if [[ $str == *k || $str == *K ]]; then
    str=${str%[kK]}
    mult=1024
  elif [[ $str == *m || $str == *M ]]; then
    str=${str%[mM]}
    mult=$((1024*1024))
  elif [[ $str == *g || $str == *G ]]; then
    str=${str%[gG]}
    mult=$((1024*1024*1024))
  fi

  if [[ $(( $str )) != "${str%${str##*[! ]}}" ]]; then
    echo "not a number has been provided - '$1'" >&2
    return 1
  fi

  echo $(( $str * $mult ))
}

# Replace all keys in a string $1 with values provided in a form of key=value arguments,
# for example: replace_placeholders "the-string-{date}-{time}-ok" "date=20231010" "time=30:30:40"
function replace_placeholders {
  local str=$1
  local k v

  shift
  for arg in "$@"; do
    k=${arg%%=*}
    v=${arg#*=}
    while [[ $str == *{$k}* ]]; do
      str=${str%%"{$k}"*}$v${str#*"{$k}"}
    done
  done
  echo $str
}

# Check if specified area $1 is mounted and try to mount it if not. The function reads a partition
# uuid of provided area from properties. If the uuid can't be found, it checks for crypto partition
# uuid assuming that it contains the former either as simple direct file system or as a part of
# lvm group.
function ensure_part_mounted {
  local area=$1
  local uuid crypt_uuid tmp
  local crypt_opened=0

  uuid=$(get_prop_value part_uuid "$area")

  [[ -n $area && -n $uuid ]] || { echo "no uuid for area '$area' configured" >&2; return 1; }

  while true; do
    tmp=($(lsblk -o UUID,PATH,MOUNTPOINT | sed -n "s/^$uuid\\s\\+//p"))
    if [[ ${#tmp[*]} -eq 2 ]]; then
      echo "found a mount path ${tmp[1]} for area '$area'"
      mountpoints[$area]=${tmp[1]}
      # even if automounting happened for an encrypted device when the script opened it and
      # a mountpoint has been found without direct mounting - add unmounting step into finalizers
      # in order to successfully close the encrypted device at the end
      if [[ $crypt_opened -eq 1 ]]; then
        finalizers+=("umount -v \"${tmp[1]}\"")
      fi
      return
    elif [[ ${#tmp[*]} -eq 1 ]]; then
      echo "found a device path ${tmp[0]} for area '$area', but no mount point - mounting"
      local mnt_path=$tmpdir_for_mounts/${area// /_}
      mkdir -p "$mnt_path"
      mount -v "${tmp[0]}" "$mnt_path"
      mountpoints[$area]=$mnt_path
      finalizers+=("umount -v \"$mnt_path\"")
      return
    elif [[ $crypt_opened -eq 0 ]]; then
      crypt_uuid=$(get_prop_value crypt_part_uuid "$area")
      if [[ -n ${crypt_uuid} ]]; then
        echo "found crypto drive for area '$area', trying to open it"
        tmp=$(lsblk -o UUID,PATH | sed -n "s/^${crypt_uuid}\\s\\+//p")
        [[ -n $tmp ]] || { echo "not found a device path for crypto drive uuid=$crypt_uuid" >&2; return 1; }
        cryptsetup open "$tmp" "${area// /_}_disk"
        finalizers+=("cryptsetup close \"${area// /_}_disk\"")
        # if the opened encrypted device contains an LVM physical volume belonging to a
        # volume group, the group needs to be activated now (though it can be done automatically)
        # and deactivated at the end
        tmp=$(lsblk -o PATH,FSTYPE | sed -n "s@/dev/mapper/${area// /_}_disk\\s\\+@@p")
        if [[ $tmp == LVM2_member ]]; then
          echo "found LVM2_member, activating volume group"
          tmp=$(pvdisplay "/dev/mapper/${area// /_}_disk" | sed -n 's/\s\+VG Name\s\+\(.*\)/\1/p')
          [[ -n $tmp ]] || { echo "unable to determine the volume group name" >&2; return 1; }
          vgchange -ay "$tmp"
          finalizers+=("vgchange -an \"$tmp\"")
        fi
        crypt_opened=1
        continue
      fi
    fi

    echo "not enough data to mount area '$area'" >&2
    return 1
  done
}

function remove_mounts_dir {
  local tmp_dir=$1
  if [[ $debug_mode -ne 0 ]]; then
    if [[ $keep_tmp_dir -eq 1 ]]; then
      echo "simulating: something requested to keep temporary mounts directory $tmp_dir"
    else
      echo "simulating: need to remote temporary mounts directory but wouldn't do it in this mode: $tmp_dir"
    fi
  else
    if [[ $keep_tmp_dir -eq 0 ]]; then
      echo "removing temporary mounts directory $tmp_dir"
      rm -r --one-file-system "$tmp_dir"
    fi
  fi
}

function term_children {
  for p in "${!pids_to_wait[@]}"; do
    /usr/bin/kill -TERM -- -$p
  done
}

function finalize_fcn {
  for (( i = ${#finalizers[*]}; i != 0; --i )); do
    eval "${finalizers[$i-1]}"
  done
}

trap finalize_fcn 0

# Sanity checks

ret_code=0
getopt -T || ret_code=$?
[[ $ret_code -eq 4 ]] || die "unsupported version of getopt found"

[[ ${BASH_VERSINFO[0]} -ge 5 ]] || die "too old bash interpreter version"

# Handing command line arguments

OPTS=$(getopt -n "$prog_name" -o h -l help,debug: -- "$@")
eval set -- "$OPTS"

while true; do
  case "$1" in
    -h|--help)
      usage; exit 0;;
    --debug)
      debug_mode=$2; shift 2;;
    --)
      shift; break;;
    *)
      die "internal error";;
  esac
done

[[ -f $cfg_path ]] || \
  die "there is no properties file $cfg_path"

split_by_sep "$(get_prop_value areas)" areas
[[ ${#areas[@]} -gt 0 ]] || die "there are no areas to backup"
for a in "${areas[@]}"; do
  [[ -n $(get_prop_value part_uuid "$a") ]] || \
    die "there is no mandatory 'part_uuid' parameter for area '$a'"
done

[[ -n $(get_prop_value part_uuid destination) ]] || \
  die "there is no mandatory 'part_uuid' parameter for destination area"
template_arch_name=$(get_prop_value template_arch_name destination)
[[ -n $template_arch_name && $template_arch_name == *{area}* ]] || \
  die "there is no mandatory 'template_arch_name' parameter for destination area \
or it doesn't contain {area} placeholder"

tmpdir_for_mounts=$(mktemp -d)
finalizers+=("remove_mounts_dir \"$tmpdir_for_mounts\"")
echo "mount points (if any) will be hold in $tmpdir_for_mounts"

# Mount all partitions pointed by areas to be archived
if [[ $debug_mode -ne 1 ]]; then
  for area in "${areas[@]}" destination; do
    ensure_part_mounted "$area"
  done
else
  for area in "${areas[@]}" destination; do
    mountpoints[$area]=$tmpdir_for_mounts/dummy_${area// /_}_dir
    mkdir -p "${mountpoints[$area]}"
  done
fi

dest_path=$(get_prop_value dir destination)
dest_path=${mountpoints[destination]}${dest_path:+/${dest_path}}
mkdir -p "$dest_path"

# Check available size on the destination area
avail_size=$(( $(df --output=avail "$dest_path" | tail -n +2) * 1024 ))
min_dest_size=$(get_prop_value min_size_available destination)
if [[ $debug_mode -ne 1 && -n $min_dest_size ]]; then
  min_dest_size=$(expand_classified_number "$min_dest_size")
  [[ $avail_size -ge $min_dest_size ]] || \
    die "insufficient size at destination path '$dest_path' - $(( avail_size / 1024 / 1024 ))M"
fi

echo "available size on destination drive: $(( avail_size / 1024 / 1024 ))M"

# Determine a pattern for destination names for archives and check that they don't overwrite
# anything alreay existing on a destination drive
suff=
curr_date=$(date +%Y%m%d)
while true; do
  for area in "${areas[@]}"; do
    arch_name=$(replace_placeholders "$template_arch_name" "area=$area" "date=$curr_date")$suff
    [[ -f $dest_path/$arch_name.tar.bz2 ]] && { suff=${suff}_; break; }
  done
  if [ "${suff%_}" = "${suff}" ]; then
    # Finally reintegrate the suffix and the date inside the template
    template_arch_name=$(replace_placeholders "$template_arch_name" "date=$curr_date")$suff
    break
  fi
  [ -z "$suff" ] && suff=-1 || { suff=${suff%_}; suff=-$(( ${suff#-} + 1 )); }
done

if [[ $debug_mode -ne 0 ]]; then
  cat >"$dest_path/dummy-exec.sh" <<EOF
#!/bin/bash

for a in "\$@"; do
  echo "arg: -=\$a=-"
done
sleep 5
[[ \$1 == "--fail" ]] && exit 1
exit 0
EOF
  chmod u+x "$dest_path/dummy-exec.sh"
fi

trap term_children SIGINT

# Starting to archive all the partitions in parallel using bash background jobs.
# Coprocessors would be more suitable for this but due to a bug only one coprocessor
# can be created unfortunatelly. Logs are made in order to find later what files an
# archive contains because it's too compute-intensive to list tar.xxx archives
declare -A pids_to_wait=()
declare -a files_to_cleanup_on_interrupt=()
for area in "${areas[@]}"; do
  log_path=$dest_path/$(replace_placeholders "$template_arch_name" "area=$area").log
  echo "--- starting to archive '$area' area, log: $log_path"
  root_dir=$(get_prop_value root_dir "$area")
  paths=$(get_prop_value paths "$area")
  excludes=$(get_prop_value excludes "$area")
  [[ -n $paths ]] || paths=.
  split_by_sep "$paths" paths
  dest_paths=()
  for p in "${paths[@]}"; do
    dest_paths+=("${p#/}")
  done
  split_by_sep "$excludes" excludes
  dest_excludes=()
  for p in "${excludes[@]}"; do
    dest_excludes+=("--exclude=$p")
  done

  if [[ $debug_mode -eq 0 ]]; then
    cmd=(tar)
  elif [[ ${#pids_to_wait[@]} -le 1 ]]; then
    cmd=("$dest_path/dummy-exec.sh")
  else
    cmd=("$dest_path/dummy-exec.sh" --fail)
  fi

  arch_path=$dest_path/$(replace_placeholders "$template_arch_name" "area=$area").tar.bz2
  files_to_cleanup_on_interrupt+=("$log_path" "${arch_path}")

  cmd+=(-cvjf "$arch_path" \
    --acls --xattrs --one-file-system -p -C "${mountpoints[$area]}${root_dir:+/${root_dir}}" \
    "${dest_excludes[@]}" "${dest_paths[@]}")

  # Bash has a feature called job control which allows to put tasks in background and control them
  # by dedicated commands. The tasks are placed into separate process groups in this way.  This
  # feature works only when a user executes a task with '&' from an interactive shell.  But when the
  # same command line with '&' at the end is executed by another script, the job control feature is
  # turned off. The task is placed in the same process group. Moreover SIGINT and SIGQUIT handlers
  # in each process of the task are masked out (see part 3.7.6 "Signals" of bash info). How to abort
  # tasks by pressing Ctrl+C in this way? One approach is to kill background processes by their pids
  # issuing some non-masked signal, for instance SIGTERM. But those processes can create any number
  # of children too. The scripts needs to track the whole hierarchy for example with 'ps' tool. More
  # robust way is to place all the tasks into separate process group and send a termination signal
  # into that group as whole. There is no clear way to place all the tasks into the same process
  # group from a shell but a 'setsid' helper exists which allows to run a command under new session
  # id.  The command has to be in a new process group as a consequence.
  setsid "${cmd[@]}" &>"$log_path" &
  pids_to_wait+=($! "${area}_+_$log_path")
done

final_ret_code=0
while [[ ${#pids_to_wait[@]} -gt 0 ]]; do
  ret_code=0
  wait -n -p cur_pid "${!pids_to_wait[@]}" || ret_code=$?
  if [[ $ret_code -ge 128 ]]; then
    echo "interrupted by user"
    for f in "${files_to_cleanup_on_interrupt[@]}"; do
      [[ -f $f ]] && rm -v "$f"
    done
    trap - SIGINT
    kill -s SIGINT $$
  fi
  area=${pids_to_wait[$cur_pid]}
  unset pids_to_wait[$cur_pid]
  log_path=${area#*_+_}
  area=${area%%_+_*}
  if [[ $ret_code -gt 0 ]]; then
    echo "archiving partition at area '$area' finished with error code $ret_code, see log at $log_path"
    final_ret_code=2
    keep_tmp_dir=1
  else
    echo "finished with archiving partition at area '$area'"
    bzip2 "$log_path"
    files_to_cleanup_on_interrupt+=("${log_path}.bz2")
  fi
done

if [[ $final_ret_code -eq 0 ]]; then
  echo "--- done"
else
  echo "--- finished with errors"
fi
exit $final_ret_code
