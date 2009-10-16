package Munin::Master::Config;

use base qw(Munin::Common::Config);

# $Id$

# Notes about config data structure:
# 
# In munin all configuration and gathered data is stored in the same
# config tree of hashes.  Since ~april 2009 we've made the tree object
# oriented so the objects in three must be instanciated as the right
# object type.  And so we can use the object type to determine
# behaviour when we itterate over the objects in the tree.
#
# The Class Munin::Common::Config is the base of Munin::Master::Config.
# The master programs (munin-update, munin-graph, munin-html) instanciates
# a Munin::Master::Config object.
#
# Please note that the munin-node configuration is also based on
# Munin::Common::Config but is quite a lot simpler with regards to syntax
#
# The Class Munin::Master::GroupRepository is based on Munin::Master::Config
# and contains a tree of Munin::Master::Group objects.
#
# The M::M::Group objects can be nested.  Under a M::M::Group object there
# can be a (flat) collection of M::M::Host objects.  The M::M::Host class
# is based in M::M::Group.
#
# A M::M::Host is a monitored host (not a node).  Munin gathers data
# about a host by connecting to a munin-node and asking about the host.
#
# Since multigraph plugins are hierarchical each host can contain
# data for nested plugin names/dataseries labels.
#
# The configuration file formats are everywhere identical in structure
# but the resulting configuration tree differs a bit.  On the munin-master
# the syntax is like this:
#
# Global setting:
#
#   attribute value
#
# Simple group/host/service tree:
#
#   Group;Host:service.attribute
#   Group;Host:service.label.attribute
#
# Groups can be nested:
#
#   Group;Group;Group;Host:(...)
#
# (When multigraph is supported) services can be nested:
#
#   (...);Host:service:service.(...)
#   (...);Host:service:service.service.(...)
#
# All attributes (attribute names) are known and appears in the @legal
# array (and accompanying hash).
# 
# Structure:
# - A group name is always postfixed by a ;
# - The host name is the first word with a : after it
# - After that there are services and attributes
#
# For ease of configuration munin supports a [section] shorthand:
#
#   [Group;]
#   [Group;Group;]
#   [Group;Host]
#   [Group;Host:service]
#
# The section is prefixed to the subsequent settings in the appropriate
# manner with the correct infixes (";", ":" or ".").  Usage can look like
# this:
#
#   [Group;]
#      Group;Host:service.attribute value
#
# is equivalent to
#
#   [Group;Group;]
#      Host:service.attribute value
#
# is equivalent to
#
#   [Group;Group;Host]
#      service.attribute value
#
# is equivalent to
#
#   [Group;Group;Host:service]
#      attribute value
#
# As part of multigraph we're supporting nested services as well:
#
#   [Group;Group;Host]
#      service.attribute value
#      service.service.attribute value
#
#   [Group;Group;Host:service]
#      attribute value             # Group;Group;Host:service.attribute
#      :service.attribute value    # Group;Group;Host:service.service.attribute
#
#   [Group;Group;Host:service.service]
#      attribute value             # Group;Group;Host:service.service.attribute
#      service.attribute value    # ...;Host:service:service.service.attribute
#

use warnings;
use strict;

use Carp;
use English qw(-no_match_vars);
use Munin::Common::Defaults;
use Munin::Master::Group;
use Munin::Master::Host;

my $MAXINT = 2 ** 53;

my %booleans = map {$_ => 1} qw(
    debug
    fork
    tls_verify_certificate
    update
    use_node_name
);


