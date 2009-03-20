package Munin::Node::Server;
use base qw(Net::Server::Fork);

use strict;
use warnings;

use English qw(-no_match_vars);
use Munin::Node::Config;
use Munin::Node::Defaults;
use Munin::Node::Logger;
use Munin::Node::OS;

my $tls;
my %tls_verified = ( 
    "level"          => 0,
    "cert"           => "",
    "verified"       => 0,
    "required_depth" => 5,
    "verify"         => "no"
);

my %services;
my %nodes;
my $caddr  = "";
my $config = Munin::Node::Config->instance();


sub pre_loop_hook {
    my $self = shift;
    print STDERR "In pre_loop_hook.\n" if $config->{DEBUG};
    _load_services();
    $self->SUPER::pre_loop_hook();
}


sub process_request {
  my $self = shift;

  my $tls_started = 0;

  my $mode = &_get_var ('tls');
  $mode = "auto" unless defined $mode and length $mode;

  $caddr = $self->{server}->{peeraddr};
  $0 .= " [$caddr]";
  _net_write ("# munin node at $config->{fqdn}\n");
  local $SIG{ALRM} = sub { logger ("Connection timed out."); die "timeout" };
  alarm($config->{sconf}{'timeout'});
  while (defined ($_ = _net_read())) {
    alarm($config->{sconf}{'timeout'});
    chomp;
    if(!$tls_started and ($mode eq "paranoid" or $mode eq "enabled"))
    {
      if(!(/^starttls\s*$/i))
      {
        logger ("ERROR: Client did not request TLS. Closing.");
	_net_write ("# I require TLS. Closing.\n");
        last;
      }
    }
    logger ("DEBUG: Running command \"$_\".") if $config->{DEBUG};
    if (/^list\s*([0-9a-zA-Z\.\-]+)?/i) {
      &_list_services($1);
    }
    elsif (/^quit/i || /^\./) {
      exit 1;
    }
    elsif (/^version/i) {
      &_show_version;
	}
    elsif (/^nodes/i) {
      &_show_nodes;
    }
    elsif (/^fetch\s?(\S*)/i) {
      _print_service (&_run_service($1)) 
    }
    elsif (/^config\s?(\S*)/i) {
      _print_service (&_run_service($1,"config"));
    } 
    elsif (/^starttls\s*$/i) {
      my $key;
      my $cert;
      my $depth;
      my $ca_cert;
      my $tls_verify;
      $key = $cert = &_get_var ("tls_pem");
      $key = &_get_var ("tls_private_key")
	  unless defined $key;
      $key = "$Munin::Node::Defaults::MUNIN_CONFDIR/munin-node.pem" unless defined $key;
      $cert = &_get_var ("tls_certificate")
	  unless defined $cert;
      $cert = "$Munin::Node::Defaults::MUNIN_CONFDIR/munin-node.pem" unless defined $cert;
      $ca_cert = &_get_var("tls_ca_certificate");
      $ca_cert = "$Munin::Node::Defaults::MUNIN_CONFDIR/cacert.pem" unless defined $ca_cert;
      $depth = &_get_var ('tls_verify_depth');
      $depth = 5 unless defined $depth;
      $tls_verify = &_get_var ('tls_verify_certificate');
      $tls_verify = "no" unless defined $tls_verify;
      if (!_start_tls ($mode, $cert, $key, $ca_cert, $tls_verify, $depth))
      {
          if ($mode eq "paranoid" or $mode eq "enabled")
          {
              logger ("ERROR: Could not establish TLS connection. Closing.");
              last;
          }
      }
      else
      {
          $tls_started=1;
      }
      logger ("DEBUG: Returned from starttls.") if $config->{DEBUG};
    }
    else  {
      _net_write ("# Unknown command. Try list, nodes, config, fetch, version or quit\n");
    }
  }
}


sub _show_version {
  print "munins node on $config->{fqdn} version: $Munin::Node::Defaults::MUNIN_VERSION\n"
}


