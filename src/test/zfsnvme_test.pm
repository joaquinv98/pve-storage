package PVE::Storage::TestZFSNVMe;

use v5.36;

use lib qw(..);

use PVE::Storage::LunCmd::LIO;
use PVE::Storage::LunCmd::NVMET;
use PVE::Storage::ZFSNVMePlugin;
use PVE::Storage::ZFSPlugin;
use Test::MockModule;
use Test::More;

my $nvme_mock = Test::MockModule->new('PVE::Storage::ZFSNVMePlugin');

is(
    PVE::Storage::ZFSNVMePlugin::verify_nvme_nqn(
        'nqn.2014-08.org.nvmexpress:uuid:12345678-1234-1234-1234-123456789abc',
    ),
    'nqn.2014-08.org.nvmexpress:uuid:12345678-1234-1234-1234-123456789abc',
    'accepts a standards-based NQN',
);

ok(
    !PVE::Storage::ZFSNVMePlugin::verify_nvme_nqn('not-an-nqn', 1),
    'rejects an invalid NQN',
);

my $hostnqn_a = 'nqn.2014-08.org.nvmexpress:uuid:12345678-1234-1234-1234-123456789abc';
my $hostnqn_b = 'nqn.2014-08.org.nvmexpress:uuid:abcdefab-abcd-abcd-abcd-abcdefabcdef';
is_deeply(
    PVE::Storage::ZFSNVMePlugin::parse_nvme_host_nqns("$hostnqn_a,$hostnqn_b"),
    [$hostnqn_a, $hostnqn_b],
    'parses the complete cluster NVMe host allow-list',
);
ok(
    !PVE::Storage::ZFSNVMePlugin::parse_nvme_host_nqns("$hostnqn_a,$hostnqn_a", 1),
    'rejects duplicate NVMe host NQNs',
);

is_deeply(
    PVE::Storage::ZFSNVMePlugin::parse_nvme_portals(
        '10.90.1.11:4420,[fd00::11]:4421,10.90.2.11',
    ),
    [
        { address => '10.90.1.11', port => 4420, family => 'ipv4' },
        { address => 'fd00::11', port => 4421, family => 'ipv6' },
        { address => '10.90.2.11', port => 4420, family => 'ipv4' },
    ],
    'parses and normalizes IPv4 and IPv6 portals',
);

eval {
    PVE::Storage::ZFSNVMePlugin::parse_nvme_portals(
        '10.90.1.11:4420,10.90.1.11:4420',
    );
};
like($@, qr/duplicate NVMe\/TCP portal/, 'duplicate portal is rejected');

ok(
    !PVE::Storage::ZFSNVMePlugin::parse_nvme_portals('10.90.1.11:70000', 1),
    'rejects an invalid TCP port',
);

ok(
    !PVE::Storage::ZFSNVMePlugin::parse_nvme_portals(
        join(',', map { "10.90.1.$_:4420" } 1 .. 17),
        1,
    ),
    'limits the number of configured paths',
);

is_deeply(
    PVE::Storage::ZFSNVMePlugin::_configured_portals({
        'nvme-portals' => '10.90.1.11:4420,10.90.2.11:4421',
        'nvme-host-ifaces' => 'ens20,ens21',
    }),
    [
        {
            address => '10.90.1.11',
            port => 4420,
            family => 'ipv4',
            host_iface => 'ens20',
        },
        {
            address => '10.90.2.11',
            port => 4421,
            family => 'ipv4',
            host_iface => 'ens21',
        },
    ],
    'binds each target portal to its configured local interface',
);

eval {
    PVE::Storage::ZFSNVMePlugin::_configured_portals({
        'nvme-portals' => '10.90.1.11,10.90.2.11',
        'nvme-host-ifaces' => 'ens20',
    });
};
like($@, qr/one interface for each/, 'portal and host-interface counts must match');

$nvme_mock->redefine(_local_iface_exists => sub { return $_[0] eq 'ens20' });
eval {
    PVE::Storage::ZFSNVMePlugin::_validate_local_ifaces([
        { host_iface => 'ens20' },
        { host_iface => 'ens21' },
    ]);
};
like($@, qr/host interface 'ens21' does not exist/, 'missing local interface fails preflight');
$nvme_mock->redefine(_local_iface_exists => sub { return 1 });