{
    my $instance;

    sub instance {
        my ($class) = @_;
        
        $instance ||= bless {
            config_file            => "$Munin::Common::Defaults::MUNIN_CONFDIR/munin.conf",
            dbdir                  => $Munin::Common::Defaults::MUNIN_DBDIR,
            debug                  => 0,
            fork                   => 1,
            graph_data_size        => 'normal',
            groups_and_hosts       => {},
            local_address          => 0,
            logdir                 => $Munin::Common::Defaults::MUNIN_LOGDIR,
            max_processes          => $MAXINT,
            rundir                 => '/tmp',
            timeout                => 180,
            tls                    => 'disabled',
            tls_ca_certificate     => "Munin::Common::Defaults::MUNIN_CONFDIR/cacert.pem",
            tls_certificate        => "$Munin::Common::Defaults::MUNIN_CONFDIR/munin.pem",
            tls_private_key        => "$Munin::Common::Defaults::MUNIN_CONFDIR/munin.pem",
            tls_verify_certificate => 0,
            tls_verify_depth       => 5,
            tmpldir                => "$Munin::Common::Defaults::MUNIN_CONFDIR/templates",
        }, $class;

	# This object will over time aquire "service_configs" and
	# "old_service_configs"

	# These are made with calls to
	#  $self->parse_config_from_file (M::C::Config)
        
        return $instance;
    }
}


sub _final_char_is {
    # Not a object method.
    my ($char, $str) = @_;
 	
    return rindex($str, $char) == ( length($str) - 1 );
}


sub _create_and_set {
    my ($self,$groups,$host,$rest,$value) = @_;
    # Nested creation of group and host class objects, and then set
    # attribute value.

    my $groupref = $self;

    my @rest = split(/\./, $rest);
    my $last_word = pop @rest;

    if ($booleans{$last_word}) {
	$value = $self->_parse_bool($value);
    }

    if ($#{$groups} == -1 and !$host) {
	$self->{$rest} = $value;
	return;
    }

    foreach my $group (@{$groups}) {
	# Create nested group objects
	$groupref->{groups}{$group} ||= Munin::Master::Group->new($group);
	if ($groupref eq $self) {
	    $groupref->{groups}{$group}{group}=undef;
	} else {
	    $groupref->{groups}{$group}{group}=$groupref;
	}
	$groupref = $groupref->{groups}{$group};
    }
    
    if ($host) {
	if (! defined ( $groupref->{hosts}{$host} ) ) {
	    $groupref->{hosts}{$host} =
		Munin::Master::Host->new($host,$groupref,{ $rest => $value });
	} else {
	    $groupref->{hosts}{$host}->add_attributes_if_not_exists({ $rest => $value } );
	}
    } else {
	# Implant key/value into group
	$groupref->{$rest} = $value;
    }
    
    # 
}

sub set_value {
    # Set value in config hash, $key is full ;:. separated value.
    my ($self, $longkey, $value) = @_;

    my ($groups,$host,$key) = $self->_split_config_line($longkey);

    $self->_create_and_set($groups,$host,$key,$value);
}


