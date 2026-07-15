package PVE::Storage::LunCmd::NVMET;

use v5.36;

use PVE::Tools qw(run_command trim);

my @ssh_opts = ('-o', 'BatchMode=yes');
my @ssh_cmd = ('/usr/bin/ssh', @ssh_opts);
my $id_rsa_path = '/etc/pve/priv/zfs';

my $REMOTE_HELPER = <<'REMOTE_HELPER';
set -euo pipefail

ROOT=/sys/kernel/config/nvmet
MODEL='Proxmox ZFS NVMe'
PROP_SUBSYS='proxmox:nvme-subsys'
PROP_NSID='proxmox:nvme-nsid'
PROP_UUID='proxmox:nvme-uuid'

die() {
    echo "$*" >&2
    exit 1
}

validate_nqn() {
    local value="$1"
    [[ "$value" =~ ^nqn\.[A-Za-z0-9][A-Za-z0-9.-]*:[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] ||
        die "invalid NQN"
    ((${#value} <= 223)) || die "NQN is too long"
}

validate_pool() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.:/-]*$ ]] || die "invalid ZFS pool name"
}

validate_device() {
    [[ "$1" =~ ^/dev/zvol/[A-Za-z0-9][A-Za-z0-9_.:/-]*$ ]] ||
        die "invalid zvol device path"
}

validate_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
        die "invalid namespace UUID"
}

prepare_configfs() {
    modprobe nvmet_tcp
    if ! mountpoint -q /sys/kernel/config; then
        mount -t configfs none /sys/kernel/config
    fi
    [[ -d "$ROOT/subsystems" && -d "$ROOT/ports" && -d "$ROOT/hosts" ]] ||
        die "NVMe target configfs is unavailable"

    install -d -m 0755 /run/lock
    exec 9>/run/lock/pve-nvmet.lock
    flock -w 30 9 || die "timed out waiting for NVMe target configuration lock"
}

ensure_subsystem() {
    local nqn="$1"
    local subsystem="$ROOT/subsystems/$nqn"
    local serial

    validate_nqn "$nqn"
    serial="PVEZFS$(printf '%s' "$nqn" | sha256sum | cut -c1-14)"

    if [[ ! -d "$subsystem" ]]; then
        mkdir "$subsystem"
        printf '%s\n' "$MODEL" >"$subsystem/attr_model"
        printf '%s\n' "$serial" >"$subsystem/attr_serial"
    else
        local current_model current_serial
        current_model="$(<"$subsystem/attr_model")"
        current_serial="$(<"$subsystem/attr_serial")"
        if [[ "$current_model" != "$MODEL" || "$current_serial" != "$serial" ]]; then
            if find "$subsystem/namespaces" -mindepth 1 -maxdepth 1 -type d -print -quit |
                grep -q .; then
                die "refusing to take over existing NVMe subsystem '$nqn'"
            fi
            printf '%s\n' "$MODEL" >"$subsystem/attr_model"
            printf '%s\n' "$serial" >"$subsystem/attr_serial"
        fi
    fi

    printf '0\n' >"$subsystem/attr_allow_any_host"
}