eval {
    PVE::Storage::ZFSNVMePlugin::_assert_unique_target(
        'new-storage',
        {
            server => '192.0.2.10',
            pool => 'tank/new',
            subsysnqn => 'nqn.2026-07.example:duplicate',
        },
        {
            ids => {
                existing => {
                    type => 'zfsnvme',
                    server => '192.0.2.11',
                    pool => 'tank/existing',
                    subsysnqn => 'nqn.2026-07.example:duplicate',
                },
            },
        },
    );
};
like($@, qr/NQN is already used/, 'a subsystem NQN cannot be shared by storage definitions');

eval {
    PVE::Storage::ZFSNVMePlugin::_assert_unique_target(
        'new-storage',
        {
            server => '192.0.2.10',
            pool => 'tank/shared',
            subsysnqn => 'nqn.2026-07.example:new',
        },
        {
            ids => {
                existing => {
                    type => 'zfsnvme',
                    server => '192.0.2.10',
                    pool => 'tank/shared',
                    subsysnqn => 'nqn.2026-07.example:existing',
                },
            },
        },
    );
};
like($@, qr/ZFS pool .* is already used/, 'a target pool cannot be shared by storage definitions');

ok(
    !PVE::Storage::ZFSNVMePlugin::parse_nvme_host_ifaces('ens20,not/an/interface', 1),
    'rejects an invalid host interface name',
);

is(
    PVE::Storage::ZFSNVMePlugin::_live_portal_count(
        {
            '10.90.1.11:4420' => { state => 'live', host_iface => 'eth0' },
            '10.90.2.11:4420' => { state => 'live', host_iface => 'ens21' },
        },
        [
            { address => '10.90.1.11', port => 4420, host_iface => 'ens20' },
            { address => '10.90.2.11', port => 4420, host_iface => 'ens21' },
        ],
    ),
    1,
    'a live controller on the wrong interface is not an eligible path',
);

is(
    PVE::Storage::ZFSNVMePlugin::_validate_secret(
        'DHHC-1:01:YWJjZGVmZ2hpamtsbW5vcA==:',
    ),
    'DHHC-1:01:YWJjZGVmZ2hpamtsbW5vcA==:',
    'accepts an NVMe DH-HMAC-CHAP secret representation',
);

eval { PVE::Storage::ZFSNVMePlugin::_validate_secret('plaintext') };
like($@, qr/invalid NVMe DH-HMAC-CHAP/, 'rejects a plaintext secret');

$nvme_mock->redefine(zfs_get_lu_name => sub { return '12345678-1234-1234-1234-123456789abc' });

my $scfg = {};
my ($path, $vmid, $vtype) = PVE::Storage::ZFSNVMePlugin->path(
    $scfg,
    'vm-100-disk-0',
    'nvmetest',
);
is(
    $path,
    '/dev/disk/by-id/nvme-uuid.12345678-1234-1234-1234-123456789abc',
    'uses the stable namespace UUID symlink',
);
is($vmid, 100, 'returns the VM owner');
is($vtype, 'images', 'returns the volume type');
is_deeply(
    PVE::Storage::ZFSNVMePlugin->qemu_blockdev_options(
        $scfg,
        'nvmetest',
        'vm-100-disk-0',
        undef,
        {},
    ),
    {
        driver => 'host_device',
        filename => '/dev/disk/by-id/nvme-uuid.12345678-1234-1234-1234-123456789abc',
    },
    'uses the QEMU host_device driver',
);

eval {
    PVE::Storage::ZFSNVMePlugin->activate_volume(
        'nvmetest',
        $scfg,
        'vm-100-disk-0',
        'snapshot-with-hints',
        {},
        { 'guest-type' => 'qemu' },
    );
};
like(
    $@,
    qr/unable to activate snapshot from remote zfs storage/,
    'activate_volume accepts the current storage API hints argument',
);

$nvme_mock->redefine(activate_storage => sub { die "activation attempted\n" });
eval {
    PVE::Storage::ZFSNVMePlugin->activate_volume(
        'nvmetest',
        $scfg,
        'vm-100-disk-0',
    );
};
like(
    $@,
    qr/activation attempted/,
    'activate_volume accepts the short direct-call form used by cloud-init',
);
$nvme_mock->unmock('activate_storage');

is(
    PVE::Storage::ZFSNVMePlugin->deactivate_volume(
        'nvmetest',
        $scfg,
        'vm-100-disk-0',
    ),
    1,
    'deactivate_volume accepts the short direct-call form',
);

