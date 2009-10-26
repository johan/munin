package Munin::Node::Configure::Plugin;

# $Id$

use strict;
use warnings;

use Munin::Node::Configure::Debug;


sub new
{
    my ($class, %opts) = @_;

    my $name = delete $opts{name} or die "Must provide name\n";
    my $path = delete $opts{path} or die "Must provide path\n";

    my %plugin = (
        name         => $name,      # the (base)name of the plugin
        path         => $path,      # the full path to the plugin
        default      => 'no',       # whether this plugin thinks it should be installed
        installed    => [],         # list of installed services (as link names)
        suggestions  => [],         # list of suggestions (as wildcards)
        family       => 'contrib',  # the family it belongs to
        capabilities => {},         # what capabilities it supports
        errors       => [],         # list of errors reported against this plugin

        %opts,
    );

    return bless \%plugin, $class;
}


################################################################################

sub is_wildcard { return ((shift)->{path} =~ /_$/); }


sub in_family { $_[0]->{family} eq $_  && return 1 foreach @_; return 0; }


sub is_installed { return @{(shift)->{installed}} ? 'yes' : 'no'; }


# report which services (link or wildcard) should be added, removed,
# or left as they are.
#   (remove) = (installed) \ (suggested)
#   (add)    = (suggested) \ (installed)
#   (same)   = (installed) ⋂ (suggested)
sub _remove { _set_difference(@_); }
sub _add    { _set_difference(reverse @_); }
sub _same   { _set_intersection(@_); }


sub suggestion_string
{
    my ($self) = @_;
    my $msg = '';

    if ($self->{default} eq 'yes') {
        my @suggestions = _same($self->_installed_wild, $self->_suggested_wild);
        push @suggestions,
            map { "+$_" } _add($self->_installed_wild, $self->_suggested_wild);
        push @suggestions,
            map { "-$_" } _remove($self->_installed_wild, $self->_suggested_wild);

        $msg = ' (' . join(' ', @suggestions) . ')' if @suggestions;
    }
    elsif ($self->{defaultreason}) {
        # Report why it's not being used
        $msg = " [$self->{defaultreason}]";
    }

    return $self->{default} . $msg;
}


sub installed_services_string { return join ' ', @{(shift)->_installed_wild}; }


### Service name <-> wildcard conversion ###############################################
# NOTE that these functions do not round-trip!

# Extracts the wildcards from a service name and formats them in a user-friendly way.
sub _reduce_wildcard
{
    my ($self, $link_name) = @_;
    my $name = $self->{name};
    my $wild;

    if ($name =~ /^snmp_(_\w+)/) {
        $link_name =~ /^snmp_(.+)$1(.*)/;
        $wild = $1 . (length($2)? "/$2" : '');  # FIXME hack :-(
    }
    else {
        ($wild = $link_name) =~ s/^$name//;
    }
    return length($wild)? $wild : ();  # FIXME more hack
}


# converts a wildcard to the appropriate service name
sub _expand_wildcard
{
    my ($self, $suggestion) = @_;

    if ($self->{name} =~ /^snmp__(\w+)/) {
        my ($host, $wild) = @$suggestion;
        $wild ||= '';
        return 'snmp_' . $host . '_' . $1 . $wild;
    }
    else {
        return $self->{name} . $suggestion;
    }
}


# Converts a wildcard into a human-readable form
sub _flatten_wildcard { return ref($_[0]) ? join('/', @{$_[0]}) : $_[0]; }


################################################################################

# return an arrayref of the installed and suggested service names (eg. 'memory'
# or 'if_eth0')
sub _installed_links { return (shift)->{installed}; }

sub _suggested_links
{
    my ($self) = @_;
    if ($self->{default} eq 'yes' and not $self->is_wildcard) {
        return [ $self->{name} ];
    }
    else {
        return [ map { $self->_expand_wildcard($_) } @{$self->{suggestions}} ];
    }
}


# return an arrayref of the installed or suggested wildcards (eg. 'eth0' or
# 'switch.example.com/1').  nothing is returned if the plugin contains no wildcards.
sub _installed_wild { return [ map { $_[0]->_reduce_wildcard($_) } @{$_[0]->{installed}} ]; }
sub _suggested_wild { return [ map { _flatten_wildcard($_) } @{(shift)->{suggestions}}]; }


