#!/build/perlbrew/perls/perl-5.10.1/bin/perl
# Author: Matthew Mallard
# Website: www.q-technologies.com.au
# 

use strict;
use warnings;
use 5.10.0;
use VMware::VIRuntime;
use English;
use Getopt::Std;
use lib "/root/perl5/lib/perl5";
#use lib "/usr/share/perl5";
use lib "/usr/local/perl5/lib/perl5";
use lib "/usr/local/share/perl5";
use Term::ReadKey;
use YAML qw(Dump LoadFile);
use Data::Dumper;
use Term::ANSIColor;

use constant DEBUG_MSG => "debug";
use constant ERROR_MSG => "error";

# Globals
my $main_config = "/build/config/settings.yaml";
my $ip_lookup_data = "/build/config/ip_lookup.yaml";
my ($vi_servers, $vm_fields, $clusters, $datastores, $guest_creds, $guest_boot_timeout);
my $ignore_exit = 0;
our( $opt_v, $opt_d );

$ENV{PERL_NET_HTTPS_SSL_SOCKET_CLASS} = 'Net::SSL';
$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;

# Process command line options
getopts('vd');

if( $EUID == 0 ){
    fatal_err( "Error: do not run this as root or with sudo!" );
}

# Load main settings
if( -r $main_config ){
    my $mc;
    eval { $mc = LoadFile( $main_config ) };
    fatal_err("There was an error parsing the YAML in $main_config.  Details:\n\n$@" ) if( $@ );
    check_main_setting( $mc, \$vi_servers, "vi_servers", "VirtualCenter server" );
    check_main_setting( $mc, \$vm_fields, "vm_fields", "VM field definitions" );
    check_main_setting( $mc, \$clusters, "clusters", "valid VI Clusters" );
    check_main_setting( $mc, \$datastores, "datastores", "DataStore preferences" );
    check_main_setting( $mc, \$guest_creds, "guest_creds", "Guest Credentials" );
    check_main_setting( $mc, \$guest_boot_timeout, "guest_boot_timeout", "Guest Booting Timeout" );
} else {
    fatal_err( "could not read the main configuration file ($main_config)");
}

# Process arguments
fatal_err( "Please specify the YAML files to be processed as the script arguments") if( ! @ARGV );
my $new_vms;
for( @ARGV ){
    if( -r $_ ){
        my $new_vm;
        eval { $new_vm = LoadFile( $_ )};
        fatal_err("There was an error parsing the YAML in $_.  Details:\n\n$@" ) if( $@ );
        $new_vm->{from_file} = $_;
        push @$new_vms, $new_vm;
    }
}

#say Dump( $new_vms );