my $lio_mock = Test::MockModule->new('PVE::Storage::LunCmd::LIO');
my @provider_args;
$lio_mock->redefine(
    run_lun_command => sub {
        @provider_args = @_;
        return 'ok';
    },
);
is(
    PVE::Storage::ZFSPlugin->zfs_request(
        { iscsiprovider => 'LIO' },
        10,
        'add_view',
        'guid',
    ),
    'ok',
    'legacy LIO dispatch still works',
);
is(ref($provider_args[0]), 'HASH', 'provider dispatch does not inject a class argument');
is($provider_args[1], 10, 'provider timeout argument is preserved');
is($provider_args[2], 'add_view', 'provider method argument is preserved');
is($provider_args[3], 'guid', 'provider parameters are preserved');

my @connect_cmd;
$nvme_mock->redefine(
    run_command => sub {
        @connect_cmd = $_[0]->@*;
        return 0;
    },
);
PVE::Storage::ZFSNVMePlugin::_connect_portal(
    '/run/pve-storage/test.json',
    { subsysnqn => 'nqn.2026-07.example:test' },
    { address => '10.90.2.11', port => 4420, host_iface => 'ens21' },
);
is_deeply(
    [@connect_cmd[10, 11]],
    ['--host-iface', 'ens21'],
    'nvme connect is explicitly bound to the configured data interface',
);

PVE::Storage::ZFSNVMePlugin::_connect_portal(
    '/run/pve-storage/test.json',
    {
        subsysnqn => 'nqn.2026-07.example:test',
        'nvme-ctrl-loss-tmo' => 60,
        'nvme-fast-io-fail-tmo' => 15,
    },
    { address => '10.90.2.11', port => 4420, host_iface => 'ens21' },
);
my $connect_args = join(' ', @connect_cmd);
like(
    $connect_args,
    qr/--fast_io_fail_tmo 15/,
    'configured fast I/O fail timeout is passed to nvme connect',
);

$nvme_mock->redefine(
    zfs_request => sub {
        my ($class, $config, $timeout, $method, @params) = @_;
        return join(
            "\n",
            "tank/vm-100-disk-0\t1048576\t-\tvolume\t-",
            "tank/vm-200-disk-0\t1048576\t-\tvolume\t-",
            "tank/vm-300-disk-0\t1048576\t-\tvolume\t-",
            '',
        ) if $method eq 'list';
        return join(
            "\n",
            "tank/vm-100-disk-0\tnqn.2026-07.example:owned\tlocal",
            "tank/vm-200-disk-0\t-\t-",
            "tank/vm-300-disk-0\tnqn.2026-07.example:owned\tinherited from tank",
            '',
        ) if $method eq 'get';
        die "unexpected mocked ZFS method '$method'\n";
    },
);
my $owned_zvols = PVE::Storage::ZFSNVMePlugin->zfs_list_zvol(
    { pool => 'tank', subsysnqn => 'nqn.2026-07.example:owned' },
);
is_deeply(
    [sort keys $owned_zvols->%*],
    ['vm-100-disk-0'],
    'volume listing requires a local or received ownership property',
);

$nvme_mock->redefine(
    zfs_list_zvol => sub { return { 'vm-100-disk-0' => 1, 'base-200-disk-0' => 1 } },
);
eval {
    PVE::Storage::ZFSNVMePlugin->on_delete_hook(
        'nvmetest',
        { subsysnqn => 'nqn.2026-07.example:test' },
    );
};
like(
    $@,
    qr/refusing to remove.*base-200-disk-0, vm-100-disk-0/s,
    'storage removal requires an empty owned dataset on every cluster node',
);

eval {
    PVE::Storage::ZFSNVMePlugin->volume_resize(
        {}, 'nvmetest', 'vm-100-disk-0', 2 * 1024 * 1024 * 1024, 1, undef,
    );
};
like(
    $@,
    qr/online resize is not supported.*stop the VM first/,
    'online resize is rejected before mutating the backend',
);

$nvme_mock->redefine(
    _namespace_openers => sub { return ['qemu-system-x86_64 (PID 123, /dev/nvme0n1)'] },
);
eval {
    PVE::Storage::ZFSNVMePlugin->deactivate_storage(
        'nvmetest',
        { subsysnqn => 'nqn.2026-07.example:test' },
    );
};
like(
    $@,
    qr/refusing to disconnect.*namespace in use by qemu-system-x86_64/s,
    'storage deactivation refuses to remove a namespace opened by a VM',
);
$nvme_mock->redefine(_namespace_openers => sub { return [] });

