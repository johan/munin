package Munin::Node::Configure::PluginList;

use strict;
use warnings;

use File::Basename qw(fileparse);

use Munin::Node::Service;
use Munin::Node::Configure::Plugin;

use Munin::Node::Config;
my $config = Munin::Node::Config->instance();


sub new
{
    my ($class, %opts) = @_;

    my $libdir     = delete $opts{libdir} or die "Must specify the directory\n";
    my $servicedir = delete $opts{servicedir} or die "Must specify the service directory\n";

    my %plugin = (
        libdir     => $libdir,
        servicedir => $servicedir,

        %opts,
    );

    return bless \%plugin, $class;
}


### Plugin and service enumeration #############################################

sub load
{
    my ($self, @families) = @_;
    $self->_load_available(@families);
    $self->_load_installed();
    return;
}


sub _load_available
{
    my ($self, @families) = @_;
    my %found;

    my %valid_plugins = main::load_plugin_history($config->{newer}) if $config->{newer};

    DEBUG("Searching '$self->{libdir}' for available plugins.");

    foreach my $item (_valid_files($self->{libdir})) {
        my $path = $item->{path};
        my $plug = $item->{name};

        DEBUG("Considering '$path'");

        # FIXME: should there ever be symlinks in here?  do we even need
        # care unless we're going to try running it?
        while (-l $path) {
            $path = readlink($path);
            $path = ($path =~ /^\//) ? $path : "$self->{libdir}/$path";
        }

        my $plugin = Munin::Node::Configure::Plugin->new(name => $plug, path => $path);

        $plugin->read_magic_markers();

        unless ($plugin->in_family(@families)) {
            DEBUG("\tFamily '$plugin->{family}' is currently ignored.  Skipping.");
            next;
        }

        if (($plugin->{family} eq "auto")
            and $config->{newer}
            and not $valid_plugins{$plug})
        {
            DEBUG("\tPlugin is older than $config->{newer}.  Skipping.");
            next;
        }

        $found{$plug} = $plugin;
    }

    $self->{plugins} = \%found;
    DEBUG(sprintf "%u plugins available.", scalar keys %found);
    return;
}


sub _load_installed
{
    my ($self) = @_;
    my $service_count = 0;  # the number of services currently installed.

    DEBUG("Searching '$self->{servicedir}' for installed plugins.");

    foreach my $item (_valid_files($self->{servicedir})) {
        my $path    = $item->{path};
        my $service = $item->{name};

        my $realfile;
        # Ignore non-symlinks, and symlinks that point anywhere other
        # than the plugin library
        next unless -l $path;
        unless ($realfile = readlink($path)) {
            # FIXME: should be a given, since it's tested by is_a_runnable_service()
            DEBUG("Warning: symlink '$path' is broken.");
            next;
        }
        next unless ($realfile =~ /^$self->{libdir}\//);

        DEBUG("Found '$service'");

        $realfile = fileparse($realfile);
        unless ($self->{plugins}{$realfile}) {
            DEBUG("\tCorresponds to an ignored plugin ($realfile).  Skipping.");
            next;
        }

        $self->{plugins}{$realfile}->add_instance($service);
        $service_count++;
    }

    DEBUG("$service_count services currently installed.");
    return;
}


# returns the list of plugins, sorted alphabetically by name
sub list
{
    my ($self) = @_;
    my @plugins;
    foreach my $plug (sort keys %{$self->{plugins}}) {
        push @plugins, $self->{plugins}{$plug};
    }
    return @plugins;
}



sub _valid_files
{
    my ($directory) = @_;
    my @items;

    opendir (my $DIR, $directory)
        or die "Fatal: Could not open '$directory' for reading: $!\n";

    while (my $item = readdir $DIR) {
        my $path = "$directory/$item";
        unless (Munin::Node::Service->is_a_runnable_service($item, $directory)) {
            DEBUG("Ignoring '$path'.");
            next;
        }
        push @items, { path => $path, name => $item };
    }
    closedir $DIR;
    return @items;
}


sub DEBUG { print '# ', @_, "\n" if $config->{DEBUG}; }


1;
# vim: sw=4 : ts=4 : expandtab
