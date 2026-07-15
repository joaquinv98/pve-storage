package PVE::Storage::ZFSNVMePlugin;

use v5.36;

use File::Path qw(make_path);
use IO::Socket::IP;
use IO::File;
use JSON;

use PVE::JSONSchema;
use PVE::RESTEnvironment qw(log_warn);
use PVE::Storage::LunCmd::NVMET;
use PVE::Storage::ZFSPlugin;
use PVE::Tools qw(file_read_firstline file_set_contents run_command trim);

use base qw(PVE::Storage::ZFSPlugin);

my $nvme = '/usr/sbin/nvme';
my $secret_dir = '/etc/pve/priv/storage';
my $runtime_dir = '/run/pve-storage';
my $max_paths = 16;

my $RE_NQN = qr{
    \A
    nqn \.
    [A-Za-z0-9] [A-Za-z0-9.-]*
    :
    [A-Za-z0-9] [A-Za-z0-9._:-]*
    \z
}nxx;
my $RE_IPV4_PORTAL = qr{
    \A
    (?<address> [^:]+)
    (?: : (?<port> [0-9]+))?
    \z
}nxx;
my $RE_IPV6_PORTAL = qr{
    \A
    \[ (?<address> [^\]]+) \]
    (?: : (?<port> [0-9]+))?
    \z
}nxx;
my $RE_HOST_IFACE = qr{\A [A-Za-z0-9_.-]+ \z}nxx;
my $RE_DHCHAP_KEY = qr{
    \A DHHC-1 : [0-9A-Fa-f]{2} : [A-Za-z0-9+/=]+ : \z
}nxx;
my $RE_NVME_CONTROLLER = qr{\A nvme [0-9]+ \z}nxx;
my $RE_NVME_SUBSYSTEM = qr{\A nvme-subsys [0-9]+ \z}nxx;
my $RE_TRADDR = qr{(?: \A | ,) traddr=(?<value>[^,]+)}nxx;
my $RE_TRSVCID = qr{(?: \A | ,) trsvcid=(?<value>[^,]+)}nxx;
my $RE_HOST_IFACE_ADDRESS = qr{(?: \A | ,) host_iface=(?<value>[^,]+)}nxx;

sub verify_nvme_nqn($value, $noerr = undef) {

    if (
        length($value) > 223
        || $value !~ $RE_NQN
    ) {
        return undef if $noerr;
        die "value is not a valid NVMe qualified name\n";
    }

    return $value;
}