sub _show_nodes {
  for my $node (keys %nodes) {
    _net_write ("$node\n");
  }
  _net_write (".\n");
}


sub _load_services {
    $config->process_plugin_configuration_files();

    opendir (DIR,$config->{servicedir}) || die "Cannot open plugindir: $config->{servicedir} $!";
FILES:
    for my $file (grep { -f "$config->{servicedir}/$_" } readdir(DIR)) {
        # FIX isn't it enough to check that the file is executable and
        # not in 'ignores'?
	next if $file =~ m/^\./; # Hidden files
	next if $file =~ m/.conf$/; # Config files
	next if $file !~ m/^([-\w.]+)$/; # Skip if any weird chars
	$file = $1; # Not tainted anymore.
	foreach my $regex (@{$config->{ignores}})
	{
	    next FILES if $file =~ /$regex/;
	}
	next if (! -x "$config->{servicedir}/$file"); # File not executeable
	print "file: '$file'\n" if $config->{DEBUG};
	$services{$file}=1;
	my @rows = &_run_service($file,"config", 1);
	my $node = &_get_var ($file, 'host_name');

	for my $row (@rows) {
	  print "row: $row\n" if $config->{DEBUG};
	  if ($row =~ m/^host_name (.+)$/) {
	    print "Found host_name, using it\n" if $config->{DEBUG};
	    $node = $1;
	  }
	} 
	$node ||= $config->{fqdn};
	$nodes{$node}{$file}=1;
    }
    closedir DIR;
}


sub _print_service {
  my (@lines) = @_;
  for my $line (@lines) {
    _net_write ("$line\n");
  }
  _net_write (".\n");
}


sub _list_services {
    my $node = $_[0] || $config->{fqdn};
    _net_write( join( " ",
		     grep( { &_has_access ($_); } keys %{$nodes{$node}} )
		     ) )
      if exists $nodes{$node};
    #print join " ", keys %{$nodes{$node}};
    _net_write ("\n");
}


sub _has_access {
    my $serv   = shift;
    my $host   = $caddr;
    my $rights = _get_var_arr($serv, 'allow_deny');
    
    return 1 unless @{$rights};

    print STDERR "DEBUG: Checking access: $host;$serv;\n" if $config->{DEBUG};
    for my $ruleset (@{$rights}) {
        for my $rule (@{$ruleset}) {
            logger ("DEBUG: Checking access: $host;$serv;"
                        . $rule->[0].";".$rule->[1])
                if $config->{DEBUG};

            # tls
            if ($rule->[1] eq "tls" and $tls_verified{"verified"}) { 
                if ($rule->[0] eq "allow") {
                    return 1;
                } else {
                    return 0;
                }
            }
            
            # regex
            elsif ($host =~ m($rule->[1])) {
                if ($rule->[0] eq "allow") {
                    return 1;
                } else {
                    return 0;
                }
            }
        }
    }
    return 1;
}


sub _reap_children {
  my $child = shift;
  my $text = shift;
  return unless $child;
  if (kill (0, $child)) 
    { 
      _net_write ("# timeout pid $child - killing..."); 
      logger ("Plugin timeout: $text (pid $child)");
      kill (-1, $child); sleep 2; 
      kill (-9, $child);
      _net_write ("done\n");
    } 
}