find_port() {
    local family="$1"
    local address="$2"
    local service="$3"
    local port

    for port in "$ROOT"/ports/*; do
        [[ -d "$port" ]] || continue
        [[ "$(<"$port/addr_trtype")" == tcp ]] || continue
        [[ "$(<"$port/addr_adrfam")" == "$family" ]] || continue
        [[ "$(<"$port/addr_traddr")" == "$address" ]] || continue
        [[ "$(<"$port/addr_trsvcid")" == "$service" ]] || continue
        basename "$port"
        return 0
    done
    return 1
}

allocate_port_id() {
    local id=1
    while [[ -e "$ROOT/ports/$id" ]]; do
        ((id++))
    done
    printf '%s\n' "$id"
}

ensure_port() {
    local nqn="$1"
    local spec="$2"
    local family address service id port

    IFS=, read -r family address service <<<"$spec"
    [[ "$family" == ipv4 || "$family" == ipv6 ]] || die "invalid address family"
    [[ "$service" =~ ^[0-9]{1,5}$ ]] || die "invalid NVMe/TCP service"
    ((service >= 1 && service <= 65535)) || die "invalid NVMe/TCP service"
    if [[ "$family" == ipv4 ]]; then
        [[ "$address" =~ ^[0-9.]+$ ]] || die "invalid IPv4 target address"
    else
        [[ "$address" =~ ^[0-9a-fA-F:]+$ ]] || die "invalid IPv6 target address"
    fi

    id="$(find_port "$family" "$address" "$service" || true)"
    if [[ -z "$id" ]]; then
        id="$(allocate_port_id)"
        port="$ROOT/ports/$id"
        mkdir "$port"
        printf 'tcp\n' >"$port/addr_trtype"
        printf '%s\n' "$family" >"$port/addr_adrfam"
        printf '%s\n' "$address" >"$port/addr_traddr"
        printf '%s\n' "$service" >"$port/addr_trsvcid"
    fi

    port="$ROOT/ports/$id"
    if [[ ! -e "$port/subsystems/$nqn" ]]; then
        ln -s "$ROOT/subsystems/$nqn" "$port/subsystems/$nqn"
    fi
    printf '%s\n' "$id"
}

ensure_target() {
    local nqn="$1"
    local pool="$2"
    shift 2
    local spec id port desired_ports=''

    validate_nqn "$nqn"
    validate_pool "$pool"
    (($# >= 1)) || die "at least one NVMe/TCP portal is required"
    ensure_subsystem "$nqn"

    for spec in "$@"; do
        id="$(ensure_port "$nqn" "$spec")"
        desired_ports="$desired_ports $id"
    done

    for port in "$ROOT"/ports/*; do
        [[ -d "$port" && -L "$port/subsystems/$nqn" ]] || continue
        id="$(basename "$port")"
        case " $desired_ports " in
            *" $id "*) ;;
            *) rm "$port/subsystems/$nqn" ;;
        esac
    done
}

ensure_host() {
    local nqn="$1"
    local hostnqn="$2"
    validate_nqn "$nqn"
    validate_nqn "$hostnqn"
    [[ -d "$ROOT/subsystems/$nqn" ]] || die "NVMe subsystem does not exist"
    [[ -d "$ROOT/hosts/$hostnqn" ]] || mkdir "$ROOT/hosts/$hostnqn"
}

allow_host() {
    local nqn="$1"
    local hostnqn="$2"
    validate_nqn "$nqn"
    validate_nqn "$hostnqn"
    [[ -d "$ROOT/hosts/$hostnqn" ]] || die "NVMe host does not exist"
    if [[ ! -e "$ROOT/subsystems/$nqn/allowed_hosts/$hostnqn" ]]; then
        ln -s "$ROOT/hosts/$hostnqn" "$ROOT/subsystems/$nqn/allowed_hosts/$hostnqn"
    fi
}

list_volumes() {
    local pool="$1"
    local dataset property value source
    declare -A datasets=()
    declare -A subsystems=()
    declare -A nsids=()
    declare -A uuids=()

    while IFS=$'\t' read -r dataset property value source; do
        datasets["$dataset"]=1
        if [[ "$source" != local && "$source" != received ]]; then
            value='-'
        fi
        case "$property" in
            "$PROP_SUBSYS") subsystems["$dataset"]="$value" ;;
            "$PROP_NSID") nsids["$dataset"]="$value" ;;
            "$PROP_UUID") uuids["$dataset"]="$value" ;;
        esac
    done < <(
        zfs get -H -r -t volume -o name,property,value,source \
            "$PROP_SUBSYS,$PROP_NSID,$PROP_UUID" "$pool"
    )

    for dataset in "${!datasets[@]}"; do
        printf '%s\t%s\t%s\t%s\n' \
            "$dataset" \
            "${subsystems[$dataset]:--}" \
            "${nsids[$dataset]:--}" \
            "${uuids[$dataset]:--}"
    done
}

property_value() {
    local property="$1"
    local dataset="$2"
    local output value source
    output="$(zfs get -H -o value,source "$property" "$dataset" 2>/dev/null || true)"
    IFS=$'\t' read -r value source <<<"$output"
    if [[ -z "$value" || ("$source" != local && "$source" != received) ]]; then
        value='-'
    fi
    printf '%s\n' "$value"
}

identity_is_duplicate() {
    local pool="$1"
    local dataset="$2"
    local nqn="$3"
    local nsid="$4"
    local uuid="$5"
    local other other_nqn other_nsid other_uuid

    while IFS=$'\t' read -r other other_nqn other_nsid other_uuid; do
        [[ "$other" != "$dataset" && "$other_nqn" == "$nqn" ]] || continue
        [[ "$other_nsid" == "$nsid" || "$other_uuid" == "$uuid" ]] && return 0
    done < <(list_volumes "$pool")
    return 1
}

allocate_nsid() {
    local pool="$1"
    local nqn="$2"
    local dataset other_nqn other_nsid other_uuid namespace nsid=1
    declare -A used=()

    while IFS=$'\t' read -r dataset other_nqn other_nsid other_uuid; do
        if [[ "$other_nqn" == "$nqn" && "$other_nsid" =~ ^[1-9][0-9]*$ ]]; then
            used["$other_nsid"]=1
        fi
    done < <(list_volumes "$pool")

    for namespace in "$ROOT/subsystems/$nqn"/namespaces/*; do
        [[ -d "$namespace" ]] || continue
        used["$(basename "$namespace")"]=1
    done

    while [[ -n "${used[$nsid]:-}" ]]; do
        ((nsid++))
    done
    printf '%s\n' "$nsid"
}

ensure_identity() {
    local nqn="$1"
    local pool="$2"
    local dataset="$3"
    local current_nqn nsid uuid

    current_nqn="$(property_value "$PROP_SUBSYS" "$dataset")"
    nsid="$(property_value "$PROP_NSID" "$dataset")"
    uuid="$(property_value "$PROP_UUID" "$dataset")"

    if [[ "$current_nqn" != '-' && "$current_nqn" != "$nqn" ]]; then
        die "ZFS volume '$dataset' belongs to NVMe subsystem '$current_nqn'"
    fi

    if [[ ! "$nsid" =~ ^[1-9][0-9]*$ ]] ||
        [[ ! "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] ||
        identity_is_duplicate "$pool" "$dataset" "$nqn" "$nsid" "$uuid"; then
        nsid="$(allocate_nsid "$pool" "$nqn")"
        uuid="$(< /proc/sys/kernel/random/uuid)"
    fi

    validate_uuid "$uuid"
    zfs set "$PROP_SUBSYS=$nqn" "$PROP_NSID=$nsid" "$PROP_UUID=$uuid" "$dataset"
    IDENTITY_NSID="$nsid"
    IDENTITY_UUID="$uuid"
}

remove_namespace() {
    local namespace="$1"
    if [[ "$(<"$namespace/enable")" == 1 ]]; then
        printf '0\n' >"$namespace/enable"
    fi
    rmdir "$namespace"
}

ensure_namespace() {
    local nqn="$1"
    local nsid="$2"
    local uuid="$3"
    local device="$4"
    local namespace="$ROOT/subsystems/$nqn/namespaces/$nsid"
    local other

    validate_uuid "$uuid"
    validate_device "$device"
    [[ -b "$device" ]] || die "zvol '$device' is not a block device"
    [[ -d "$ROOT/subsystems/$nqn" ]] || die "NVMe subsystem does not exist"

    for other in "$ROOT/subsystems/$nqn"/namespaces/*; do
        [[ -d "$other" && "$other" != "$namespace" ]] || continue
        if [[ "$(<"$other/device_uuid")" == "$uuid" ]]; then
            die "namespace UUID '$uuid' is already in use"
        fi
    done

    if [[ -d "$namespace" ]]; then
        if [[ "$(<"$namespace/device_uuid")" == "$uuid" ]] &&
            [[ "$(<"$namespace/device_path")" == "$device" ]]; then
            [[ "$(<"$namespace/enable")" == 1 ]] || printf '1\n' >"$namespace/enable"
            return
        fi
        remove_namespace "$namespace"
    fi

    mkdir "$namespace"
    if ! {
        printf '%s\n' "$device" >"$namespace/device_path"
        printf '%s\n' "$uuid" >"$namespace/device_uuid"
        printf '0\n' >"$namespace/buffered_io"
        printf '1\n' >"$namespace/enable"
    }; then
        printf '0\n' >"$namespace/enable" 2>/dev/null || true
        rmdir "$namespace" 2>/dev/null || true
        die "failed to create namespace '$nsid'"
    fi
}

create_volume() {
    local nqn="$1"
    local pool="$2"
    local device="$3"
    local dataset

    validate_nqn "$nqn"
    validate_pool "$pool"
    validate_device "$device"
    dataset="${device#/dev/zvol/}"
    [[ "$dataset" == "$pool/"* ]] || die "zvol is outside configured pool"
    [[ "$(zfs get -H -o value type "$dataset")" == volume ]] ||
        die "'$dataset' is not a ZFS volume"

    ensure_identity "$nqn" "$pool" "$dataset"
    ensure_namespace "$nqn" "$IDENTITY_NSID" "$IDENTITY_UUID" "$device"
    printf '%s\n' "$IDENTITY_UUID"
}

delete_volume() {
    local nqn="$1"
    local uuid="$2"
    local namespace found=0

    validate_nqn "$nqn"
    validate_uuid "$uuid"
    [[ -d "$ROOT/subsystems/$nqn" ]] || return 0
    for namespace in "$ROOT/subsystems/$nqn"/namespaces/*; do
        [[ -d "$namespace" ]] || continue
        [[ "$(<"$namespace/device_uuid")" == "$uuid" ]] || continue
        ((found == 0)) || die "duplicate namespace UUID '$uuid'"
        remove_namespace "$namespace"
        found=1
    done
}

lookup_volume() {
    local nqn="$1"
    local pool="$2"
    local device="$3"
    local dataset current_nqn nsid uuid

    validate_nqn "$nqn"
    validate_pool "$pool"
    validate_device "$device"
    dataset="${device#/dev/zvol/}"
    [[ "$dataset" == "$pool/"* ]] || die "zvol is outside configured pool"
    [[ "$(zfs get -H -o value type "$dataset")" == volume ]] ||
        die "'$dataset' is not a ZFS volume"

    current_nqn="$(property_value "$PROP_SUBSYS" "$dataset")"
    nsid="$(property_value "$PROP_NSID" "$dataset")"
    uuid="$(property_value "$PROP_UUID" "$dataset")"
    [[ "$current_nqn" == "$nqn" ]] ||
        die "ZFS volume '$dataset' is not owned by NVMe subsystem '$nqn'"
    [[ "$nsid" =~ ^[1-9][0-9]*$ ]] || die "invalid NSID on '$dataset'"
    validate_uuid "$uuid"
    identity_is_duplicate "$pool" "$dataset" "$nqn" "$nsid" "$uuid" &&
        die "duplicate NVMe identity on '$dataset'"

    ensure_namespace "$nqn" "$nsid" "$uuid" "$device"
    printf '%s\n' "$uuid"
}

lookup_view() {
    local nqn="$1"
    local pool="$2"
    local uuid="$3"
    local dataset other_nqn nsid other_uuid found=''

    validate_nqn "$nqn"
    validate_pool "$pool"
    validate_uuid "$uuid"
    while IFS=$'\t' read -r dataset other_nqn nsid other_uuid; do
        [[ "$other_nqn" == "$nqn" && "$other_uuid" == "$uuid" ]] || continue
        [[ -z "$found" ]] || die "duplicate namespace UUID '$uuid'"
        found="$nsid"
    done < <(list_volumes "$pool")
    [[ "$found" =~ ^[1-9][0-9]*$ ]] || die "namespace UUID '$uuid' was not found"
    printf '%s\n' "$found"
}

resize_volume() {
    local nqn="$1"
    local uuid="$2"
    local namespace

    validate_nqn "$nqn"
    validate_uuid "$uuid"
    for namespace in "$ROOT/subsystems/$nqn"/namespaces/*; do
        [[ -d "$namespace" ]] || continue
        if [[ "$(<"$namespace/device_uuid")" == "$uuid" ]]; then
            printf '1\n' >"$namespace/revalidate_size"
            return
        fi
    done
    die "namespace UUID '$uuid' was not found"
}

reconcile() {
    local nqn="$1"
    local pool="$2"
    local dataset other_nqn nsid uuid device namespace
    declare -A desired=()
    declare -A seen_uuid=()

    validate_nqn "$nqn"
    validate_pool "$pool"
    [[ -d "$ROOT/subsystems/$nqn" ]] || die "NVMe subsystem does not exist"

    while IFS=$'\t' read -r dataset other_nqn nsid uuid; do
        [[ "$other_nqn" == "$nqn" ]] || continue
        [[ "$nsid" =~ ^[1-9][0-9]*$ ]] || die "invalid NSID on '$dataset'"
        validate_uuid "$uuid"
        [[ -z "${desired[$nsid]:-}" ]] || die "duplicate NSID '$nsid'"
        [[ -z "${seen_uuid[$uuid]:-}" ]] || die "duplicate namespace UUID '$uuid'"
        desired["$nsid"]=1
        seen_uuid["$uuid"]=1
        device="/dev/zvol/$dataset"
        ensure_namespace "$nqn" "$nsid" "$uuid" "$device"
    done < <(list_volumes "$pool")

    for namespace in "$ROOT/subsystems/$nqn"/namespaces/*; do
        [[ -d "$namespace" ]] || continue
        nsid="$(basename "$namespace")"
        [[ -n "${desired[$nsid]:-}" ]] || remove_namespace "$namespace"
    done
}

delete_target() {
    local nqn="$1"
    local subsystem="$ROOT/subsystems/$nqn"
    local namespace port link hostnqn referenced
    local -a hosts=()

    validate_nqn "$nqn"
    [[ -d "$subsystem" ]] || return 0

    for namespace in "$subsystem"/namespaces/*; do
        [[ -d "$namespace" ]] || continue
        remove_namespace "$namespace"
    done
    for port in "$ROOT"/ports/*; do
        [[ -d "$port" ]] || continue
        link="$port/subsystems/$nqn"
        [[ -L "$link" ]] && rm "$link"
    done
    for link in "$subsystem"/allowed_hosts/*; do
        [[ -L "$link" ]] || continue
        hosts+=("$(basename "$link")")
        rm "$link"
    done
    rmdir "$subsystem"

    # Host objects (and their DHCHAP keys) are global in nvmet. Remove an
    # orphan only after proving that no other subsystem still authorizes it.
    for hostnqn in "${hosts[@]}"; do
        referenced=0
        for link in "$ROOT"/subsystems/*/allowed_hosts/"$hostnqn"; do
            if [[ -L "$link" ]]; then
                referenced=1
                break
            fi
        done
        ((referenced == 1)) || rmdir "$ROOT/hosts/$hostnqn"
    done
}