my $update_key = 'DHHC-1:01:dXBkYXRlLXRlc3Qta2V5:';
$nvme_mock->redefine(file_read_firstline => sub { return $update_key });
my $zfs_parent_mock = Test::MockModule->new('PVE::Storage::ZFSPlugin');
$zfs_parent_mock->redefine(check_config => sub { return $_[2] });
eval {
    PVE::Storage::ZFSNVMePlugin->check_config(
        'nvmetest',
        { 'nvme-host-ifaces' => 'ens20,ens21' },
        0,
        1,
    );
};
is($@, '', 'check_config accepts a valid partial update');

eval {
    PVE::Storage::ZFSNVMePlugin::_validate_fail_fast_timeout(
        {
            'nvme-ctrl-loss-tmo' => 30,
            'nvme-fast-io-fail-tmo' => 31,
        },
        600,
    );
};
like(
    $@,
    qr/must not exceed nvme-ctrl-loss-tmo/,
    'fast I/O fail timeout cannot outlive the controller loss timeout',
);

eval {
    PVE::Storage::ZFSNVMePlugin::_validate_fail_fast_timeout(
        {
            'nvme-ctrl-loss-tmo' => -1,
            'nvme-fast-io-fail-tmo' => 30,
        },
        600,
    );
};
is($@, '', 'fast I/O fail remains valid with infinite controller reconnect');

{
    no warnings 'redefine';
    local *PVE::Storage::config = sub { return { ids => {} } };
    eval {
        PVE::Storage::ZFSNVMePlugin->on_update_hook_full(
            'nvmetest',
            {
                subsysnqn => 'nqn.2026-07.example:test',
                'nvme-portals' => '10.90.1.11,10.90.2.11',
                'nvme-host-nqns' => $hostnqn_a,
            },
            { 'nvme-host-ifaces' => 'ens20,ens21' },
            undef,
            {},
        );
    };
    is($@, '', 'partial update with no delete list validates against the current config');
}

my $nvmet_mock = Test::MockModule->new('PVE::Storage::LunCmd::NVMET');
my @helper_calls;
$nvmet_mock->redefine(
    run_command => sub {
        my ($cmd, %opts) = @_;
        push @helper_calls, { cmd => $cmd, %opts };
        return 0;
    },
);
PVE::Storage::LunCmd::NVMET::ensure_target(
    {
        server => '192.0.2.10',
        subsysnqn => 'nqn.2026-07.example:test',
        pool => 'tank/pve-nvme',
    },
    ['ipv4,10.90.1.11,4420'],
);
like(
    $helper_calls[0]->{input},
    qr/current_model.*current_serial.*refusing to take over existing NVMe subsystem/s,
    'target reconcile verifies model and deterministic serial before taking over a subsystem',
);
my ($ensure_port_body) = $helper_calls[0]->{input} =~ /^ensure_port\(\) \{\n(?<body>.*?)^\}/ms;
ok(defined($ensure_port_body), 'remote helper contains the port preparation function');
unlike(
    $ensure_port_body,
    qr{ln[ ]-s},
    'target setup does not publish a subsystem before ACL and namespace reconciliation',
);
like(
    $helper_calls[0]->{input},
    qr{^publish_target\(\).*?ln[ ]-s}ms,
    'the remote helper exposes the subsystem only in its publish operation',
);

@helper_calls = ();
PVE::Storage::LunCmd::NVMET::publish_target(
    {
        server => '192.0.2.10',
        subsysnqn => 'nqn.2026-07.example:test',
    },
    ['ipv4,10.90.1.11,4420'],
);
like(
    join(' ', $helper_calls[0]->{cmd}->@*),
    qr/publish-target/,
    'publishing the fully reconciled target is an explicit final operation',
);

my ($key_cmd, %key_opts);
$nvmet_mock->redefine(
    run_command => sub {
        ($key_cmd, %key_opts) = @_;
        return 0;
    },
);
my $test_key = 'DHHC-1:01:bm90LWEtcmVhbC1rZXk=:';
PVE::Storage::LunCmd::NVMET::set_host_key(
    { server => '192.0.2.10' },
    'nqn.2014-08.org.nvmexpress:uuid:12345678-1234-1234-1234-123456789abc',
    $test_key,
);
unlike(join(' ', $key_cmd->@*), qr/\Q$test_key\E/, 'DHCHAP key is absent from the process argv');
is($key_opts{input}, "$test_key\n", 'DHCHAP key is provided through standard input');

done_testing();

1;