sub _run_service {
  my ($service,$command,$autoreap) = @_;
  $command ||="";
  my @lines = ();
  my $timed_out = 0;
  my %sconf = %{$config->{sconf}};
  if ($services{$service} and ($caddr eq "" or &_has_access ($service))) {
    my $timeout = _get_var ($service, 'timeout');
    $timeout = $sconf{'timeout'} 
    	unless defined $timeout and $timeout =~ /^\d+$/;

    # FIX Why does Perl::Critic complain on this open? This is IPC not
    # a regular file open.

    ## no critic
    my $child_pid = open my $CHILD, '-|';
    ## use critic

    if ($child_pid) {
      eval {
	  local $SIG{ALRM} = sub { $timed_out=1; die "$!\n"};
	  alarm($timeout);
	  while(<$CHILD>) {
	    push @lines,$_;
	  }
      };
      if( $timed_out ) {
	  _reap_children($child_pid, "$service $command: $@");
	  close ($CHILD);
          return ();
      }
      unless (close $CHILD)
      {
	  if ($!)
	  {
	      # If Net::Server::Fork is currently taking care of reaping,
	      # we get false errors. Filter them out.
	      unless (defined $autoreap and $autoreap) 
	      {
		  logger ("Error while executing plugin \"$service\": $!");
	      }
	  }
	  else
	  {
	      logger ("Plugin \"$service\" exited with status $?. --@lines--");
	  }
      }
    }
    else {
      if ($child_pid == 0) {
	# New process group...
	POSIX::setsid();
        # Setting environment
	$sconf{$service}{user}    = &_get_var ($service, 'user');
	$sconf{$service}{group}   = &_get_var ($service, 'group');
	$sconf{$service}{command} = &_get_var ($service, 'command');

        # FIX Not very obvious that _get_var() should have a side effect ...
	&_get_var ($service, 'env', $sconf{$service}{env});
	
	if ($< == 0) # If root...
	{
		# Giving up gid egid uid euid
		my $u  = (defined $sconf{$service}{'user'}?
			$sconf{$service}{'user'}:
			$config->{defuser});
		my $g  = $config->{defgroup};
		my $gs = "$g $g" .
			($sconf{$service}{'group'}?" $sconf{$service}{group}":"");

#		_net_write ("# Want to run as euid/egid $u/$g\n") if $config->{DEBUG};

		if ($Munin::Node::Defaults::MUNIN_HASSETR)
		{
			$( = $g    unless $g == 0;
			$< = $u    unless $u == 0;
		}
		$) = $gs   unless $g == 0;
		$> = $u    unless $u == 0;

		if ($> != $u or $g != (split (' ', $)))[0])
		{
#			_net_write ("# Can't drop privileges. Bailing out. (wanted uid=",
#			    ($sconf{$service}{'user'} || $config->{defuser}), " gid=\"",
#			    $gs, "\"($g), got uid=$> gid=\"$)\"(", 
#			    (split (' ', $)))[0], ").\n");
			logger ("Plugin \"$service\" Can't drop privileges. ".
			    "Bailing out. (wanted uid=".
			    ($sconf{$service}{'user'} || $config->{defuser}). " gid=\"".
			    $gs. "\"($g), got uid=$> gid=\"$)\"(". 
			    (split (' ', $)))[0]. ").\n");
			exit 1;
		}
	}
#	_net_write ("# Running as uid/gid/euid/egid $</$(/$>/$)\n") if $config->{DEBUG};
	if (!Munin::Node::OS->check_perms("$config->{servicedir}/$service"))
	{
#	    _net_write ("# Error: unsafe permissions. Bailing out.");
	    logger ("Error: unsafe permissions. Bailing out.");
	    exit 2;
	}

	# Setting environment...
	if (exists $sconf{$service}{'env'} and
			defined $sconf{$service}{'env'})
	{
	    foreach my $key (keys %{$sconf{$service}{'env'}})
	    {
#		_net_write ("# Setting environment $key=$sconf{$service}{env}{$key}\n") if $config->{DEBUG};
		$ENV{"$key"} = $sconf{$service}{'env'}{$key};
	    }
	}
	if (exists $sconf{$service}{'command'} and 
		defined $sconf{$service}{'command'})
	{
	    my @run = ();
	    foreach my $t (@{$sconf{$service}{'command'}})
	    {
		if ($t =~ /^%c$/)
		{
		    push (@run, "$config->{servicedir}/$service", $command);
		}
		else
		{
		    push (@run, $t);
		}
	    }
	    print STDERR "# About to run \"", join (' ', @run), "\"\n" if $config->{DEBUG};
#	    _net_write ("# About to run \"", join (' ', @run), "\"\n") if $config->{DEBUG};
	    exec (@run) if @run;
	}
	else
	{
#	    _net_write ("# Execing...\n") if $config->{DEBUG};
	    exec ("$config->{servicedir}/$service", $command);
	}
      }
      else {
#	_net_write ("# Unable to fork.\n");
	logger ("Unable to fork.");
      }
    }
    wait;
    alarm(0);
  }
  else {
    _net_write ("# Unknown service\n");
  }
  chomp @lines;
  return (@lines);
}


