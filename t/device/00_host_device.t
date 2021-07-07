use warnings;
use strict;

use Carp qw(confess);
use Data::Dumper;
use File::Path qw(make_path);
use IPC::Run3 qw(run3);
use Mojo::JSON qw(decode_json encode_json);
use Ravada::Request;
use Test::More;
use YAML qw( Dump );

use lib 't/lib';
use Test::Ravada;

no warnings "experimental::signatures";
use feature qw(signatures);

use_ok('Ravada::HostDevice');


my $N_DEVICE = 0;
#########################################################

# we will try to find an unused bluetooth usb dongle

sub _search_unused_device {
    my @cmd =("lsusb");
    my ($in, $out, $err);
    run3(["lsusb"], \$in, \$out, \$err);
    for my $line ( split /\n/, $out ) {
        next if $line !~ /Bluetooth/;
        my ($filter) = $line =~ /(ID [a-f0-9]+):/;
        die "ID \\d+ not found in $line" if !$filter;
        return ("lsusb",$filter);
    }
}

sub _template_usb($vm) {
    if ( $vm->type eq 'KVM' ) {
    return (
        { path => "/domain/devices/hostdev"
        ,type => 'node'
        ,template => "<hostdev mode='subsystem' type='usb'>
            <source>
                <vendor id='0x<%= \$vendor_id %>'/>
                <product id='0x<%= \$product_id %>'/>
            </source>
        </hostdev>"
        })
    } elsif ($vm->type eq 'Void') {
        return (
            {path => "/hardware/host_devices"
            ,type => 'node'
            ,template => Dump( device => { device => 'hostdev'
                    , vendor_id => '<%= $vendor_id %>'
                    , product_id => '<%= $product_id %>'
            })
        });
    }
}

sub _template_xmlns($vm) {
    return (
        {path => "/domain"
            ,type => "namespace"
            ,template => "qemu='http://libvirt.org/schemas/domain/qemu/1.0'"
        }
        ,
        { path => "/domain/qemu:commandline"
                ,template => "
                <qemu:commandline>
    <qemu:arg value='-set'/>
    <qemu:arg value='device.hostdev0.x-igd-opregion=on'/>
    <qemu:arg value='-set'/>
    <qemu:arg value='device.hostdev0.display=on'/>
    <qemu:arg value='-display'/>
    <qemu:arg value='egl-headless'/>
  </qemu:commandline>"
    }
    );
}

sub _template_gpu($vm) {
    if ($vm->type eq 'KVM') {
        return (
                {path => "/domain"
                    ,type => "namespace"
                    ,template => "qemu='http://libvirt.org/schemas/domain/qemu/1.0'"
                }
                ,
                {path => "/domain/metadata/libosinfo:libosinfo"
                ,template => "<libosinfo:libosinfo xmlns:libosinfo='http://libosinfo.org/xmlns/libvirt/domain/1.0'>
      <libosinfo:os id='http://microsoft.com/win/10'/>
    </libosinfo:libosinfo>"
                }
                ,
                {path => "/domain/devices/graphics[\@type='spice']"
                 ,template =>  "<graphics type='spice' autoport='yes'>
                    <listen type='address'/>
                    <image compression='auto_glz'/>
                    <jpeg compression='auto'/>
                    <zlib compression='auto'/>
                    <playback compression='on'/>
                    <streaming mode='filter'/>
                    <gl enable='no' rendernode='/dev/dri/by-path/pci-<%= \$pci %> render'/>
                    </graphics>"
                }
                ,
                {path => "/domain/devices/graphics[\@type='egl-headless']"
                 ,template =>  "<graphics type='egl-headless'/>"
                }
                ,
                {
                    path => "/domain/devices/hostdev"
                 ,template =>
"<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci' display='off'>
    <source>
        <address uuid='<%= \$uuid %>'/>
    </source>
    <address type='pci' domain='0x0000' bus='0x00' slot='0x10' function='0x0'/>
</hostdev>"
                }
                ,
                { path => "/domain/qemu:commandline"
                ,template => "
                <qemu:commandline>
    <qemu:arg value='-set'/>
    <qemu:arg value='device.hostdev0.x-igd-opregion=on'/>
    <qemu:arg value='-set'/>
    <qemu:arg value='device.hostdev0.display=on'/>
    <qemu:arg value='-display'/>
    <qemu:arg value='egl-headless'/>
  </qemu:commandline>"
  }
            )
    } else {
        return (
                {path => "/hardware/host_devices"
                 ,template => Dump(
                     { 'device' => 'graphics'
                       ,"rendernode" => 'pci-<%= $pci %>'
                     }
                 )
                }
            );
    }
}