sub _extract_group_name_from_definition {
    # Extract the group name from any munin.conf section name
    #
    # This a object method for the sake of finding it with the help of
    # a object of the right kind.

    # Cases:
    # * foo.example.com      ->  example.com
    # * bar;foo.example.com  ->  bar
    # * foo                  ->  foo
    # * bar;foo              ->  bar
    # * bar;		     ->  bar
    #
    # More cases:
    # * bar;foo.example.com:service

    my ($self, $definition) = @_;

    my $dot_loc = index($definition, '.');
    my $sc_loc = index($definition, ';');

    # Return bare hostname
    return $definition if $sc_loc == -1 and $dot_loc == -1;
    
    # Return explicit group name
    return substr($definition, 0, $sc_loc)
	if $sc_loc > -1 and ($dot_loc == -1 or $sc_loc < $dot_loc);

    # Return domain name as group name
    return substr($definition, $dot_loc + 1);
}
sub _concat_config_line {
    # Canonify and concatenate current prefix and and the config line
    # we're parsing now in a correct manner.

    # See also _split_config_line.

    # No sanity checking in this procedure.  Use _concat_config_line_ok to
    # get sanity/syntax checking.

    my ($self, $prefix, $key, $value) = @_;

    my $longkey;

    # Allowed constructs:
    # [group;host]
    #     port 4949
    #
    # This is shorthand for [domain;host.domain]:
    #   [host.domanin]
    #     port 4949
    # 
    # [group;]
    # [group;host]
    # [group;host:service]
    # [group;host:service.field]
    # [group1;group2;host:service.field]
    #    keyword value
    #    field.keyword value (only if no service in prefix)
    #    group_order ....
    #
    # And more recently this for nested services (multigraph).
    # [group1;group2;host:service:service...]
    #     :service.field.keyword value
    #
    # Rules:
    # - Last ';' terminates group part
    # - Last ':' terminates the host part
    # - The rest is a collection of services and time series data
    #   - which we collect under the host name in the data-structure.

    # Note that keywords can come directly after group names in the
    # concatenated syntax: group;group_order ...

    if ($prefix eq '') {
	# If the prefix is empty then the key had better be well formed and
	# complete, because we'll use it without further checking.
	return $key;
    }

    if (index($prefix,';') == -1) {
	# Handle shorthand: Group name is given by host name
	my $group = $self->_extract_group_name_from_definition($prefix);
	$prefix = "$group;$prefix";
    }

    if (_final_char_is(';',$prefix)) {
	# Prefix ended in the middle of a group.  The rest can be
	# appended.
	$longkey = $prefix.$key;
    } elsif (index($prefix,':') != -1) {
	# Host name ends explicitly in the prefix. Use "." everywhere after :
	# Key is a nested service name
	$longkey = $prefix.'.'.$key;
    } else {
	# Prefix ends in host name but ":" is missing.
	$longkey = $prefix.':'.$key;
    }

    return $longkey;
}


sub _concat_config_line_ok {
    # Concatenate config line and do some extra syntaxy checks
    #
    # If the arrived at config line is not legal as far as we can tell
    # then croak here.

    my ($self, $prefix, $key, $value) = @_;

    if (!defined($key) or !$key) {
	croak "Somehow we're missing the keyword sometime after section [$prefix]";
    }

    my $longkey = $self->_concat_config_line($prefix,$key,$value);
       
    my @words = split (/[;:.]/, $longkey);
    my $last_word = pop(@words);

    if (! $self->is_keyword($last_word)) {
	croak "Parse error in ".$self->{config_file}." in section [$prefix]:\n".
	    " Unknown keyword at end of left hand side of line ($key $value)\n";
    }
    return $longkey;
}


sub _split_config_line {
    # After going to all that trouble with putting a "longkey" together
    # we now persue splitting the key in a nice and accurate manner.
    #
    # See also _concat_config_line

    my ($self,$line) = @_;

    my $groups;
    my $host;
    my $key;

    # Cases to keep in mind
    #   htmldir
    #   Group;address
    #   Group;Group;address
    #   Group;Host:address
    #   Group;Host:if_eth0.in.value
    #   Group;Host:snmp_foo_if_input.snmp_foo_if_input_0.value

    my $sc = index($line,';');

    if ($sc == -1) {
	$groups='';
    } else {
	# Note that .+ is greedy so $groups is the whole groups grouping
	$line =~ /(.+);(.*)/;  
	($groups, $line) = ($1, $2);
    }

    # Now left with (1:1 with cases above)
    #   address
    #   address
    #   Host:address
    #   Host:if_eth0.in.value
    #   Host:snmp_foo_if_input.snmp_foo_if_input_0.value

    my $cc = index($line,':');

    if ($cc == -1) {
	# No host delimiter: the rest is a setting
	$host = '';
	$key = $line;
    } else {
	# Can see host delimiter.  Copy it and the rest is a setting.
	$host = substr($line,0,$cc);
	substr($line,0,$cc+1) = '';
	$key = $line;
    }
    
    return ([split(';',$groups)],$host,$key);
}