sub _net_read 
{
    if (defined $tls)
    {
	eval { $_ = Net::SSLeay::read($tls); };
	my $err = &Net::SSLeay::print_errs("");
	if (defined $err and length $err)
	{
	    logger ("TLS Warning in _net_read: $err");
	}
	if($_ eq '') { undef $_; } #returning '' signals EOF
    }
    else
    {
	$_ = <STDIN>;
    }
    logger ("DEBUG: < $_") if $config->{DEBUG};
    return $_;
}


sub _net_write 
{
    my $text = shift;
    logger ("DEBUG: > $text") if $config->{DEBUG};
    if (defined $tls)
    {
	eval { Net::SSLeay::write ($tls, $text); };
	my $err = &Net::SSLeay::print_errs("");
	if (defined $err and length $err)
	{
	    logger ("TLS Warning in _net_write: $err");
	}
    }
    else
    {
	print STDOUT $text;
    }
}


sub _tls_verify_callback 
{
    my ($ok, $subj_cert, $issuer_cert, $depth, 
	    $errorcode, $arg, $chain) = @_;
#    logger ("ok is ${ok}");

    $tls_verified{"level"}++;

    if ($ok)
    {
        $tls_verified{"verified"} = 1;
        logger ("TLS Notice: Verified certificate.") if $config->{DEBUG};
        return 1; # accept
    }

    if(!($tls_verified{"verify"} eq "yes"))
    {
        logger ("TLS Notice: Certificate failed verification, but we aren't verifying.") if $config->{DEBUG};
	$tls_verified{"verified"} = 1;
        return 1;
    }

    if ($tls_verified{"level"} > $tls_verified{"required_depth"})
    {
        logger ("TLS Notice: Certificate verification failed at depth ".$tls_verified{"level"}.".");
        $tls_verified{"verified"} = 0;
        return 0;
    }

    return 0; # Verification failed
}