# Create the VMs
for my $new_vm ( @$new_vms ){
    my ( $vi_server, $vi_port, $vi_api_loc, $vi_url );
    my $guest_name = check_vm_inputs( $new_vm, 'guest_name' );
    my $guest_id = check_vm_inputs( $new_vm, 'guest_id' );
    #my $network = check_vm_inputs( $new_vm, 'network' );
    my $ip_addresses = check_vm_inputs( $new_vm, 'ip_address' );
    my $template = check_vm_inputs( $new_vm, 'template' );
    my $memory = check_vm_inputs( $new_vm, 'memory' );
    my $vcpus = check_vm_inputs( $new_vm, 'vcpus' );
    my $extra_disk_gb = check_vm_inputs( $new_vm, 'extra_disk_gb' );
    #my $datacenter = check_vm_inputs( $new_vm, 'datacenter' );
    my $folder = check_vm_inputs( $new_vm, 'folder' );
    my $puppet_facts = check_vm_inputs( $new_vm, 'puppet_facts' );

    my $ip_address = shift @$ip_addresses;
    my( $datacenter, $network ) = find_dc_net( $ip_address );
    my %extra_nets;
    for my $ip ( @$ip_addresses ){
        my( $datacenter, $network ) = find_dc_net( $ip );
        $extra_nets{$network} = $ip
    }

    my $puppet_role;
    if( defined($puppet_facts->{role}) ){
        $puppet_role = $puppet_facts->{role};
        debug_msg( "Puppet role is: ".var($puppet_role) );
    } else {
        fatal_err( "Could not successfully determine the Puppet role from the specified facts" ); 
    }

    info_msg( "Beginning process of creating a new VM called: ".var($guest_name)." on '".var($network)."' network" );

    # Find VI server to connect to and connect
    for my $vi_net ( @$vi_servers ){
        if( $network =~ qr/$vi_net->{match_net}/ ){
            $vi_server = $vi_net->{server};
            $vi_port = $vi_net->{port};
            $vi_api_loc = $vi_net->{api_loc};
            last;
        }
    }
    $vi_port = '443' if ! $vi_port;
    $vi_api_loc = '/sdk/vimService' if ! $vi_api_loc;
    $vi_url = "https://$vi_server:$vi_port$vi_api_loc";
    my $session_file = $ENV{HOME}.'/.visession.'.$vi_server;
    my $vim;
    $vim = connect_to_vi( $vi_url, $session_file );

    my $dc_view = get_dc_view( $vim, $datacenter );

    my $esx_folder = get_esx_folder_ref($vim, $dc_view, $folder);
    my( $esx_host, $datastore ) = get_esx_host_and_ds( $vim, $dc_view, $clusters, $datastores );

    #next;
    
#=begin GHOSTCODE
    clone_vm( $vim, $dc_view, { 
                        ds => $datastore, 
                        host => $esx_host,
                        folder => $esx_folder,
                        base_vm => $template,
                        new_vm => { name => $guest_name,
                                    memoryMB => $memory,
                                    numCPUs => $vcpus,
                                    guestId => $guest_id,
                                  },
                      } );
#=end GHOSTCODE

#=cut
    my $vm = get_vm_ref( $vim, $dc_view, $guest_name );

    # Make sure it is powered off
    ensure_vm_off( $vm );

    # Set the network for the primary adapter
    set_vm_net( $vm, $network );

    # Add additional network adapters
    for my $net ( keys %extra_nets ){
        add_vm_net( $vm, $net );
    }

    # Add additional Hard Disks
    add_disk_to_vm( $vm, $extra_disk_gb );

    # Add Metadata to VI

    # Make sure it is powered on
    ensure_vm_on( $vm );

    # Wait until we can successfully launch a command
    info_msg( "Waiting for the VM guest tools to be operational" );
    my $start_time = time;
    while(1){
        my $elapsed_time = (time - $start_time);
        debug_msg( "Testing running command on guest now: ".var($elapsed_time)." of ".var($guest_boot_timeout)." seconds" );
        #$@ = try_cmd( \&run_cmd_on_vm( $vim, $vm, "/usr/bin/uptime", "", $guest_creds->{user}, $guest_creds->{passwd} ) );
        #eval { run_cmd_on_vm( $vim, $vm, "/usr/bin/uptime", "", $guest_creds->{user}, $guest_creds->{passwd} ) };
        my $quiet = 1;
        my $ans = run_cmd_on_vm( $vim, $vm, "/usr/bin/uptime", "", $guest_creds->{user}, $guest_creds->{passwd}, $quiet );
        #say $@;
        last if $ans->{success};
        # Try every 5 seconds
        if( $elapsed_time > $guest_boot_timeout ){
            fatal_err( "Could not successfully run a command on the guest within the timeframe: ".
                       var($guest_boot_timeout)." seconds" );
        }
        sleep 5;
    }
    info_msg( "Waiting for the VM to be fully booted" );
    #sleep 10; #Give it some extra time to finish boot scripts

    # Add some Puppet facts to the guest
    info_msg( "Adding the Puppet facts" );

    # Configure the IP address inside the guest and bootstrap the additional install
    my $quiet = 0;
    my $ans = run_cmd_on_vm( $vim, $vm, "/root/setup.sh", "$guest_name $ip_address $puppet_role", $guest_creds->{user}, $guest_creds->{passwd}, $quiet );

    fatal_err( "Could not successfully run the command on the VM!  Details:\n\n".$ans->{details} ) if not $ans->{success}; 

}