sub _template_args_usb {
    return encode_json ({
        vendor_id => 'ID ([a-f0-9]+)'
        ,product_id => 'ID .*?:([a-f0-9]+)'
    });
}

sub _template_args_gpu {
    return encode_json({
            pci => "0000:([a-f0-9:\.]+)"
            ,uuid => "_DEVICE_CONTENT_"
    });
}

sub _insert_hostdev_data_usb($vm, $name, $list_command, $list_filter) {
    my $sth = connector->dbh->prepare("INSERT INTO host_devices "
    ."(name, id_vm, list_command, list_filter, template_args ) "
    ." VALUES (?, ?, ?, ?, ? )"
    );
    $sth->execute(
        $name
        ,$vm->id,
        ,$list_command, $list_filter
        ,_template_args_usb()
    );
    _insert_hostdev_data_template(_template_usb($vm));
}

sub _insert_hostdev_data_gpu($vm, $name, $list_command, $list_filter) {
    my $sth = connector->dbh->prepare("INSERT INTO host_devices "
    ."(name, id_vm, list_command, list_filter, template_args ) "
    ." VALUES (?, ?, ?, ?, ? )"
    );
    $sth->execute(
        $name
        ,$vm->id,
        ,$list_command, $list_filter
        ,_template_args_gpu()
    );
    _insert_hostdev_data_template(_template_gpu($vm));
}

sub _insert_hostdev_data_xmlns($vm, $name, $list_command, $list_filter) {
    my $sth = connector->dbh->prepare("INSERT INTO host_devices "
    ."(name, id_vm, list_command, list_filter, template_args ) "
    ." VALUES (?, ?, ?, ?, ? )"
    );
    $sth->execute(
        $name
        ,$vm->id,
        ,$list_command, $list_filter
        ,_template_args_gpu()
    );
    _insert_hostdev_data_template(_template_xmlns($vm));
}


sub _insert_hostdev_data_template(@template) {
    my $id = Ravada::Request->_last_insert_id(connector());

    my $sth = connector->dbh->prepare("INSERT INTO host_device_templates "
        ." ( id_host_device, path, template , type ) "
        ." VALUES ( ?, ? , ? , ?)"
    );
    for my $template(@template) {
        $template->{type} = 'node' if !$template->{type};
        $sth->execute($id, $template->{path}, $template->{template}, $template->{type});
    }
}


sub _check_hostdev_kvm($domain, $expected=0) {
    my $doc = XML::LibXML->load_xml(string => $domain->domain->get_xml_description);
    my @hostdev = $doc->findnodes("/domain/devices/hostdev");
    is(scalar @hostdev, $expected, $domain->name) or confess ;
}

sub _check_hostdev_void($domain, $expected=0) {
    my $doc = $domain->_load();
    my @hostdev;
    for my $dev ( @{ $doc->{hardware}->{host_devices} } ) {
        push @hostdev,($dev);
        for my $item ( keys %$dev ) {
            like($item,qr/^\w+$/);
            like($dev->{$item}, qr(^[0-9a-z]+$)) or die Dumper($dev);
        }
    }
    is(scalar @hostdev, $expected) or confess Dumper($domain->name, $doc->{hardware});

}

sub _check_hostdev($domain, $expected=0) {
    if ($domain->type eq 'KVM') {
        _check_hostdev_kvm($domain, $expected);
    } elsif ($domain->type eq 'Void') {
        _check_hostdev_void($domain, $expected);
    }
}

sub test_devices($host_device, $expected_available, $match = undef) {
    my @devices = $host_device->list_devices();
    ok(scalar(@devices));

    my @devices_available = $host_device->list_available_devices();
    is(scalar(@devices_available) , $expected_available) or confess;

    return if !$match;

    for (@devices) {
        like($_,qr($match));
    }
}

sub test_host_device_usb($vm) {

    my ($list_command,$list_filter) = _search_unused_device();
    unless ( $list_command ) {
        diag("SKIPPED: install a USB device to test");
        return;
    }
    _insert_hostdev_data_usb($vm, "USB Test", $list_command, $list_filter);

    my @list_hostdev = $vm->list_host_devices();
    is(scalar @list_hostdev, 1);

    isa_ok($list_hostdev[0],'Ravada::HostDevice');

    my $base = create_domain($vm);
    $base->_set_controller_usb(5) if $base->type eq 'KVM';

    $base->add_host_device($list_hostdev[0]);
    my @list_hostdev_b = $base->list_host_devices();
    is(scalar @list_hostdev_b, 1);

    test_devices($list_hostdev[0],1, "Bluetooth");

    $base->prepare_base(user_admin);
    my $clone = $base->clone(name => new_domain_name
        ,user => user_admin
    );
    my @list_hostdev_c = $clone->list_host_devices();
    is(scalar @list_hostdev_c, 1) or exit;

    _check_hostdev($clone);
    $clone->start(user_admin);
    _check_hostdev($clone, 1);

    shutdown_domain_internal($clone);
    eval { $clone->start(user_admin) };
    is(''.$@, '');
    _check_hostdev($clone, 1) or exit;

    #### it will fail in another clone

    my $clone2 = $base->clone( name => new_domain_name
        ,user => user_admin
    );
    eval { $clone2->start(user_admin) };
    like ($@ , qr(No available devices));

    $list_hostdev[0]->remove();
    my @list_hostdev2 = $vm->list_host_devices();
    is(scalar @list_hostdev2, 0);

    remove_domain($base);
    test_db_host_devices_removed($base, $clone);

    $list_hostdev[0]->remove();
}