sub _start_tls 
{
    my $tls_paranoia = shift;
    my $tls_cert     = shift;
    my $tls_priv     = shift;
    my $tls_ca_cert  = shift;
    my $tls_verify   = shift;
    my $tls_vdepth   = shift;

    my $err;
    my $ctx;
    my $local_key = 0;

    %tls_verified = ( "level" => 0, "cert" => "", "verified" => 0, "required_depth" => $tls_vdepth, "verify" => $tls_verify );

    if ($tls_paranoia eq "disabled")
    {
	logger ("TLS Notice: Refusing TLS request from peer.");
	_net_write ("TLS NOT AVAILABLE\n");
	return 0
    }

    logger("Enabling TLS.") if $config->{DEBUG};
    eval {
        require Net::SSLeay;
    };

    if ($EVAL_ERROR) {
	if ($tls_paranoia eq "auto")
	{
	    logger ("Notice: TLS requested by peer, but Net::SSLeay unavailable.");
	    return 0;
	}
	else # tls really required
	{
	    logger ("Fatal: TLS enabled but Net::SSLeay unavailable.");
	    exit 0;
	}
    }

    # Init SSLeay
    Net::SSLeay::load_error_strings();
    Net::SSLeay::SSLeay_add_ssl_algorithms();
    Net::SSLeay::randomize();
    $ctx = Net::SSLeay::CTX_new();
    if (!$ctx)
    {
	logger ("TLS Error: Could not create SSL_CTX: " . &Net::SSLeay::print_errs(""));
	return 0;
    }

    # Tune a few things...
    if (Net::SSLeay::CTX_set_options($ctx, &Net::SSLeay::OP_ALL))
    {
	logger ("TLS Error: Could not set SSL_CTX options: " . &Net::SSLeay::print_errs(""));
	return 0;
    }

    # Should we use a private key?
    if (-e $tls_priv or $tls_paranoia eq "paranoid")
    {
        if (defined $tls_priv and length $tls_priv)
        {
	    if (!Net::SSLeay::CTX_use_PrivateKey_file($ctx, $tls_priv, 
		    &Net::SSLeay::FILETYPE_PEM))
	    {
	        logger ("TLS Notice: Problem occured when trying to read file with private key \"$tls_priv\": ".&Net::SSLeay::print_errs("").". Continuing without private key.");
	    }
	    else
	    {
	        $local_key = 1;
	    }
        }
    }
    else
    {
	logger ("TLS Notice: No key file \"$tls_priv\". Continuing without private key.");
    }

    # How about a certificate?
    if (-e $tls_cert)
    {
        if (defined $tls_cert and length $tls_cert)
        {
	    if (!Net::SSLeay::CTX_use_certificate_file($ctx, $tls_cert, 
		    &Net::SSLeay::FILETYPE_PEM))
	    {
	        logger ("TLS Notice: Problem occured when trying to read file with certificate \"$tls_cert\": ".&Net::SSLeay::print_errs("").". Continuing without certificate.");
	    }
	}
    }
    else
    {
	logger ("TLS Notice: No certificate file \"$tls_cert\". Continuing without certificate.");
    }

    # How about a CA certificate?
    if (-e $tls_ca_cert)
    {
        if(!Net::SSLeay::CTX_load_verify_locations($ctx, $tls_ca_cert, ''))
        {
            logger ("TLS Notice: Problem occured when trying to read file with the CA's certificate \"$tls_ca_cert\": ".&Net::SSLeay::print_errs("").". Continuing without CA's certificate.");
        }
    }

    # Tell the other side that we're able to talk TLS
    if ($local_key)
    {
        print "TLS OK\n";
    }
    else
    {
        print "TLS MAYBE\n";
    }

    # Now let's define our requirements of the node
    $tls_vdepth = 5 unless defined $tls_vdepth;
    Net::SSLeay::CTX_set_verify_depth ($ctx, $tls_vdepth);
    $err = &Net::SSLeay::print_errs("");
    if (defined $err and length $err)
    {
	logger ("TLS Warning in set_verify_depth: $err");
    }
    Net::SSLeay::CTX_set_verify ($ctx, &Net::SSLeay::VERIFY_PEER, \&_tls_verify_callback);
    $err = &Net::SSLeay::print_errs("");
    if (defined $err and length $err)
    {
	logger ("TLS Warning in set_verify: $err");
    }

    # Create the local tls object
    if (! ($tls = Net::SSLeay::new($ctx)))
    {
	logger ("TLS Error: Could not create TLS: " . &Net::SSLeay::print_errs(""));
	return 0;
    }
    if ($config->{DEBUG})
    {
	my $i = 0;
	my $p = '';
	my $cipher_list = 'Cipher list: ';
	$p=Net::SSLeay::get_cipher_list($tls,$i);
	$cipher_list .= $p if $p;
	do {
	    $i++;
	    $cipher_list .= ', ' . $p if $p;
	    $p=Net::SSLeay::get_cipher_list($tls,$i);
	} while $p;
        $cipher_list .= '\n';
	logger ("TLS Notice: Available cipher list: $cipher_list.");
    }

    # Redirect stdout/stdin to the TLS
    Net::SSLeay::set_rfd($tls, fileno(STDIN));
    $err = &Net::SSLeay::print_errs("");
    if (defined $err and length $err)
    {
	logger ("TLS Warning in set_rfd: $err");
    }
    Net::SSLeay::set_wfd($tls, fileno(STDOUT));
    $err = &Net::SSLeay::print_errs("");
    if (defined $err and length $err)
    {
	logger ("TLS Warning in set_wfd: $err");
    }

    # Try to negotiate the tls connection
    my $res;
    if ($local_key)
    {
        $res = Net::SSLeay::accept($tls);
    }
    else
    {
        $res = Net::SSLeay::connect($tls);
    }
    $err = &Net::SSLeay::print_errs("");
    if (defined $err and length $err)
    {
	logger ("TLS Error: Could not enable TLS: " . $err);
	Net::SSLeay::free ($tls);
	Net::SSLeay::CTX_free ($ctx);
	$tls = undef;
    }
    elsif (!$tls_verified{"verified"} and $tls_paranoia eq "paranoid")
    {
	logger ("TLS Error: Could not verify CA: " . Net::SSLeay::dump_peer_certificate($tls));
	Net::SSLeay::free ($tls);
	Net::SSLeay::CTX_free ($ctx);
	$tls = undef;
    }
    else
    {
	logger ("TLS Notice: TLS enabled.");
	logger ("TLS Notice: Cipher `" . Net::SSLeay::get_cipher($tls) . "'.");
	$tls_verified{"cert"} = Net::SSLeay::dump_peer_certificate($tls);
	logger ("TLS Notice: client cert: " .$tls_verified{"cert"});
    }

    return $tls;
}