sub connect_to_vi {
    my $url = shift;
    my $session_file = shift;

    my $vim = Vim->new(service_url => $url);

    info_msg( "Connecting to ".var($url)."...");
#=begin IGNORE
    my $service_instance;
    if( -r $session_file ){
        eval { $vim->load_session(session_file => $session_file ) };
        #say $@;
        if( $@ ){
            #fatal_err( "There was a problem loading the session file!  Details:\n\n".$@ );
            debug_msg( "The session file was not valid - probably timed out" );
        } else {
            $service_instance = $vim->get_service_instance();
            #say "here";
            #say $service_instance->CurrentTime();
        }
    }
    if( ! $service_instance ){
#=end IGNORE
#=cut
        say "Your session has timed out, you will need to log in again.  Enter your vCenter credentials here:";
        #say "Enter your vCenter credentials here:";
        print "User name: ";
        chomp( my $username = <STDIN>);
        print "Password: ";
        ReadMode('noecho'); # don't echo
        chomp( my $password = <STDIN>);
        ReadMode(0);        # back to normal
        print "\n";
        $vim->login(user_name => $username, password => $password);
        $vim->save_session(session_file => $session_file);
#=begin IGNORE
    }
#=end IGNORE
#=cut

    return $vim
}

sub clone_vm {
    my $vim = shift;
    my $dc_view = shift;
    my %args = %{shift(@_)};

    info_msg( "Cloning ".var($args{new_vm}->{name})." from ".var($args{base_vm}) );

    my $ds_view = $vim->find_entity_view( view_type => 'Datastore', 
                                          filter => {'name' => $args{ds}},
                                          begin_entity => $dc_view,
                                        );

    my $host_view = $vim->find_entity_view( view_type => 'HostSystem', 
                                            filter => {'name' => $args{host}},
                                            begin_entity => $dc_view,
                                          );

    my $comp_res_view = $vim->get_view(mo_ref => $host_view->parent);

    my $relocate_spec = VirtualMachineRelocateSpec->new( datastore => $ds_view,
                                                         host => $host_view,
                                                         pool => $comp_res_view->resourcePool,
                                                       );

    my $vm_config_spec = VirtualMachineConfigSpec->new( %{$args{new_vm}} );

    my $clone_spec = VirtualMachineCloneSpec->new( powerOn => 0,
                                                   template => 0,
                                                   location => $relocate_spec,
                                                   config => $vm_config_spec,
                                                 );

    my $vm_view = $vim->find_entity_views( view_type => 'VirtualMachine', 
                                           filter => {'name' =>$args{base_vm}},
                                            begin_entity => $dc_view,
                                         );
    if(@$vm_view) {
        foreach (@$vm_view) {
            eval {
               $_->CloneVM( folder => $args{folder},
                            name => $args{new_vm}->{name},
                            spec => $clone_spec
                          );
            };
            fatal_err( "Could not clone the VM!  Details:\n\n".$@ ) if $@; 
        }
    } else {
        die "Could not find the reference (base) VM to clone";
    }
}

sub get_vm_ref {
    my $vim = shift;
    my $dc_view = shift;
    my $guest_name = shift;
    my $vm_views = $vim->find_entity_views( view_type => 'VirtualMachine', 
                                            filter => { 'name' => $guest_name },
                                            begin_entity => $dc_view,
                                          );
    my $vm = shift @$vm_views;
    fatal_err("Could not get the object reference to $guest_name from VI") if( ! $vm );
    
    return $vm;
}

sub info_msg {
    chomp( my $msg = shift );
    my $level = shift;
    $level = "" if ! $level;
    my $color = "green";
    my $var_col = "black on_white";
    my $prefix = "Info";
    my $say = ($opt_v or $opt_d);
    my $extra_nl = "";
    my $excl = "";
    if( $level eq DEBUG_MSG ){
        $color = "magenta";
        $var_col = "blue";
        $prefix = "Debug";
        $say = $opt_d;
    } elsif( $level eq ERROR_MSG ){
        $color = "red";
        $var_col = "yellow";
        $prefix = "Error";
        $say = 1;
        $extra_nl = "\n";
        $excl = "!";
    }
    for( $msg ){
        my $code1 = color("reset").color( $var_col );
        my $code2 = color("reset").color( $color );
        s/%%/$code1/g;
        s/##/$code2/g;
    }
    say color($color).$extra_nl.$prefix.": ".$msg.$excl.$extra_nl.color("reset") if $say;
}