sub _create_mock_devices($n_devices, $type, $value="fff:fff") {
    my $path  = "/var/tmp/$</ravada/dev";
    make_path($path) if !-e $path;

    my $name = base_domain_name()." $type Mock_device ID";

    opendir my $dir,$path or die "$! $path";
    while ( my $file = readdir $dir ) {
        next if $file !~ /^$name/;
        unlink "$path/$file" or die "$! $path/$file";
    }
    closedir $dir;

    for ( 1 .. $n_devices ) {
        open my $out,">","$path/${name} $N_DEVICE$value$_ Foo bar"
            or die $!;
        print $out "fff6f017-3417-4ad3-b05e-17ae3e1a461".int(rand(10));
        close $out;
    }
    $N_DEVICE ++;
    return (encode_json(["find","$path/"]),$name);
}

sub test_host_device_usb_mock($vm) {

    my $n_devices = 3;
    my ($list_command,$list_filter) = _create_mock_devices( $n_devices , "USB" );

    _insert_hostdev_data_usb($vm, "USB Mock", $list_command, $list_filter);

    my @list_hostdev = $vm->list_host_devices();
    is(scalar @list_hostdev, 1);

    isa_ok($list_hostdev[0],'Ravada::HostDevice');

    my $base = create_domain($vm);
    $base->_set_controller_usb(5) if $base->type eq 'KVM';

    $base->add_host_device($list_hostdev[0]);
    my @list_hostdev_b = $base->list_host_devices();
    is(scalar @list_hostdev_b, 1);

    $base->prepare_base(user_admin);

    my @clones;
    for my $n ( 1 .. $n_devices+1 ) {
        my $clone = $base->clone(name => new_domain_name
            ,user => user_admin
        );

        _check_hostdev($clone, 0 );
        eval { $clone->start(user_admin) };
        diag($clone->name." ".($@ or ''));
        # the last one should fail
        if ($n > $n_devices) {
            like( ''.$@,qr(No available devices));
            _check_hostdev($clone, 0);
        } else {
            like( ''.$@,qr(Did not find USB device)) if $vm->type eq 'KVM';
            is( ''.$@, '' ) if $vm->type eq 'Void';
            _check_hostdev($clone, 1);
        }
        is(scalar($clone->list_host_devices_attached()),1, $clone->name);
        push @clones,($clone);
    }
    $clones[0]->shutdown_now(user_admin);
    _check_hostdev($clones[0], 1);
    my @devs_attached = $clones[0]->list_host_devices_attached();
    is(scalar(@devs_attached),1);
    is($devs_attached[0]->{is_locked},0);

    $list_hostdev[0]->_data('enabled' => 0 );
    is( scalar($vm->list_host_devices()) , 1 );
    is( scalar($base->list_host_devices()), 0);
    is( scalar($clones[0]->list_host_devices()), 0);
    is( scalar($clones[0]->list_host_devices_attached()), 0);

    my $clone_nhd = $base->clone(name => new_domain_name, user => user_admin);
    eval { $clone_nhd->start( user_admin ) };

    is( scalar($clone_nhd->list_host_devices()), 0);
    is( scalar($clone_nhd->list_host_devices_attached()), 0);

    remove_domain($base);
    $list_hostdev[0]->remove();
    test_db_host_devices_removed($base, @clones);
}

sub test_db_host_devices_removed(@domains) {
    my $sth = connector->dbh->prepare("SELECT count(*) from host_devices_domain "
        ." WHERE id_domain=?"
    );
    for my $domain ( @domains ) {
        $sth->execute($domain->id);
        my ($count) = $sth->fetchrow;
        is($count,0,"Expecting host_device_domain removed from db ".$domain->name) or confess;
    }

    $sth = connector->dbh->prepare("SELECT count(*) FROM host_devices ");
    $sth->execute();
    my ($count) = $sth->fetchrow;
    is($count, 0, "Expecting no host devices") or confess;
}

