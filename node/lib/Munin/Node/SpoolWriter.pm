package Munin::Node::SpoolWriter;

# $Id$

use strict;
use warnings;

use Carp;
use IO::File;

use Munin::Common::Defaults;
use Munin::Node::Logger;


sub new
{
    my ($class, %args) = @_;

    $args{spooldir} or croak "no spooldir provided";

    opendir $args{spooldirhandle}, $args{spooldir}
        or croak "Could not open spooldir '$args{spooldir}': $!";

    # TODO: paranoia check?  except dir doesn't (currently) have to be
    # root-owned.

    # TODO: set umask

    return bless \%args, $class;
}


# writes the results of a plugin run to the appropriate spool-file
# need to remove any lines containing only a '.'
sub write
{
    my ($self, $timestamp, $service, $data) = @_;

    open my $fh , '>>', "$self->{spooldir}/munin-daemon.$service.0"
        or die "Unable to open spool file: $!";

    print {$fh} "timestamp $timestamp\n";
    print {$fh} "multigraph $service\n" unless $data->[0] =~ m{^multigraph};

    foreach my $line (@$data) {
        # Ignore blank lines and "."-ones.
        next if (!defined($line) || $line eq '' || $line eq '.');

        print {$fh} $line, "\n" or logger("Error writing results: $!");
    }

    return;
}


# removes content from the spooldir older than $timestamp
# TODO - For now, SpoolReader just parses the old thing. No need to
# garbage-collect.
sub cleanup
{}


1;

__END__

=head1 NAME

Munin::Node::SpoolWriter - Writing side of the spool functionality

=head1 SYNOPSIS

  my $spool = Munin::Node::SpoolWriter->new(spooldir => $spooldir);
  $spool->write(1234567890, 'cpu', \@results);

=head1 METHODS

=over 4

=item B<new(%args)>

Constructor.  'spooldir' key should be the directory
L<Munin::Node::SpoolReader> is reading from.

=item B<write($timestamp, $service, \@results)>

Takes a timestamp, service name, and the results of running config and fetch on
it.  Writes it to the spool directory for L<Munin::Node::SpoolReader> to read.

=item B<cleanup($timestamp)>

Removes any items in the spool directory older than $timestamp.

=back

=cut

# vim: sw=4 : ts=4 : et