sub var {
    return '%%'.shift.'##';
}

sub debug_msg {
    my $msg = shift;
    info_msg( $msg, DEBUG_MSG );
}

sub fatal_err {
    my $msg = shift;
    my $val = shift;
    $val = 1 if ! defined( $val );
    info_msg( $msg, ERROR_MSG );
    #exit $val if not $ignore_exit;
    #die;
    exit $val;
}

sub check_vm_inputs {
    my $vm = shift;
    my $key = shift;
    my $validate = $vm_fields->{$key}{validate};

    if( $vm_fields->{$key}{required} and ! defined($vm->{$key}) and ! $vm_fields->{$key}{default} ){
        fatal_err( "could not find the required key '$key' in ".$vm->{from_file}." and there is no default");
    }
    if( $validate and defined($vm->{$key}) ){
        if( $key eq "ip_address" ){
            my $ref = $vm->{$key};
            my $invalid = 0;
            if( ref($ref) eq $validate ){
                for( @$ref ){
                    if( ! /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/ ){
                        $invalid = 1;
                        last;
                    }
                }
                return $ref if not $invalid;
            }
            fatal_err( "'$key' in ".$vm->{from_file}." is not in a valid format");
        } elsif( $key eq "puppet_facts" ){
            my $ref = $vm->{$key};
            my $invalid = 0;
            if( ref($ref) eq $validate ){
                for( keys %$ref ){
                    if( ! /^[a-z0-9_]+$/ ){
                        $invalid = 1;
                        last;
                    }
                }
                return $ref if not $invalid;
            }
            fatal_err( "'$key' in ".$vm->{from_file}." is not in a valid format");
        } elsif( $vm->{$key} !~ /$validate/ ){
                fatal_err( "'$key' in ".$vm->{from_file}." is not in a valid format");
        }
    }
    
    return $vm->{$key} if defined($vm->{$key});
    return $vm_fields->{$key}{default} if $vm_fields->{$key}{required};
    return "";
}

# Add a disk to the guest
sub add_disk_to_vm {
    my $vm = shift;
    my $disk_size_gb = shift;
    info_msg( "Adding a new Virtual Disk of ".var($disk_size_gb)." GB: to ".var($vm->name) );

    my $controller = find_device($vm, 'ParaVirtualSCSIController', 'SCSI controller 0');
    my $controllerKey = $controller->key;
    my $unitNumber = $#{$controller->device} + 1;

    # valid combinations are 'persistent', 'independent_persistent' and 'independent_nonpersistent'
    my $diskMode = 'persistent';

    # Generate the filename of the VMDK - assume it's in the same directory as the primary
    my $name = $vm->name."/extra_disk_".$unitNumber;
    my $path = $vm->config->files->vmPathName;
    $path =~ /^(\[.*\])/;
    my $fileName = "$1/$name";
    $fileName .= ".vmdk" unless ($fileName =~ /\.vmdk$/);

    # Create a new virtual disk
    my $disk = VirtualDisk->new( controllerKey => $controllerKey,
                                 unitNumber => $unitNumber,
                                 key => -1,
                                 backing => VirtualDiskFlatVer2BackingInfo->new( diskMode => $diskMode, 
                                                                                 fileName => $fileName,
                                                                               ),
                                 capacityInKB => $disk_size_gb*1024*1024,
                               );
    my $devspec = VirtualDeviceConfigSpec->new( operation => VirtualDeviceConfigSpecOperation->new('add'),
                                                device => $disk,
                                                fileOperation => VirtualDeviceConfigSpecFileOperation->new('create'),
                               );                           
    my $vmspec = VirtualMachineConfigSpec->new( deviceChange => [$devspec] );
    eval {
       $vm->ReconfigVM( spec => $vmspec );
    };
    fatal_err( "Could not add the extra disk to the VM!  Details:\n\n".$@ ) if $@; 

}