sub test_domain_path_kvm($domain, $path) {
    my $doc = XML::LibXML->load_xml(string
            => $domain->domain->get_xml_description(Sys::Virt::Domain::XML_INACTIVE))
        or die "ERROR: $!\n";

    confess if !$path;

    my @nodes = $doc->findnodes($path);
    is(scalar @nodes, 1, "Expecting $path in ".$domain->name) or exit;

}

sub test_domain_path_void($domain, $path) {
    my $data = $domain->_load();
    my $found_parent;

    my ($parent, $entry) = $path =~ m{/(.*)/(.*)};
    confess "Error: $path hauria de ser parent/entry" if !$entry;
    for my $entry ( split m{/},$parent ) {
        $found_parent = $data->{$entry} or last;
        $data = $found_parent;
    }
    ok($found_parent, "Expecting $parent in ".$domain->name) or die Dumper($domain->name, $data);
    my $found;
    if (ref($found_parent) eq 'ARRAY') {
        for my $item (@$found_parent) {
            confess "Error: item has no device field ".Dumper($found_parent, $entry)
            if !exists $item->{device} || !defined $item->{device};
            $found = $item->{device} if $item->{device} eq $entry;
        }
    }
    ok($found,"Expecting $entry in ".Dumper($parent)) or exit;
}


sub test_hostdev_gpu_kvm($domain) {
    for my $path (
        # the next one returns XPath error : Undefined namespace prefix
        #"/domain/metadata/libosinfo:libosinfo"
        #,
         "/domain/devices/graphics[\@type='spice']"
        ,"/domain/devices/graphics[\@type='spice']/gl"
        ,"/domain/devices/graphics[\@type='egl-headless']"
        ,"/domain/devices/hostdev[\@model='vfio-pci']"
        ,"/domain/qemu:commandline"
    ) {
        test_domain_path_kvm($domain, $path);
    }
}

sub test_hostdev_gpu_void($domain) {
    for my $path (
        "/hardware/host_devices/graphics" ) {
        test_domain_path_void($domain, $path);
    }
}

sub test_hostdev_gpu($domain) {
    if ($domain->type eq 'KVM') {
        test_hostdev_gpu_kvm($domain);
    } elsif ($domain->type eq 'Void') {
        test_hostdev_gpu_void($domain);
    }
}

sub test_host_device_gpu($vm) {
    my $n_devices = 3;
    my ($list_command,$list_filter) = _create_mock_devices( $n_devices, "GPU" , "0000:00:02." );

    _insert_hostdev_data_gpu($vm, "GPU Mock", $list_command, $list_filter);

    my @list_hostdev = $vm->list_host_devices();

    my $base = create_domain($vm);
    $base->add_host_device($list_hostdev[0]);
    eval { $base->start(user_admin) };
    like ($@,qr{^($|.*Unable to stat|.*device not found.*mediated)} , $base->name) or exit;

    test_hostdev_gpu($base);

    $list_hostdev[0]->remove();
    remove_domain($base);
}

sub test_xmlns($vm) {
    return if $vm->type ne 'KVM';
    my ($list_command,$list_filter) = _create_mock_devices( 1, "GPU" , "0000:00:02." );

    _insert_hostdev_data_xmlns($vm, "GPU Mock", $list_command, $list_filter);

    my @list_hostdev = $vm->list_host_devices();

    my $base = create_domain($vm);
    $base->add_host_device($list_hostdev[0]);
    eval { $base->start(user_admin) };
    like ($@,qr{^($|.*Unable to stat|.*device not found.*mediated|.*there is no device "hostdev)} , $base->name) or exit;

    my $doc = XML::LibXML->load_xml( string => $base->domain->get_xml_description);
    my ($domain_xml) = $doc->findnodes("/domain");

    my ($xmlns) = $domain_xml =~ m{xmlns:qemu=["'](.*?)["']}m;
    my ($line1) = $domain_xml =~ m{(<domain.*)}m;
    ok($xmlns,"Expecting xmlns:qemu namespace in ".$line1) or exit;
    is($xmlns, "http://libvirt.org/schemas/domain/qemu/1.0") or exit;

    $list_hostdev[0]->remove();
    remove_domain($base);

}

#########################################################

clean();

for my $vm_name ( reverse vm_names()) {
    my $vm;
    eval { $vm = rvd_back->search_vm($vm_name) };

    SKIP: {

        my $msg = "SKIPPED: $vm_name virtual manager not found ".($@ or '');

        diag($msg)      if !$vm;
        skip($msg,10)   if !$vm;

        diag("Testing host devices in $vm_name");

        test_xmlns($vm);
        test_host_device_gpu($vm);

        test_host_device_usb($vm);

        test_host_device_usb_mock($vm);

    }
}

end();
done_testing();