prepare_configfs
mode="${1:-}"
shift || true

case "$mode" in
    ensure-target) ensure_target "$@" ;;
    ensure-host) ensure_host "$@" ;;
    allow-host) allow_host "$@" ;;
    create) create_volume "$@" ;;
    delete) delete_volume "$@" ;;
    lookup) lookup_volume "$@" ;;
    view) lookup_view "$@" ;;
    resize) resize_volume "$@" ;;
    reconcile) reconcile "$@" ;;
    delete-target) delete_target "$@" ;;
    *) die "unknown NVMe target operation" ;;
esac
REMOTE_HELPER

my $REMOTE_SET_HOST_KEY = <<'REMOTE_SET_HOST_KEY';
set -euo pipefail

ROOT=/sys/kernel/config/nvmet
hostnqn="$1"
host="$ROOT/hosts/$hostnqn"

[[ "$hostnqn" =~ ^nqn\.[A-Za-z0-9][A-Za-z0-9.-]*:[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || {
    echo "invalid host NQN '$hostnqn'" >&2
    exit 1
}
((${#hostnqn} <= 223)) || {
    echo 'host NQN is too long' >&2
    exit 1
}
[[ -d "$host" ]] || {
    echo 'NVMe host does not exist' >&2
    exit 1
}

IFS= read -r key
[[ "$key" =~ ^DHHC-1:[0-9A-Fa-f]{2}:[A-Za-z0-9+/=]+:$ ]] || {
    echo 'invalid DH-HMAC-CHAP key representation' >&2
    exit 1
}
current="$(<"$host/dhchap_key")"
if [[ -n "$current" && "$current" != "$key" ]]; then
    for link in "$ROOT"/subsystems/*/allowed_hosts/"$hostnqn"; do
        if [[ -L "$link" ]]; then
            echo "refusing to replace an in-use DH-HMAC-CHAP key for '$hostnqn'" >&2
            exit 1
        fi
    done
fi
printf '%s\n' "$key" >"$host/dhchap_key"
REMOTE_SET_HOST_KEY

my sub server($scfg) {
    return $scfg->{server} // $scfg->{portal};
}

my sub ssh_key($scfg) {
    my $server = server($scfg);
    return "$id_rsa_path/${server}_id_rsa";
}

my sub remote_call($scfg, $timeout, $operation, @params) {
    my $server = server($scfg);
    my $target = 'root@' . $server;
    my $msg = '';
    my $err = '';
    my $cmd = [
        @ssh_cmd,
        '-i',
        ssh_key($scfg),
        $target,
        '--',
        '/bin/bash',
        '-s',
        '--',
        $operation,
        @params,
    ];

    run_command(
        $cmd,
        input => $REMOTE_HELPER,
        timeout => $timeout // 10,
        outfunc => sub($line) { $msg .= "$line\n" },
        errfunc => sub($line) { $err .= "$line\n" },
        errmsg => "NVMe target operation '$operation' failed",
    );

    return trim($msg);
}

sub get_base($scfg) {
    return '/dev/zvol';
}

sub ensure_target($scfg, $hostnqn, $portals) {
    my $nqn = $scfg->{subsysnqn};

    remote_call($scfg, 15, 'ensure-target', $nqn, $scfg->{pool}, $portals->@*);
    remote_call($scfg, 10, 'ensure-host', $nqn, $hostnqn);
}

sub set_host_key($scfg, $hostnqn, $key) {
    my $server = server($scfg);
    my $target = 'root@' . $server;
    my $remote_cmd = join(
        ' ',
        map { PVE::Tools::shellquote($_) }
            ('/bin/bash', '-c', $REMOTE_SET_HOST_KEY, '--', $hostnqn),
    );
    my $cmd = [
        @ssh_cmd,
        '-i',
        ssh_key($scfg),
        $target,
        '--',
        $remote_cmd,
    ];

    run_command(
        $cmd,
        input => "$key\n",
        timeout => 10,
        quiet => 1,
        errmsg => "failed to configure NVMe DH-HMAC-CHAP key",
    );
}

sub allow_host($scfg, $hostnqn) {
    remote_call($scfg, 10, 'allow-host', $scfg->{subsysnqn}, $hostnqn);
}

sub reconcile($scfg) {
    remote_call($scfg, 30, 'reconcile', $scfg->{subsysnqn}, $scfg->{pool});
}

sub delete_target($scfg) {
    remote_call($scfg, 15, 'delete-target', $scfg->{subsysnqn});
}

my %lun_cmd_map = (
    create_lu => sub($scfg, $timeout, $method, $device) {
        return remote_call($scfg, $timeout, 'create', $scfg->{subsysnqn}, $scfg->{pool}, $device);
    },
    delete_lu => sub($scfg, $timeout, $method, $uuid) {
        return remote_call($scfg, $timeout, 'delete', $scfg->{subsysnqn}, $uuid);
    },
    import_lu => sub($scfg, $timeout, $method, $device) {
        return remote_call($scfg, $timeout, 'create', $scfg->{subsysnqn}, $scfg->{pool}, $device);
    },
    modify_lu => sub($scfg, $timeout, $method, $size, $uuid) {
        return remote_call($scfg, $timeout, 'resize', $scfg->{subsysnqn}, $uuid);
    },
    add_view => sub($scfg, $timeout, $method, @params) {
        return '';
    },
    list_view => sub($scfg, $timeout, $method, $uuid) {
        return remote_call($scfg, $timeout, 'view', $scfg->{subsysnqn}, $scfg->{pool}, $uuid);
    },
    list_lu => sub($scfg, $timeout, $method, $device) {
        return remote_call($scfg, $timeout, 'lookup', $scfg->{subsysnqn}, $scfg->{pool}, $device);
    },
);

sub run_lun_command($scfg, $timeout, $method, @params) {
    die "unknown command '$method'\n" if !exists($lun_cmd_map{$method});
    return $lun_cmd_map{$method}->($scfg, $timeout, $method, @params);
}

1;