# Update the network settings on a guest
sub set_vm_net {
    my $vm = shift;
    my $network = shift;
    info_msg( "Setting the network to '".var($network)."' on the primary NIC on ".var($vm->name) );

    # Find the device and update the backing network
    my $device = find_device($vm, 'VirtualVmxnet3', 'Network adapter 1');
    $device->backing( VirtualEthernetCardNetworkBackingInfo->new(deviceName => $network) );

    # Create an edit operation and perform it
    my $devspec = VirtualDeviceConfigSpec->new( operation => VirtualDeviceConfigSpecOperation->new('edit'),
                                                device => $device);
    my $vmspec = VirtualMachineConfigSpec->new( deviceChange => [$devspec] );
    eval {
       $vm->ReconfigVM( spec => $vmspec );
    };
    fatal_err( "Could not update the network settings on the primary NIC!  Details:\n\n".$@ ) if $@; 
}

# Add a new network card to a guest
sub add_vm_net {
    my $vm = shift;
    my $network = shift;

    info_msg( "Adding a new NIC on the '".var($network)."' network to ".var($vm->name) );

    # Create a new network device and set the backing network
    my $device = VirtualVmxnet3->new( key => -1, 
                                      backing => VirtualEthernetCardNetworkBackingInfo->new(deviceName => $network));

    # Create an add operation and perform it
    my $devspec = VirtualDeviceConfigSpec->new( operation => VirtualDeviceConfigSpecOperation->new('add'),
                                                device => $device);
    my $vmspec = VirtualMachineConfigSpec->new( deviceChange => [$devspec] );
    eval {
       $vm->ReconfigVM( spec => $vmspec );
    };
    fatal_err( "Could not add a new network interface to the VM!  Details:\n\n".$@ ) if $@; 
}

# Find a VM's device by type and label
sub find_device {
   my $vm = shift;
   my $type = shift;
   my $label = shift;
   my $devices = $vm->config->hardware->device;
   foreach my $device (@$devices) {
      my $class = ref $device;
      if($class->isa($type) and $label eq $device->deviceInfo->label ) {
         return $device;
      }
   }
   return undef;
}


sub check_main_setting {
    my $mc = shift;
    my $var = shift;
    my $key = shift;
    my $desc = shift;
    if( defined($mc->{$key}) ){
        ${$var} = $mc->{$key};
    } else {
        fatal_err( "could not find the $desc in the main configuration file");
    }
}

sub get_esx_folder_ref {
    my $vim = shift;
    my $dc_view = shift;
    my $folder = shift;
    my $folders_by_int = {}; # keyed off the internal VI name
    my $folders_by_path = {}; # keyed off the Full Path name

    # Find all folders
    my $fldr_views = $vim->find_entity_views( view_type => 'Folder',
                                              begin_entity => $dc_view,
                                            );
    foreach my $fldr (@$fldr_views) {
        # See if folder has a parent
        my $parent;
        $parent = $fldr->{'parent'}->value if defined( $fldr->{'parent'} );
        # If it has children , find them
        my @children;
        if( defined( $fldr->childEntity) ){
            for my $child ( @{$fldr->childEntity} ){
                push @children, $child->value if $child->type eq "Folder";
            }
        }
        # Build a hash using the internal folder name as the key, keep track of its
        # proper name, children and VIM object.
        $folders_by_int->{$fldr->{'mo_ref'}->value} = { name => $fldr->name, children => \@children, mo_ref => $fldr };
    }
    # Now traverse the Folder structure starting from the internal parent (vm)
    # and build a new hash using the UNIX-like path name as the key
    $fldr_views = $vim->find_entity_views( view_type => 'Folder', 
                                           filter => { 'name' => 'vm' },
                                           begin_entity => $dc_view,
                                         );
    foreach my $fldr (@$fldr_views) {
        traverse_esx_folder( $folders_by_int, $folders_by_path, $fldr->{'mo_ref'}->value );
    }

    # if the specified folder was found return the perl object of it
    return $folders_by_path->{$folder} if defined( $folders_by_path->{$folder} );

    # if the specified folder was not found throw a fatal error
    fatal_err( "$folder was not found in the vCenter folder structure" );
    
}