sub _split_config_line_ok {
    # Split config line and do some extra syntaxy checks
    #
    # If all is not well we'll corak here.

    my ($self,$longkey,$value) = @_;

    my ($groups,$host,$key) = $self->_split_config_line($longkey);

    my @words = split (/[.]/, $key);
    my $last_word = pop(@words);

    if (! $self->is_keyword($last_word)) {
	croak "Parse error in ".$self->{config_file}." for $key:\n".
	    " Unknown keyword at end of left hand side of line ($key $value)\n";
    }

    retrun ($groups,$host,$key);
}


sub _parse_config_line {
    my ($self, $prefix, $key, $value) = @_;
    
    my $longkey = $self->_concat_config_line($prefix,$key,$value);

    $self->set_value($longkey,$value);
}

sub parse_config {
    my ($self, $io) = @_;
        
    my $section = undef;

    my $prefix = '';

    while (my $line = <$io>) {
        $self->_strip_comment($line);
        $self->_trim($line);
        if ( !length($line) ) {
	    next;
	}
        
	# Group/host/service configuration is saved for later persual.
	# Everything else is saved at once.  Note that _trim removes
	# leading whitespace so section changes can only happen if a new
	# [foo] comes along.

        if ($line =~ m{\A \[ ([^]]+) \] \s* \z}xms) {
	    $prefix = $1;
	} else {
	    my($key,$value) = split(/\s+/,$line,2);
	    $self->_parse_config_line($prefix,$key,$value);
        }
    }
}


sub get_groups_and_hosts {
    my ($self) = @_;
    
    return %{$self->{groups_and_hosts}};
}


sub set {
    my ($self, $config) = @_;
    
    %$self = (%$self, %$config); 
}


sub _read_old_service_configs {
    my ($self) = @_;

    return {} unless -e $self->{config_dump_file};

    open my $dump, '<', $self->{config_dump_file}
        or croak "Fatal error: Could not open '$self->{config_dump_file}' for reading: $!";

    my %service_configs = $self->_parse_service_config_dump($dump);

    close $dump
        or croak "Fatal error: Could not close '$self->{config_dump_file}': $!";

    #use Data::Dumper; warn Dumper(\%service_configs);

    return \%service_configs;
    
}


sub _parse_service_config_dump {
    my ($self, $io) = @_;

    my %service_configs = ();

    my $version = <$io>;
    chop $version;
    $self->{old_version} =  substr $version, length('version ');

    while (my $line = <$io>) {
        chop $line;

        my ($key, $value) = split(/ /, $line);

	my ($grouphost,$ss) = split(/:/, $key);

	my ($service,@rest) = split(/\./, $ss);

	my @key_components = split(/;/, $grouphost);

	my $host = pop(@key_components);

        if (@key_components == 1 || @key_components == 3) {
            # Ignore. These are configuration variables from
            # $CONF_DIR/munin.conf. We only care about service
            # configuration.
            next;
        }
        
        my $group = join(';', @key_components);

        $host = "$group;$host";

        #use Data::Dumper; warn Dumper([$host, $value, \@attribute]);

        $service_configs{$host} ||= {};

	if (defined($service)) {
	    $service_configs{$host}{$service} ||= 
	    {global => [], data_source => {}};

	    if (@rest == 2) {
		$service_configs{$host}{$service}{data_source}{$rest[0]} ||= {};
		$service_configs{$host}{$service}{data_source}{$rest[0]}{$rest[1]} = $value;
	    } else {
		push @{$service_configs{$host}{$service}{global}}, [@rest, $value];
	    }
        } # Don't we need a else here?
    }

    return %service_configs;
}


1;


__END__

=head1 NAME

Munin::Master::Config - Holds the master configuration.

=head1 SYNOPSIS

FIX

=head1 METHODS

=over

=item B<instance>

FIX

=item B<parse_config>

FIX

=item B<set>

FIX

=item B<get_groups_and_hosts>

FIX

=back
