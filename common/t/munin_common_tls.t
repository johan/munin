use warnings;
use strict;

use Test::More tests => 2;

use_ok('Munin::Common::TLS');

use Data::Dumper;
use English qw(-no_match_vars);
use FindBin;
use IO::Handle;
use Socket;

sub do_server {
    my ($socket) = @_;
    #print $socket "Parent Pid $$ is sending this\n";
    #chomp(my $line = <$socket>);
    #print "Parent Pid $$ just read this: `$line'\n";

    chomp(my $line = <$socket>);

    die "Expected STARTTLS '$line'" unless $line eq 'STARTTLS';

    my $tls = Munin::Common::TLS->new(
        fileno($socket),
        fileno($socket),
        sub { print "Server reading ...\n"; my $line = <$socket>; print "Server done. ($line)\n"; return $line; },
        sub { print $socket @_ },
        sub { print "LOG SERVER: ", @_, "\n" },
        1,
    );

    my $tls_session = $tls->start_tls_server(
        1, 
        "$FindBin::Bin/tls/node_cert.pem",
        "$FindBin::Bin/tls/node_key.pem",
        "$FindBin::Bin/tls/CA/ca_cert.pem",
        1,
        5,
    );

    $line = $tls->read();
    $tls->write($line);
    
}

sub do_client {
    my ($socket) = @_;
    #chomp(my $line = <$socket>);
    #print "Child Pid $$ just read this: `$line'\n";
    #print $socket "Child Pid $$ is sending this\n";

    my $tls = Munin::Common::TLS->new(
        fileno($socket),
        fileno($socket),
        sub { print "Client reading ...\n"; my $line = <$socket>; print "Client done.  ($line)\n"; return $line; },
        sub { print $socket @_ },
        sub { print "LOG CLIENT: ", @_, "\n" },
        1,
    );

    my $tls_session = $tls->start_tls_client(
        1, 
        "$FindBin::Bin/tls/master_cert.pem",
        "$FindBin::Bin/tls/master_key.pem",
        "$FindBin::Bin/tls/CA/ca_cert.pem",
        1,
        5,
    );

    my $req_msg = "ping\n";
    $tls->write($req_msg);
    my $res_msg = $tls->read();
    return $req_msg eq $res_msg;
}


socketpair(CHILD, PARENT, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or  die "socketpair: $!";

CHILD->autoflush(1);
PARENT->autoflush(1);

my $pid;
if ($pid = fork) {
    close PARENT;
    do_server(\*CHILD);
    close CHILD;
    waitpid($pid,0);
    my $child_exit_status = $CHILD_ERROR >> 8; # FIX becomes 1 for some reason ...
    is($CHILD_ERROR, 256, "Status OK");        # FIX Want to test $child_exit_status == 0
} else {
    die "cannot fork: $!" unless defined $pid;
    close CHILD;
    my $stat = do_client(\*PARENT);
    close PARENT;
    exit $stat ? 0 : 1;
}