sub services_to_add
{
    my ($self) = @_;
    return _add($self->_installed_links, $self->_suggested_links);
}


sub services_to_remove
{
    my ($self) = @_;
    return _remove($self->_installed_links, $self->_suggested_links);
}


sub add_instance { push @{(shift)->{installed}}, shift; }


sub add_suggestions { push @{(shift)->{suggestions}}, @_; }


sub read_magic_markers
{
    my ($self) = @_;
    my $PLUGIN;

    DEBUG("\tReading magic markers.");

    unless (open ($PLUGIN, '<', $self->{path})) {
        DEBUG("Could not open plugin '$self->{path}' for reading: $!");
        return;
    }

    while (<$PLUGIN>) {
        if (/#%#\s+family\s*=\s*(\S+)\s*/) {
            $self->{family} = $1;
            DEBUG("\tSet family to '$1'." );
        }
        elsif (/#%#\s+capabilities\s*=\s*(.+)/) {
            my @caps = split(/\s+/, $1);
            @{$self->{capabilities}}{@caps} = (1) x scalar @caps;
            DEBUG("\tCapabilities are: $1");
        }
    }
    close ($PLUGIN);

    # Some sanity-checks
    $self->log_error(q{In family 'auto' but doesn't have 'autoconf' capability})
        if ($self->{family} eq 'auto' and not $self->{capabilities}{autoconf});

    $self->log_error(q{In family 'auto' but doesn't have 'autoconf' capability})
        if ($self->{family} eq 'snmpauto' and not $self->{capabilities}{snmpconf});

    $self->log_error(q{Has 'suggest' capability, but isn't a wildcard plugin})
        if ($self->{capabilities}{suggest} and not $self->is_wildcard);

    return;
}


### Parsing plugin responses ###################################################

sub parse_autoconf_response
{
    my ($self, @response) = @_;

    unless (scalar(@response) == 1) {
        # FIXME: not a good message
        $self->log_error('Wrong amount of autoconf');
        return;
    }

    my $line = shift @response;

    unless ($line =~ /^(yes)$/
         or $line =~ /^(no)(?:\s+\((.*)\))?\s*$/)
    {
        $self->log_error("Junk printed to stdout");
        return;
    }

    DEBUG("\tGot yes/no: $line");
    $self->{default} = $1;
    $self->{defaultreason} = $2;

    return;
}


sub parse_suggest_response
{
    my ($self, @suggested) = @_;

    foreach my $line (@suggested) {
        if ($line =~ /^[-\w.:]+$/) {
            DEBUG("\tAdded suggestion: $line");
            $self->add_suggestions($line);
        }
        else {
            $self->log_error("\tBad suggestion: $line");
        }
    }

    unless (@{ $self->{suggestions} }) {
        $self->log_error("No valid suggestions");
        return;
    }

    return;
}


my $oid_pattern      = qr/^[0-9.]+[0-9]+$/;
my $oid_root_pattern = qr/^[0-9.]+\.$/;

sub parse_snmpconf_response
{
    my ($self, @response) = @_;

    foreach my $line (@response) {
        my ($key, $value) = $line =~ /(\w+)\s+(.+\S)/;

        next unless $key and defined $value;

        DEBUG("\tAnalysing line: $line");

        if ($key eq 'require') {
            my ($oid, $regex) = split /\s+/, $value, 2;

            if ($oid =~ /$oid_root_pattern/) {
                $oid =~ s/\.$//;
                push @{ $self->{require_root} }, [$oid, $regex];

                DEBUG("\tRegistered 'require': $oid");
                DEBUG("\t\tFiltering on /$regex/") if $regex;
            }
            elsif ($oid =~ /$oid_pattern/) {
                push @{ $self->{require_oid} }, [$oid, $regex];

                DEBUG("\tRegistered 'require': $oid");
                DEBUG("\t\tFiltering on /$regex/") if $regex;
            }
            else {
                $self->log_error("Invalid format for 'require': $value");
            }
        }
        elsif ($key eq 'index') {
            if ($self->{index}) {
                $self->log_error('index redefined');
                next;
            }
            unless ($value =~ /$oid_root_pattern/) {
                $self->log_error('index must be an OID root');
                next;
            }

            ($self->{index} = $value) =~ s/\.$//;
            DEBUG("\tRegistered 'index'  : $value");
        }
        elsif ($key eq 'number') {
            if ($self->{number}) {
                $self->log_error('number redefined');
                next;
            }

            unless ($value =~ /$oid_pattern/) {
                $self->log_error('number must be an OID');
                next;
            }

            $self->{number} = $value;
            DEBUG("\tRegistered 'number' : $value");
        }
        else {
            $self->log_error("Couldn't parse line: $line");
        }
    }
}


### Debugging and error reporting ##############################################
# Logs an error due to this plugin, and prints it out if debugging is on
sub log_error
{
    my ($self, $msg) = @_;

    chomp $msg;
    push @{$self->{errors}}, $msg;
    DEBUG($msg);

    return;
}


### Set operations #############################################################

# returns the list of elements in arrayref $a that are not in arrayref $b
# NOTE this is *not* a method.
sub _set_difference
{
    my ($A, $B) = @_;
    my %set;
    @set{@$A} = ();
    delete @set{@$B};
    return sort keys %set;
}


# returns the list of elements common to arrayrefs $a and $b
# NOTE this is *not* a method.
sub _set_intersection
{
    my ($A, $B) = @_;
    my %set;
    @set{@$A} = (1) x @$A;
    return sort grep $set{$_}, @$B;
}


1;

__END__


=head1 NAME

Munin::Node::Configure::Plugin - Class representing a plugin, along with its
installed and suggested services.


=head1 SYNOPSIS

  my $plugin = Munin::Node::Configure::Plugin->new();


=head1 METHODS

=over

=item B<new(%args)>

Constructor.

Required arguments are 'name' and 'path', which should be the
basename and full path of the plugin, respectively.


=item B<is_wildcard()>

Returns true if the plugin is a wildcard.  In the case of SNMP plugins,
only double-wild plugins will return true (ie. 'snmp__memory' would
return false, but 'snmp__if_' would return true).


=item B<in_family(@families)>

Returns true if plugin's family is in @families, false otherwise.


=item B<is_installed()>

Returns 'yes' if one or more links to this plugin exist in the service
directory, 'no' otherwise.


=item B<suggestion_string()>

Returns a string detailing whether or not autoconf considers that the plugin
should be installed.  The string may also report the reason why the plugin 
declined to be installed, or the list of suggestions it provided, if this
information is available.


=item B<installed_services_string()>

Returns a string detailing which wildcards are installed for this plugin.


=item B<services_to_add()>

=item B<services_to_remove()>

Return a list of service names that should be added or removed for this
plugin.


=item B<add_instance($name)>

Associates a link from the service directory with this plugin.


=item B<add_suggestions(@suggestions)>

Adds @suggestions to the list of suggested wildcards for this plugin.  They
are not validated.


=item B<read_magic_markers()>

Sets the family and capabilities from the magic markers embedded in the plugin's
executable, as specified by
http://munin.projects.linpro.no/wiki/ConcisePlugins#Magicmarkers


=item B<parse_autoconf_response(@response)>

Parses and validates the autoconf response from the plugin, in the format
specified by http://munin.projects.linpro.no/wiki/ConcisePlugins#autoconf

Invalid input will cause an error to be logged against the plugin.


=item B<parse_suggest_response(@response)>

Validates the suggestions from the plugin.

Invalid suggestions will cause an error to be logged against the plugin.


=item B<parse_snmpconf_response(@response)>

Parses and validates the snmpconf response from the plugin, in the format
specified by http://munin.projects.linpro.no/wiki/ConcisePlugins#suggest

Invalid or inconsistent input will cause an error to be logged against the
plugin.


=item B<log_error($message)>

Logs an error for later retrieval.  The error will also be displayed if
debugging output is enabled.


=back

=cut
# vim: sw=4 : ts=4 : expandtab