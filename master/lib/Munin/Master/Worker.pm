package Munin::Master::Worker;

# $Id$

use warnings;
use strict;

use Scalar::Util qw(refaddr);


use overload q{""} => 'to_string';


sub new {
    my ($class, $identity) = @_;

    my $self = bless {}, $class;

    $identity = refaddr($self) unless defined $identity;
    $self->{ID} = $identity;

    return $self;
}


sub to_string {
    my ($self) = @_;

    return sprintf("%s<%s>", ref $self, $self->{ID}); 
}


1;


__END__

=head1 NAME

Munin::Master::Worker - Abstract base class for workers.

=head1 SYNOPSIS

See L<Munin::Master::ProcessManager>.

=head1 METHODS

=over

=item B<new>

FIX

=item B<to_string>

FIX