sub traverse_esx_folder {
    my $folders_by_int = shift;
    my $folders_by_path = shift;
    my $key = shift;
    my $parent = shift;
    my $fullpath = $folders_by_int->{$key}{name};
    $fullpath = $parent."/".$fullpath if $parent and $parent ne "vm";
        #say $key . " = ".$fullpath if $fullpath ne "vm";
        $folders_by_path->{$fullpath} = $folders_by_int->{$key}{mo_ref} if $fullpath ne "vm";
        for( @{$folders_by_int->{$key}{children}} ){
            traverse_esx_folder( $folders_by_int, $folders_by_path, $_, $fullpath );
        }
}

sub get_esx_host_and_ds {
    my $vim = shift;
    my $dc_view = shift;
    my $clusters = shift;
    my $datastores = shift;

    my $ds_bl;
    $ds_bl = $datastores->{blacklist};

    $datastores = {};
    my $ds_views = $vim->find_entity_views( view_type => 'Datastore', 
                                            begin_entity => $dc_view,
                                          );
    info_msg( "Finding all Datastores..." );
    for my $ds (@$ds_views){
        my $blacklisted = ( $ds->name =~ qr/$ds_bl/ ) ? "yes" : "no";
        debug_msg( "\tFound ".$ds->name.": ".join( " - ", "Free GB: ".$ds->info->freeSpace/1024/1024/1024, 
                                               "Capacity GB: ".$ds->summary->capacity/1024/1024/1024, 
                                               "Accessible: ".$ds->summary->accessible, 
                                               "Maint Mode: ".$ds->summary->maintenanceMode, 
                                               "Status: ". $ds->overallStatus->val,
                                               "Blacklisted: $blacklisted",
                                      ) );
        $datastores->{$ds->name} = { free_gb => $ds->info->freeSpace/1024/1024/1024,
                                     total_gb => $ds->summary->capacity/1024/1024/1024, 
                                   } if $ds->summary->accessible == 1 and 
                                        $ds->summary->maintenanceMode eq "normal" and 
                                        $ds->overallStatus->val eq "green" and
                                        $ds->name !~ qr/$ds_bl/;
    }
    #say Dump( $datastores );

    my $cluster_map = get_cluster_map( $vim, $dc_view );
    #say Dump( $cluster_map );

    my $hosts = {};
    my $host_views = $vim->find_entity_views( view_type => 'HostSystem',
                                              begin_entity => $dc_view,
                                            );
    info_msg( "Finding all ESX Hosts..." );
    for my $host (@$host_views){
        # Check whether the host is in one of the allowed clusters
        my $cluster_int = $host->parent->value;
        my $found = 0;
        for( @$clusters ){
            if( /$cluster_map->{$cluster_int}/ ){
                $found = 1;
                next;
            }
        }
        next if not $found;

        # Gather host details
        debug_msg( "\tFound ".$host->name.": ".join( " - ", "Free GB: ".($host->summary->hardware->memorySize/1024/1024/1024 - $host->summary->quickStats->overallMemoryUsage/1024), 
                                                 "Maint Mode: ".$host->runtime->inMaintenanceMode 
                                        ) );
        $hosts->{$host->name}{free_gb} = $host->summary->hardware->memorySize/1024/1024/1024 - $host->summary->quickStats->overallMemoryUsage/1024 if $host->runtime->inMaintenanceMode == 0;
        $hosts->{$host->name}{cluster} = $cluster_map->{$host->parent->value};
        my @networks = $host->network;
        debug_msg( "\tdatastores visible on ".$host->name.":" );
        for my $mnt ( @{$host->config->fileSystemVolume->mountInfo} ){
            debug_msg( "\t\t".join( " - ", $mnt->volume->name, 
                                  $mnt->mountInfo->path, 
                                  $mnt->volume->type, 
                                  $mnt->volume->capacity/1024/1024/1024 . " GB" 
                         ) ) if $mnt->volume->type !~ /OTHER/i; 
            $hosts->{$host->name}{datastores}{$mnt->volume->name} = { path => $mnt->mountInfo->path, 
                                                                      type => $mnt->volume->type,
                                                                      free_gb => $datastores->{$mnt->volume->name}{free_gb},
                                                                      total_gb => $datastores->{$mnt->volume->name}{total_gb},
                                                                    } if $mnt->volume->type !~ /OTHER/i and
                                                                         $mnt->volume->name !~ qr/$ds_bl/ and
                                                                         $host->runtime->inMaintenanceMode == 0;
        }
    }
    #say Dump( $hosts );
    fatal_err("No hosts were found in the allowed clusters") if (keys %$hosts) == 0;

    # Find the host with the most memory free
    my @sorted_keys = sort { $hosts->{$a}{free_gb} <=> $hosts->{$b}{free_gb} }  keys %$hosts;
    my $most_free_mem_host = pop @sorted_keys;
    info_msg( "'".var($most_free_mem_host)."' has the most free memory (".var($hosts->{$most_free_mem_host}{free_gb})." GBs)" );
    
    # Find the allowed datastore on this host with the most free space
    for my $key (sort keys %{$hosts->{$most_free_mem_host}{datastores}}) {
        if (not exists $hosts->{$most_free_mem_host}{datastores}{$key}{free_gb}) {
            #print "$key does not have a VAL\n";
            $hosts->{$most_free_mem_host}{datastores}{$key}{free_gb} = 0;
        } elsif (not defined $hosts->{$most_free_mem_host}{datastores}{$key}{free_gb}) {
            #print "$key's VAL is undefined"
            $hosts->{$most_free_mem_host}{datastores}{$key}{free_gb} = 0;
        }
    }
    my @sorted_keys2 = sort { $hosts->{$most_free_mem_host}{datastores}{$a}{free_gb} <=> $hosts->{$most_free_mem_host}{datastores}{$b}{free_gb} }  keys %{$hosts->{$most_free_mem_host}{datastores}};
    my $most_free_disk_ds = pop @sorted_keys2;
    info_msg( "'".var($most_free_disk_ds)."' has the most free disk space (".var($hosts->{$most_free_mem_host}{datastores}{$most_free_disk_ds}{free_gb})." GBs)" );
    
    return( $most_free_mem_host, $most_free_disk_ds );

}