sub _get_var_arr
{
    my $name    = shift;
    my $var     = shift;
    my $result  = [];

    my $sconf   = $config->{sconf};

    if (exists $sconf->{$name}{$var})
    {
	push (@{$result}, $sconf->{$name}{$var});
    }

    foreach my $wildservice (grep (/\*$/, reverse sort keys %{$sconf}))
    {
	(my $tmpservice = $wildservice) =~ s/\*$//;
	next unless ($name =~ /^$tmpservice/);
	print STDERR "# Checking $wildservice...\n" if $config->{DEBUG};

	if (defined $sconf->{$wildservice}{$var})
	{
	    push (@{$result}, $sconf->{$wildservice}{$var});
	    print STDERR ("DEBUG: Pushing: |", join (';', @{$sconf->{$wildservice}{$var}}), "|\n")
		if $config->{DEBUG};
	}
    }
    return $result;
}


sub _get_var
{
    my $name    = shift;
    my $var     = shift;
    my $env     = shift;

    my $sconf   = $config->{sconf};


    if (!defined $var and defined $name)
    {
	return $sconf->{$name};
    }
    if ($var eq 'env' and !defined $env)
    {
	%{$env} = ();
    }
    
    if ($var ne 'env' and exists $sconf->{$name}{$var})
    {
	return $sconf->{$name}{$var};
    }
    # Deciding environment
    foreach my $wildservice (grep (/\*$/, reverse sort keys %{$sconf}))
    {
	(my $tmpservice = $wildservice) =~ s/\*$//;
	next unless ($name =~ /^$tmpservice/);
#	_net_write ("# Checking $wildservice...\n") if $config->{DEBUG};

	if ($var eq 'env')
	{
	    if (exists $sconf->{$wildservice}{'env'})
	    {
		foreach my $key (keys %{$sconf->{$wildservice}{'env'}})
		{
		    if (! exists $sconf->{$name}{'env'}{$key})
		    {
                        # FIX What!? A sideffect in a getter? This
                        # reeks ...
			$sconf->{$name}{'env'}{$key} = $sconf->{$wildservice}{'env'}{$key};
			_net_write ("Saving $wildservice->$key\n") if $config->{DEBUG};
		    }
		}
	    }
	}
	else
	{
	    if (! exists $sconf->{$name}{$var} and
		    exists $sconf->{$wildservice}{$var})
	    {
		return ($sconf->{$wildservice}{$var});
	    }
	}
    }
    return $env;
}

1;

__END__

=head1 NAME

Munin::Node::Server - This module implements a Net::Server server for
the munin node.

=head1 SYNOPSIS

 use Munin::Node::Server;
 Munin::Node::Server->run(...);
 
For arguments to run(), see L<Net::Server>.

=head1 METHODS

=head2 NET::SERVER "CALLBACKS"

=over

=item B<pre_loop_hook>

Loads all the plugins (services)

=item B<process_request>

Processes the request ...

=cut