sub parse_nvme_portals($value, $noerr = undef) {
    my $result = [];
    my $seen = {};

    for my $entry (split(/,/, $value // '')) {
        $entry = trim($entry);
        my ($address, $port, $family);
        if ($entry =~ $RE_IPV6_PORTAL) {
            ($address, $port, $family) = ($+{address}, $+{port} // 4420, 'ipv6');
        } elsif ($entry =~ $RE_IPV4_PORTAL) {
            ($address, $port, $family) = ($+{address}, $+{port} // 4420, 'ipv4');
        } else {
            return undef if $noerr;
            die "invalid NVMe/TCP portal '$entry'\n";
        }

        if (
            !PVE::JSONSchema::pve_verify_ip($address, 1)
            || ($family eq 'ipv4' && index($address, ':') >= 0)
            || ($family eq 'ipv6' && index($address, ':') < 0)
            || $port < 1
            || $port > 65535
        ) {
            return undef if $noerr;
            die "invalid NVMe/TCP portal '$entry'\n";
        }
        my $id = join("\0", $family, $address, $port);
        if ($seen->{$id}++) {
            return undef if $noerr;
            die "duplicate NVMe/TCP portal '$entry'\n";
        }
        push $result->@*, {
            address => $address,
            port => int($port),
            family => $family,
        };
        if (scalar($result->@*) > $max_paths) {
            return undef if $noerr;
            die "at most $max_paths NVMe/TCP portals are supported\n";
        }
    }

    if (!$result->@*) {
        return undef if $noerr;
        die "at least one NVMe/TCP portal is required\n";
    }

    return $result;
}

my sub verify_nvme_portals($value, $noerr = undef) {
    return undef if !parse_nvme_portals($value, $noerr);
    return $value;
}

sub parse_nvme_host_ifaces($value, $noerr = undef) {
    my $result = [];

    for my $iface (split(/,/, $value // '')) {
        $iface = trim($iface);
        if (length($iface) < 1 || length($iface) > 15 || $iface !~ $RE_HOST_IFACE) {
            return undef if $noerr;
            die "invalid NVMe/TCP host interface '$iface'\n";
        }
        push $result->@*, $iface;
    }

    if (!$result->@*) {
        return undef if $noerr;
        die "at least one NVMe/TCP host interface is required\n";
    }

    return $result;
}

my sub verify_nvme_host_ifaces($value, $noerr = undef) {
    return undef if !parse_nvme_host_ifaces($value, $noerr);
    return $value;
}

sub _configured_portals($scfg) {
    my $portals = parse_nvme_portals($scfg->{'nvme-portals'});
    my $ifaces = parse_nvme_host_ifaces($scfg->{'nvme-host-ifaces'});
    die "nvme-host-ifaces must contain one interface for each nvme-portals entry\n"
        if scalar($ifaces->@*) != scalar($portals->@*);

    for (my $i = 0; $i < scalar($portals->@*); $i++) {
        $portals->[$i]->{host_iface} = $ifaces->[$i];
    }
    return $portals;
}

PVE::JSONSchema::register_format('pve-storage-nvme-nqn', \&verify_nvme_nqn);
PVE::JSONSchema::register_format('pve-storage-nvme-portals', \&verify_nvme_portals);
PVE::JSONSchema::register_format('pve-storage-nvme-host-ifaces', \&verify_nvme_host_ifaces);

sub type($class) {
    return 'zfsnvme';
}

sub plugindata($class) {
    return {
        content => [{ images => 1 }, { images => 1 }],
        'sensitive-properties' => { 'dhchap-key' => 1 },
    };
}

sub properties($class) {
    return {
        subsysnqn => {
            description => "NVMe subsystem qualified name.",
            type => 'string',
            format => 'pve-storage-nvme-nqn',
        },
        'nvme-portals' => {
            description =>
                "Comma-separated NVMe/TCP target addresses. The default TCP port is 4420.",
            type => 'string',
            format => 'pve-storage-nvme-portals',
            maxLength => 2048,
        },
        'nvme-host-ifaces' => {
            description =>
                "Comma-separated local interfaces, in portal order. Interface names must be identical on every cluster node.",
            type => 'string',
            format => 'pve-storage-nvme-host-ifaces',
            maxLength => 512,
        },
        'dhchap-key' => {
            description => "NVMe DH-HMAC-CHAP key in secret representation format.",
            type => 'string',
            maxLength => 256,
        },
        'nvme-iopolicy' => {
            description => "Native NVMe multipath I/O policy.",
            type => 'string',
            enum => ['numa', 'round-robin', 'queue-depth'],
            default => 'round-robin',
        },
        'nvme-keep-alive-tmo' => {
            description => "NVMe keep-alive timeout in seconds.",
            type => 'integer',
            minimum => 1,
            maximum => 120,
            default => 5,
        },
        'nvme-reconnect-delay' => {
            description => "Delay between NVMe reconnect attempts in seconds.",
            type => 'integer',
            minimum => 1,
            maximum => 120,
            default => 2,
        },
        'nvme-ctrl-loss-tmo' => {
            description => "Time to keep retrying a lost NVMe controller in seconds.",
            type => 'integer',
            minimum => -1,
            maximum => 86400,
            default => 600,
        },
        'nvme-nr-io-queues' => {
            description => "Number of NVMe/TCP I/O queues per controller.",
            type => 'integer',
            minimum => 1,
            maximum => 1024,
            optional => 1,
        },
    };
}

sub options($class) {
    return {
        server => { fixed => 1 },
        subsysnqn => { fixed => 1 },
        'nvme-portals' => { fixed => 1 },
        'nvme-host-ifaces' => { optional => 1 },
        pool => { fixed => 1 },
        blocksize => { fixed => 1 },
        sparse => { optional => 1 },
        'dhchap-key' => { optional => 1 },
        'nvme-iopolicy' => { optional => 1 },
        'nvme-keep-alive-tmo' => { optional => 1 },
        'nvme-reconnect-delay' => { optional => 1 },
        'nvme-ctrl-loss-tmo' => { optional => 1 },
        'nvme-nr-io-queues' => { optional => 1 },
        nodes => { optional => 1 },
        disable => { optional => 1 },
        content => { optional => 1 },
        bwlimit => { optional => 1 },
    };
}

sub check_config($class, $section_id, $config, $create, $skip_schema_check) {
    if ($create) {
        $config->{sparse} = 1 if !defined($config->{sparse});
        $config->{'nvme-iopolicy'} //= 'round-robin';
        $config->{'nvme-keep-alive-tmo'} //= 5;
        $config->{'nvme-reconnect-delay'} //= 2;
        $config->{'nvme-ctrl-loss-tmo'} //= 600;
    }

    verify_nvme_nqn($config->{subsysnqn}) if defined($config->{subsysnqn});
    parse_nvme_portals($config->{'nvme-portals'}) if defined($config->{'nvme-portals'});
    if (defined($config->{'nvme-host-ifaces'}) && defined($config->{'nvme-portals'})) {
        _configured_portals($config);
    } elsif (defined($config->{'nvme-host-ifaces'})) {
        parse_nvme_host_ifaces($config->{'nvme-host-ifaces'});
    }
    return $class->SUPER::check_config($section_id, $config, $create, $skip_schema_check);
}

sub zfs_lun_provider($class, $scfg = undef) {
    return 'PVE::Storage::LunCmd::NVMET';
}

sub zfs_request($class, $scfg, @params) {
    local $scfg->{portal} = $scfg->{server};
    return $class->SUPER::zfs_request($scfg, @params);
}

sub zfs_list_zvol($class, $scfg) {
    my $list = $class->SUPER::zfs_list_zvol($scfg);
    my $properties = $class->zfs_request(
        $scfg,
        10,
        'get',
        '-H',
        '-d',
        '1',
        '-o',
        'name,value,source',
        'proxmox:nvme-subsys',
        $scfg->{pool},
    );
    my $owned = {};
    for my $line (split(/\n/, $properties)) {
        my ($dataset, $nqn, $source) = split(/\t/, $line, 3);
        next if !defined($source) || ($source ne 'local' && $source ne 'received');
        next if !defined($nqn) || $nqn ne $scfg->{subsysnqn};
        my $prefix = "$scfg->{pool}/";
        next if index($dataset, $prefix) != 0;
        $owned->{substr($dataset, length($prefix))} = 1;
    }
    for my $name (keys $list->%*) {
        delete $list->{$name} if !$owned->{$name};
    }
    return $list;
}

my sub secret_path($storeid) {
    return "$secret_dir/$storeid.nvme-dhchap";
}

sub _assert_unique_target($storeid, $scfg, $cfg = undef) {
    $cfg //= PVE::Storage::config();
    my $ids = $cfg->{ids} // {};
    for my $other_id (keys $ids->%*) {
        next if $other_id eq $storeid;
        my $other = $cfg->{ids}->{$other_id};
        next if ($other->{type} // '') ne 'zfsnvme';

        die "NVMe subsystem NQN is already used by storage '$other_id'\n"
            if ($other->{subsysnqn} // '') eq $scfg->{subsysnqn};
        die "ZFS pool '$scfg->{pool}' on '$scfg->{server}' is already used by storage '$other_id'\n"
            if ($other->{server} // '') eq $scfg->{server}
            && ($other->{pool} // '') eq $scfg->{pool};
    }
}

sub _validate_secret($key) {
    die "missing NVMe DH-HMAC-CHAP key\n" if !defined($key) || $key eq '';
    die "invalid NVMe DH-HMAC-CHAP key representation\n"
        if $key !~ $RE_DHCHAP_KEY;
    return $key;
}

my sub set_secret($storeid, $key) {
    _validate_secret($key);
    make_path($secret_dir, { mode => 0700 });
    file_set_contents(secret_path($storeid), "$key\n", 0600);
}

my sub get_secret($storeid) {
    my $key = file_read_firstline(secret_path($storeid));
    return _validate_secret($key);
}

my sub delete_secret($storeid) {
    unlink(secret_path($storeid));
}

sub on_add_hook($class, $storeid, $scfg, %sensitive) {
    _configured_portals($scfg);
    _assert_unique_target($storeid, $scfg);
    set_secret($storeid, $sensitive{'dhchap-key'});
    return;
}

sub on_update_hook_full($class, $storeid, $scfg, $update, $delete, $sensitive) {
    my %prospective = ($scfg->%*, $update->%*);
    delete @prospective{$delete->@*} if $delete;
    verify_nvme_nqn($prospective{subsysnqn});
    _configured_portals(\%prospective);
    _assert_unique_target($storeid, \%prospective);

    my $old_key = file_read_firstline(secret_path($storeid));
    my $key = exists($sensitive->{'dhchap-key'}) ? $sensitive->{'dhchap-key'} : $old_key;
    _validate_secret($key);

    # nvmet stores authentication on the global Host NQN object, which can be
    # shared by multiple subsystems. Replacing an active key in place can make
    # unrelated storages unrecoverable on their next reconnect. Until PVE can
    # coordinate a rolling rotation on every node, fail before mutating the
    # cluster-wide secret.
    die "online NVMe DH-HMAC-CHAP key rotation is not supported; create a new storage/NQN\n"
        if defined($old_key) && $key ne $old_key;

    set_secret($storeid, $key) if exists($sensitive->{'dhchap-key'});
    return;
}

sub on_delete_hook($class, $storeid, $scfg) {
    eval { $class->deactivate_storage($storeid, $scfg) };
    log_warn("failed to disconnect NVMe storage '$storeid': $@") if $@;
    eval { PVE::Storage::LunCmd::NVMET::delete_target($scfg) };
    log_warn("failed to remove NVMe target for '$storeid': $@") if $@;
    delete_secret($storeid);
    return;
}

my sub runtime_config_path($storeid) {
    return "$runtime_dir/nvme-$storeid.json";
}

my sub write_runtime_config($storeid, $scfg, $hostnqn, $hostid, $key, $portals) {
    my $ports = [
        map {
            {
                transport => 'tcp',
                traddr => $_->{address},
                host_iface => $_->{host_iface},
                trsvcid => "$_->{port}",
                keep_alive_tmo => $scfg->{'nvme-keep-alive-tmo'} // 5,
                reconnect_delay => $scfg->{'nvme-reconnect-delay'} // 2,
                ctrl_loss_tmo => $scfg->{'nvme-ctrl-loss-tmo'} // 600,
                ($scfg->{'nvme-nr-io-queues'}
                    ? (nr_io_queues => $scfg->{'nvme-nr-io-queues'})
                    : ()),
            }
        } $portals->@*
    ];
    my $config = [
        {
            hostnqn => $hostnqn,
            hostid => $hostid,
            dhchap_key => $key,
            subsystems => [
                {
                    nqn => $scfg->{subsysnqn},
                    ports => $ports,
                    application => 'pve-storage',
                },
            ],
        },
    ];

    make_path($runtime_dir, { mode => 0700 });
    my $json = JSON->new->canonical->utf8->encode($config);
    my $path = runtime_config_path($storeid);
    file_set_contents($path, "$json\n", 0600);
    return $path;
}

my sub controller_states($nqn) {
    my $states = {};

    opendir(my $dh, '/sys/class/nvme') or return $states;
    while (defined(my $entry = readdir($dh))) {
        next if $entry !~ $RE_NVME_CONTROLLER;
        my $base = "/sys/class/nvme/$entry";
        my $subsys = file_read_firstline("$base/subsysnqn");
        next if !defined($subsys) || $subsys ne $nqn;
        my $address = file_read_firstline("$base/address") // '';
        my $state = file_read_firstline("$base/state") // 'unknown';
        my $traddr = $address =~ $RE_TRADDR ? $+{value} : undef;
        my $trsvcid = $address =~ $RE_TRSVCID ? $+{value} : undef;
        my $host_iface = $address =~ $RE_HOST_IFACE_ADDRESS ? $+{value} : undef;
        next if !defined($traddr) || !defined($trsvcid);
        $states->{"$traddr:$trsvcid"} = {
            device => "/dev/$entry",
            host_iface => $host_iface,
            state => $state,
        };
    }
    closedir($dh);
    return $states;
}

my sub portal_reachable($portal) {
    my $socket = IO::Socket::IP->new(
        PeerHost => $portal->{address},
        PeerPort => $portal->{port},
        Proto => 'tcp',
        Timeout => 2,
    );
    return 0 if !$socket;
    close($socket);
    return 1;
}

sub _live_portal_count($states, $portals) {
    my $live = 0;
    for my $portal ($portals->@*) {
        my $id = "$portal->{address}:$portal->{port}";
        my $controller = $states->{$id};
        $live++
            if $controller
            && $controller->{state} eq 'live'
            && ($controller->{host_iface} // '') eq $portal->{host_iface};
    }
    return $live;
}

sub _connect_portal($config_path, $scfg, $portal) {
    my $cmd = [
        $nvme,
        'connect',
        '--config',
        $config_path,
        '--transport',
        'tcp',
        '--nqn',
        $scfg->{subsysnqn},
        '--traddr',
        $portal->{address},
        '--host-iface',
        $portal->{host_iface},
        '--trsvcid',
        "$portal->{port}",
        '--keep-alive-tmo',
        $scfg->{'nvme-keep-alive-tmo'} // 5,
        '--reconnect-delay',
        $scfg->{'nvme-reconnect-delay'} // 2,
        '--ctrl-loss-tmo',
        $scfg->{'nvme-ctrl-loss-tmo'} // 600,
    ];
    if (my $queues = $scfg->{'nvme-nr-io-queues'}) {
        push $cmd->@*, '--nr-io-queues', $queues;
    }

    run_command($cmd, timeout => 10, quiet => 1, errmsg => "NVMe/TCP connect failed");
}

my sub set_iopolicy($nqn, $policy) {
    opendir(my $dh, '/sys/class/nvme-subsystem') or return;
    while (defined(my $entry = readdir($dh))) {
        next if $entry !~ $RE_NVME_SUBSYSTEM;
        my $base = "/sys/class/nvme-subsystem/$entry";
        my $subsys = file_read_firstline("$base/subsysnqn");
        next if !defined($subsys) || $subsys ne $nqn;
        my $fh = IO::File->new("$base/iopolicy", 'w')
            or die "unable to set NVMe multipath policy: $!\n";
        print $fh "$policy\n";
        close($fh) or die "unable to set NVMe multipath policy: $!\n";
    }
    closedir($dh);
}

sub activate_storage($class, $storeid, $scfg, $cache = undef) {
    $cache //= {};

    die "nvme-cli is not installed\n" if !-x $nvme;
    die "native NVMe multipath is disabled in the running kernel\n"
        if (file_read_firstline('/sys/module/nvme_core/parameters/multipath') // 'N') ne 'Y';

    _assert_unique_target($storeid, $scfg);
    my $portals = _configured_portals($scfg);
    my $states = controller_states($scfg->{subsysnqn});
    my $force_reconcile =
        delete($cache->{'zfsnvme-force-reconcile'}->{$storeid}) // 0;
    my $live = _live_portal_count($states, $portals);

    # This method is called by the periodic storage status loop. Once every
    # configured controller is live, all lifecycle mutations are already
    # reconciled by their individual operations, so avoid four SSH round-trips
    # on every status poll. Missing namespaces explicitly force the slow path
    # from activate_volume().
    if (!$force_reconcile && $live == scalar($portals->@*)) {
        die "missing NVMe DH-HMAC-CHAP key\n" if !-s secret_path($storeid);
        set_iopolicy($scfg->{subsysnqn}, $scfg->{'nvme-iopolicy'} // 'round-robin');
        return 1;
    }

    my $hostnqn = file_read_firstline('/etc/nvme/hostnqn')
        // die "missing /etc/nvme/hostnqn\n";
    my $hostid = file_read_firstline('/etc/nvme/hostid')
        // die "missing /etc/nvme/hostid\n";
    verify_nvme_nqn($hostnqn);
    my $key = get_secret($storeid);
    my $target_portals = [
        map { "$_->{family},$_->{address},$_->{port}" } $portals->@*
    ];

    PVE::Storage::LunCmd::NVMET::ensure_target($scfg, $hostnqn, $target_portals);
    PVE::Storage::LunCmd::NVMET::set_host_key($scfg, $hostnqn, $key);
    PVE::Storage::LunCmd::NVMET::allow_host($scfg, $hostnqn);
    PVE::Storage::LunCmd::NVMET::reconcile($scfg);

    my $config_path =
        write_runtime_config($storeid, $scfg, $hostnqn, $hostid, $key, $portals);
    $states = controller_states($scfg->{subsysnqn});
    for my $portal ($portals->@*) {
        my $id = "$portal->{address}:$portal->{port}";
        my $needs_rebind = 0;
        if (my $controller = $states->{$id}) {
            $needs_rebind = ($controller->{host_iface} // '') ne $portal->{host_iface};
            next if !$needs_rebind && $controller->{state} ne 'dead';
            run_command(
                [$nvme, 'disconnect', '--device', $controller->{device}],
                timeout => 5,
                noerr => 1,
                quiet => 1,
            );
        }
        if (!portal_reachable($portal)) {
            log_warn("NVMe/TCP portal '$id' is unreachable");
            next;
        }
        eval { _connect_portal($config_path, $scfg, $portal) };
        log_warn("$id: $@") if $@;

        # Rebind controllers one at a time. Do not disconnect the next path
        # until this one is live on its configured interface, so changing an
        # interface mapping cannot cause an avoidable all-path outage.
        if ($needs_rebind) {
            my $rebound = 0;
            for (my $attempt = 0; $attempt < 40; $attempt++) {
                $states = controller_states($scfg->{subsysnqn});
                my $controller = $states->{$id};
                if (
                    $controller
                    && $controller->{state} eq 'live'
                    && ($controller->{host_iface} // '') eq $portal->{host_iface}
                ) {
                    $rebound = 1;
                    last;
                }
                select(undef, undef, undef, 0.25);
            }
            if (!$rebound) {
                log_warn("NVMe/TCP portal '$id' did not rebind to '$portal->{host_iface}'");
                last;
            }
        }
    }

    # Existing controllers can be in the middle of their kernel reconnect delay
    # after a target restart. Do not create duplicates, but give that recovery
    # cycle enough time to complete before declaring the storage unavailable.
    for (my $attempt = 0; $attempt < 60; $attempt++) {
        $states = controller_states($scfg->{subsysnqn});
        last if _live_portal_count($states, $portals);
        select(undef, undef, undef, 0.25);
    }
    $live = _live_portal_count($states, $portals);
    die "no live NVMe/TCP path for storage '$storeid'\n" if !$live;
    log_warn("storage '$storeid' is degraded: $live/" . scalar($portals->@*) . " paths live")
        if $live < scalar($portals->@*);

    set_iopolicy($scfg->{subsysnqn}, $scfg->{'nvme-iopolicy'} // 'round-robin');
    return 1;
}

sub deactivate_storage($class, $storeid, $scfg, $cache = undef) {

    run_command(
        [$nvme, 'disconnect', '--nqn', $scfg->{subsysnqn}],
        timeout => 15,
        noerr => 1,
        quiet => 1,
    ) if -x $nvme;
    unlink(runtime_config_path($storeid));
    return 1;
}

sub path($class, $scfg, $volname, $storeid, $snapname = undef) {
    die "direct access to snapshots not implemented\n" if defined($snapname);
    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    my $uuid = $class->zfs_get_lu_name($scfg, $name);
    my $path = "/dev/disk/by-id/nvme-uuid.$uuid";
    return ($path, $vmid, $vtype);
}

sub qemu_blockdev_options($class, $scfg, $storeid, $volname, $machine_version, $options) {
    die "direct access to snapshots not implemented\n" if $options->{'snapshot-name'};
    my ($path) = $class->path($scfg, $volname, $storeid);
    return { driver => 'host_device', filename => $path };
}

sub activate_volume($class, $storeid, $scfg, $volname, $snapname, $cache = undef) {
    die "unable to activate snapshot from remote zfs storage\n" if $snapname;
    my ($path) = $class->path($scfg, $volname, $storeid);
    if (!-b $path) {
        $cache //= {};
        $cache->{'zfsnvme-force-reconcile'}->{$storeid} = 1;
        $class->activate_storage($storeid, $scfg, $cache);
        for (my $attempt = 0; $attempt < 40 && !-b $path; $attempt++) {
            select(undef, undef, undef, 0.25);
        }
    }
    die "NVMe namespace for '$volname' did not appear\n" if !-b $path;
    return 1;
}

sub deactivate_volume($class, $storeid, $scfg, $volname, $snapname, $cache = undef) {
    die "unable to deactivate snapshot from remote zfs storage\n" if $snapname;
    return 1;
}

sub volume_resize($class, $scfg, $storeid, $volname, $size, $running, $snapname) {
    # QEMU's block_resize command explicitly cannot resize host block devices.
    # Reject before changing the zvol/namespace, otherwise qemu-server would
    # leave the backend larger while the running VM and its config keep the old
    # size. A stopped VM is reopened with the new capacity on its next start.
    die "online resize is not supported for NVMe/TCP block devices; stop the VM first\n"
        if $running;
    return $class->SUPER::volume_resize(
        $scfg, $storeid, $volname, $size, $running, $snapname,
    );
}

sub alloc_image($class, $storeid, $scfg, $vmid, $fmt, $name, $size) {
    die "unsupported format '$fmt'" if $fmt ne 'raw';
    die "illegal name '$name' - should be 'vm-$vmid-*'\n"
        if $name && index($name, "vm-$vmid-") != 0;
    my $volname = $name // $class->find_free_diskname($storeid, $scfg, $vmid, $fmt);

    $class->zfs_create_zvol($scfg, $volname, $size);
    eval {
        my $uuid = $class->zfs_create_lu($scfg, $volname);
        $class->zfs_add_lun_mapping_entry($scfg, $volname, $uuid);
    };
    if (my $err = $@) {
        eval { $class->zfs_delete_zvol($scfg, $volname) };
        warn "failed to clean up zvol '$volname': $@" if $@;
        die $err;
    }
    return $volname;
}

1;