sub get_cluster_map {
    my $vim = shift;
    my $dc_view = shift;

    my $clusters = {};

    my $cl_views = $vim->find_entity_views( view_type => 'ClusterComputeResource',
                                            begin_entity => $dc_view,
                                          );
    debug_msg( "Finding all specified Clusters..." );
    for my $cl (@$cl_views){
        $Data::Dumper::Maxdepth = 2;       # no deeper than 3 refs down
        #say Dumper( $cl );
        debug_msg( "Found ".$cl->name );
        $clusters->{$cl->{'mo_ref'}->value} = $cl->name;
    }

    return $clusters;
}

sub find_dc_net {
    my $ip = shift;
    #say $ip;
    debug_msg( "Finding Datacentre and VM Network from the IP Address (".var($ip).")...");
    my( $ip1, $ip2, $ip3, $ip4 ) = ("","","","");
    ( $ip1, $ip2, $ip3, $ip4 ) = split /\./, $ip if $ip =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/;

    my $new_net_list = LoadFile( $ip_lookup_data );
    #say Dump( $new_net_list );

    #say Dump( $new_net_list->{$ip1}{$ip2}{$ip3} );
    if( not defined($new_net_list->{$ip1}{$ip2}{$ip3}{vmnet}) ){
        fatal_err("The specified IP address ($ip) not does map to a VMware Network" );
    }
    if( not defined($new_net_list->{$ip1}{$ip2}{$ip3}{dc}) ){
        fatal_err("The specified IP address (".var($ip).") not does map to a DataCentre" );
    }
    my( $datacenter, $network ) = ( $new_net_list->{$ip1}{$ip2}{$ip3}{dc}, $new_net_list->{$ip1}{$ip2}{$ip3}{vmnet} );
    debug_msg( "Datacentre: ".var($datacenter).", VM Network: ".var($network));
    return( $datacenter, $network );
}

sub run_cmd_on_vm {
    my $vim = shift;
    my $vm = shift;
    my $cmd = shift;
    my $args = shift;
    my $guestusername = shift;
    my $guestpassword = shift;
    my $quiet = shift;

    info_msg( "Running command (".var($cmd." ".$args).") on ".var($vm->name) ) if not $quiet;

    ensure_vm_on( $vm );

    my $wd = "/tmp";

    #my( $guestCreds, $guestOpMgr ) = &acquireGuestAuth($vim, $vm, $guestusername, $guestpassword);
    my $ans = &acquireGuestAuth($vim, $vm, $guestusername, $guestpassword);
    return { success => 0, 
             details => "Could not validate the guest credentials in " . var($vm->name) 
           } if( not $ans->{success} );
    my( $guestCreds, $guestOpMgr ) = ( $ans->{guest_auth}, $ans->{guest_op_mgr} );
    my $procMgr =$vim->get_view(mo_ref => $guestOpMgr->processManager);

    eval {
        my $progStartSpec = GuestProgramSpec->new(programPath => $cmd, arguments => $args, workingDirectory => $wd);
        my $pid = $procMgr->StartProgramInGuest(vm => $vm, auth => $guestCreds, spec => $progStartSpec);
        info_msg("Program started with the following PID: " . var($pid)) if not $quiet;
    };
    info_msg( "Please Note: It is not possible to determine whether the command completed correctly" ) if not $quiet;
    return { success => 0, details => $@ } if $@;
    return { success => 1 };
}

sub ensure_vm_off {
    my $vm = shift;
    $vm->update_view_data();
    if( $vm->runtime->powerState->val eq "poweredOn" ){
        info_msg( "Powering Off ".var($vm->name)." as it was on and we need it stopped" );
        $vm->PowerOffVM();
        fatal_err( "Could not power off VM!  Details:\n\n".$@ ) if $@; 
    }
}

sub ensure_vm_on {
    my $vm = shift;
    $vm->update_view_data();
    if( $vm->runtime->powerState->val eq "poweredOff" ){
        info_msg( "Powering On ".var($vm->name)." as it was off and we need it running" );
        $vm->PowerOnVM();
        fatal_err( "Could not power on VM!  Details\n\n".$@ ) if $@; 
    }
}

sub acquireGuestAuth {
    my $vim = shift;
    my ($vmview,$gu,$gp) = @_;
    my $success = 0;
    
    my $guest_op_mgr = $vim->get_view(mo_ref => $vim->get_service_content()->guestOperationsManager);
    my $authMgr = $vim->get_view(mo_ref => $guest_op_mgr->authManager);
    my $guest_auth = NamePasswordAuthentication->new(username => $gu, password => $gp, interactiveSession => 'false');

    debug_msg("Validating guest credentials in " . var($vmview->name) . " ...");
    eval {
        $authMgr->ValidateCredentialsInGuest(vm => $vmview, auth => $guest_auth);
    };
    if($@) {
        #fatal_err( "Could not validate the guest credentials in " . var($vmview->name));
    } else {
        debug_msg("Succesfully validated guest credentials.");
        $success = 1;
    }

    return { success => $success, guest_auth => $guest_auth, guest_op_mgr => $guest_op_mgr };
}

sub try_cmd {
    my $func = shift;
    $ignore_exit  = 1;
    eval { $func->() };
    return $@;
    $ignore_exit  = 0;
}

sub get_dc_view {
    #say "Showing details";
    my $vim = shift;
    my $datacenter = shift;
    my $datacenter_view = $vim->find_entity_view( view_type => 'Datacenter', 
                                                  filter => { name => $datacenter },
                                                );
    if (!$datacenter_view) {
       fatal_err( "Datacenter '" . var($datacenter) . "' not found" );
    }
    return $datacenter_view;
}


