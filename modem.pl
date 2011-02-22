#!/usr/bin/perl
#
# modem.pl - Hayes-compatible modem emulator for virtual machines
#
# Copyright (c) 2007-2011 nandhp <nandhp@gmail.com>
#
# USAGE
#
# Works with QEMU and VMWare [Player]. Configure the serial port as follows:
#   QEMU: Use command line option -serial unix:FILENAME,server
#   VMWARE: Use socket (named pipe) from Server to Virtual Machine
# Then run modem.pl with FILENAME on the command line.
#
# In case of Bochs, configure the serial port to use TCP server:
#   BOCHS: Use "com1: enabled=1, mode=socket-server, dev=localhost:PORT"
# Then run modem.pl with [HOST:]PORT on the command line.
#
# TESTED DIALERS
# - 16-bit MSIE5.01's built-in ShivaPPP dialer
# - Windows 95 DUN
# - Windows NT 3.51 RAS (Wants "real" RS-232, use "Manual modem commands")
#
# BUGS
#
# PPP works if the entry for your machine's hostname in /etc/hosts is not
# a loopback address like 127.xxx.xxx.xxx (Sadly, the default is 127.0.1.1).
# To fix, patch SLIRP's options.c to remove the check "&& !bad_ip_adrs(local)"
#
# Ignores some modem settings. (Guard time)
# Doesn't handle reboots/hangups very well. (FIXED?)
# Loops when serial port socket is disconnected. (FIXED?)
#
# Should have better phonebook. Dial 62442 for getty, anything else for slirp.
#

my $VERSION = 20110207;

use IO::Select;
use IPC::Open3;
use IPC::Open2;
use IO::Pty;
use Socket;
use POSIX qw(:errno_h);
use strict;
our $| = 1;

my $rate=115200;
my $show_data = 0;

my $fn = $ARGV[0]||'/media/m/VMWare/Windows 3.1/COM1';

# Open "serial line"
my $pipe;
my ($carrierreadfh,$carrierwritefh,$carrierpty);
my ($carrierread,$carrierwrite);
my $carrier = 0;

print "Opening serial line...\n";
if ( $fn =~ m/^(?:([^\\\/:]*):)?(\d+)$/ ) { # INET socket
    my ($host,$port) = ($1||'localhost',$2);
    my $iaddr = inet_aton($host) or die "INET no host: $host";
    my $paddr = sockaddr_in($port, $iaddr);
    my $proto = getprotobyname('tcp');
    socket($pipe, PF_INET, SOCK_STREAM, $proto) or die "INET socket: $!";
    connect($pipe, $paddr) or die "INET connect: $!";
}
#elsif ( 0 ) { open $pipe, '+<', $fn or die "Can't open pipe: $!" }
else { # Unix socket
    socket($pipe, PF_UNIX, SOCK_STREAM, 0) or die "socket: $!";
    connect($pipe, sockaddr_un($fn)) or die "connect: $!";
}
{ my $orig = select($pipe); $|=1; select($orig) }

print "Serial line established.\n";
my $select = IO::Select->new();
$select->add($pipe);
$SIG{CHLD} = \&child_hangup;

# Constants
my %responses = ( OK => 0, CONNECT => 1, RING => 2, 'NO CARRIER' => 3,
		  ERROR => 4, 'NO DIALTONE' => 6, BUSY => 7,
		  'NO ANSWER' => 8 );
my ($ident,$nident) = ('nandhp_VMODEM',127001);
my @info = ($nident,	# I0
	    0,		# I1 Display checksum
	    '',		# I2 Verify checksum
	    '',         # I3
	    $ident,	# I4 OEM String
	   );

# http://docs.kde.org/stable/en/kdenetwork/kppp/hayes-sregisters.html
my @defreg = (0,	# S0  Answer on ring number. Don't answer if 0
	      0,	# S1  Count of incoming rings.
	      43,	# S2  Escape to cmd mode char (43='+',>127=None)
	      ord("\r"),# S3  Carriage return character (13="\r")
	      ord("\n"),# S4  Line feed character (10="\n")
	      8,	# S5  Backspace character
	      0,	# S6  Dial tone wait time (default 2-255)
	      0,	# S7  Carrier wait time (default 1-255 sec)
	      0,	# S8  Comma pause time (default 2)
	      0,	# S9  Carrier detect time (1-255 1/10ths second)
	      0,	# S10 Time from carrier loss to hangup (1/10ths sec.)
	      0,	# S11 Pulse dial tone length (50-255 milliseconds)
	      50,	# S12 Guard time for +++ (0-255 1/50th seconds)
	     );

# Settings storage
my ($echo_mode, $quiet_mode, $verbose_mode,$smartmodem);
my @reg;
init_defaults();

# Load phonebook
my @phonebook = ();
{
    my $idx = -1;
    while (<DATA>) {
        next if m/^(;|#|$)/;
        s/^\s*|\s*$//g;
        if ( m/^\[(.+)\]/ ) {
            $idx++;
            $phonebook[$idx]{Pattern} = $1;
        }
        elsif ( m/(.+?)=(.+)/ ) { $phonebook[$idx]{$1} = $2 }
        else { die "Phonebook parse error" }
    }
}
my %dialoptions = %{shift @phonebook} or die "Phonebook parse error";

# Current State
my $suspended = 0;
my $last_readtime = 0;
my $is_reading_plus = 0;
my $plus_readtime = 0;
my $last_direction = '';
print "[OK]\n";
while (1) {
    my $line = '';#$waiting;
    #$waiting = '';
    #print "Reading line:$line";
    #print "Waiting...\n";
  READ:
    while (1) {
	if ( my @readables = $select->can_read() ) {
	    foreach ( @readables ) {
		my $char = '';
		if ( ($carrier && !$suspended) && $_ eq $pipe ) {
		    # Read pipe write slirp
		    my $rc = sysread($pipe,$char,1);
		    die "VM hangup?\n" unless $rc;
		    if ( $show_data ) {
			if ( $last_direction ne '<' )
			    { print "\n<"; $last_direction = '<' }
			print printable($char);
		    }
		    if ( $is_reading_plus && (time >= $plus_readtime+1) ) {
			$plus_readtime = 0;
			$is_reading_plus = 0;
		    }
		    if ( $reg[2] <= 127 && ord $char == $reg[2] ) {
			print "\n" if $show_data;
			$last_direction = '';
			if ( $is_reading_plus || ($is_reading_plus == 0 &&
			                          time >= $last_readtime+1) ) {
			    $is_reading_plus++;
			    print "[PLUS $is_reading_plus]\n";
			}
			if ( $is_reading_plus == 3 ) {
			    $suspended = 1;
			    $plus_readtime = 0;
			    $is_reading_plus = 0;
			    print "[SUSPEND]\n";
			    modemreply('OK');
			}
			$last_readtime = $plus_readtime = time;
		    }
		    else { $last_readtime = time }
		    syswrite($carrierwrite, $char);
		}
		elsif ( $_ eq $pipe ) {
		    # Prepare a line
		    sysread($pipe,$char,1);
		    syswrite($pipe,$char) if $echo_mode;
    		    if ( ord($char) == $reg[3] || ord($char) == $reg[4] ) {
    		        # Use of \n for termination is not strictly permitted.
    		        next unless $line;
    		        print "\n";
    		        last READ;
		    }
    		    elsif ( ord($char) == $reg[5] ) { # Backspace
		        next unless $line;
		        print chr(8);
		        $line = substr($line,0,-1);
		    }
		    else {
		        print $char;#." ".ord($char)."\n";
		        $line .= $char;
		    }
		}
		#elsif ( $_ eq $slirpin ) {
		#    my $c = ''; my $rc = sysread($slirpin, $c, 1);
		#    if ( $rc == 0 ) {
		#        print "NO CARRIER (2)\n";
		#    }
		#    print $c;
	        #}
		elsif ( !$suspended ) {
		    # Read from slirp write to pipe
		    my $rc = sysread($carrierread, $char, 1);#slirpin
		    if ( !defined($rc) ) {
		        next if $! == EAGAIN;
		        print "$!\n";
	            } elsif( $rc == 0 ) {
		        modemreply('NO CARRIER');
		        hangup();
		        next;
	            }
	            else {
		        if ( $show_data ) {
			    if ( $last_direction ne '>' )
			      { print "\n>"; $last_direction = '>' }
			    print printable($char);
		        }
		        syswrite($pipe,$char);
		    }
		}
	    }
	}
    }

    #print "\n";#print "\n$line\n";
    $line =~ s/^\s*|\s*$//g;
    $line =~ s/^.*?(\+\+\+|AT)/$1/i;
    modemreply('OK') if $line =~ s/^\+\+\+//; # Should only do this first time.
    next unless $line =~ m/^AT/i;
    my $result = 'OK';
    $line =~ s/^AT//i;

    while ( $line ) {
	$line =~ s/^\s*|\s*$//g; # For NT3 RAS
	# Reset
	if ( $line =~ s/^(Z\d*|&F\d*)//i ) {
	    hangup();
	    init_defaults();
	}
	# The following commands affect the physical serial, telephone line,
	# or conversation in ways that cannot be implemented.
	elsif ( $line =~ s/^&C[01]?//i ) { } # Carrier Detect
	elsif ( $line =~ s/^&D[0123]?//i ) { } # Data Terminal Ready
	elsif ( $line =~ s/^&K[0123456]?//i ) { } # Flow control
	elsif ( $line =~ s/^\\Q[0123]?//i ) { } # Flow control
	elsif ( $line =~ s/^B[012]?//i ) { } # Bell mode (Most modems ignore)
	elsif ( $line =~ s/^L[0123]?//i ) { } # Speaker Loudness
	elsif ( $line =~ s/^M[0123]?//i ) { } # Speaker on/off
	elsif ( $line =~ s/^[PT]//i ) { } # Default to tone/pulse dialing

	# The following commands control the conversation
	elsif ( $line =~ s/^A//i ) { # Answer incoming call
	    if ( $carrier ) { $result = 'ERROR'; last }
	    else { $result = 'NO CARRIER'; last }
	}
	elsif ( $line =~ s/^D([-\s\d\*\#ABCD,PT!W;L]+)//i ) {
	    my $dialtag = $1;
	    $dialtag =~ s/\D//g;
	    if ( $carrier ) { $result = 'ERROR'; last }
	    hangup();
	    print "\n[Dialing]\n";
	    my $obj = undef;
	    foreach ( @phonebook ) {
	        next unless $_->{Pattern};
	        if ( $dialtag =~ m/$_->{Pattern}/ ) { $obj = $_; last }
	    }
	    my @cmd = split(/\s+/, ($obj->{Helper} ?
	                            $dialoptions{$obj->{Helper}} :
	                            $obj->{Command})||'');
            my $printcmd = 'Using command line ';
	    foreach ( @cmd ) {
	        s/%command%/$obj->{Command}||''/eg;
	        s/%tty(name|path)%/getcarrierpty($1)/eg;
	        s/%rate%/$rate/g;
	        s/%sp%/ /g;
	        s/%(\d+)%/'$'.$1/eeg;
	        $printcmd .= " '$_'";
	    }
	    print "[$printcmd]\n";
	    if ( @cmd ) {
	        local $ENV{SLIRP_TTY} = getcarrierpty('path') if $carrierpty;
	        local $ENV{TERM} = 'vt100';
	        $carrier = open2($carrierreadfh, $carrierwritefh, @cmd);
	    }

            if ( $carrier ) { $result = 'CONNECT '.$rate }
            else { $result = 'NO CARRIER'; last }
            my $origfh = select;
            if ( $carrierpty ) {
                $carrierread = $carrierpty;
                $carrierwrite = $carrierpty;
            }
            else {
                $carrierread = $carrierreadfh;
                $carrierwrite = $carrierwritefh;
            }
            for my $fh ( $carrierread, $carrierwrite ) {
                use Fcntl;
                my $flags = '';
                fcntl($fh, F_GETFL, $flags) or warn "Couldn't get flags: $!";
                $flags |= O_NONBLOCK;
                fcntl($fh, F_SETFL, $flags) or warn "Couldn't set flags: $!";
                select($fh); $| = 1;
            }
            select($origfh);
	    $suspended = 0;
	    $select->add($carrierread);
	    last;
	}
	elsif ( $line =~ s/^H([0]?)//i ) {
	    my $arg = $1+0;
	    if ( $arg && $carrier ) { $result = 'ERROR'; last }
	    elsif ( $arg ) { $result = 'NO CARRIER'; last }
	    else { hangup() }
	}
	elsif ( $line =~ s/^O([01]?)//i ) { # Go online
	    if ( $suspended && $carrier ) {
	        $result = 'CONNECT '.$rate;
	        $suspended = 0;
	    }
	    else { $result = 'NO CARRIER'; last }
	}

	# The following commands set options
	elsif ( $line =~ s/^W[012]?//i ) { } # FIXME Negotiation progress msgs
	elsif ( $line =~ s/^X([01234]?)//i ) { # Call progress information
	    # 0: "CONNECT" 1: "CONNECT text"
	    # 2: "CONNECT text"+dialtone detection
	    # 3: "CONNECT text"+busy detection
	    # 4: "CONNECT text"+dialtone and busy detection
	    $smartmodem = length($1)?($1+0):0;
	}
	elsif ( $line =~ s/^E([01]?)//i ) { $echo_mode = $1+0 } # Echo
	elsif ( $line =~ s/^Q([01])//i ) { $quiet_mode = $1+0 } # Quiet
	elsif ( $line =~ s/^V([01]?)//i ) { $verbose_mode = $1+0 } # Verbose
	elsif ( $line =~ s/^S(\d+)\?//i ) { $result = ($reg[$1]||0)."\r\nOK" }
	elsif ( $line =~ s/^S(\d+)=(\d+)//i ) { $reg[$1]=$2+0 }

	# The following commands retrieve identifying information
	elsif ( $line =~ s/^I(\d*)//i ) {
	    my $idx = $1+0;
	    if ( ($idx < @info) && length($info[$idx])>0 )
	      { $result = $info[$idx]."\r\nOK" }
	    else { $result = 'OK' }
	}
	# The following information commands are required by V.250. Be
	# careful, this extended command format come with some other baggage.
	# If any more are implemented (e.g. FAX), use a special parser.
	elsif ( $line =~ s/^\+GMI(=\?)?\s*(;|$)//i )
	    { $result = "nandhp\r\nnandhp\@gmail.com\r\nOK" unless $1 }
	elsif ( $line =~ s/^\+GMM(=\?)?\s*(;|$)//i )
	    { $result = "$ident\r\nOK" unless $1 }
        elsif ( $line =~ s/^\+GMR(=\?)?\s*(;|$)//i )
	    { $result = "$VERSION\r\nOK" unless $1 }
        #elsif ( $line =~ s/^\+GSN(=\?)?\s*(;|$)//i )
	#    { $result = "$nident\r\nOK" unless $1 }
        elsif ( $line =~ s/^\+GCAP(=\?)?\s*(;|$)//i )
	    { $result = "+GCAP:\r\nOK" unless $1 }
	else { $result = 'ERROR'; last }
    }
    modemreply($result);
}

# http://www.tc.bham.ac.uk/Documentation/software/hylafax/Modems/Hayes/hayes.html for more about W and S95

sub modemreply {
    my ($result) = @_;
    if ( $quiet_mode ) {
        print "\r\n$result\r\n";
        return;
    }
    # Table 3/V.250 – Effect of V parameter on response formats
    #                       V0                 V1
    # Information responses <text><cr><lf>     <cr><lf><text><cr><lf>
    # Result codes          <numeric code><cr> <cr><lf><verbose code><cr><lf>
    if ( $verbose_mode ) {
        $result =~ s/ +\d+$//g if !$smartmodem;
        $result = "\r\n$result\r\n";
    }
    else {
        my ($text,$code) = $result =~ m/^((?:[\s\S]*\r\n)?)([^\r\n]+)$/;
        $code =~ s/ +\d+$//g;
        $result = $text.(exists($responses{$code})?$responses{$code}:99)."\r";
    }
    print $result; print "\n" unless $verbose_mode;
    # Get values for \r and \n from registers.
    $result =~ s/(\r|\n)/chr(($1 eq "\r")?$reg[3]:$reg[4])/eg;
    syswrite($pipe,$result);
}
###{ my $presult = "\r\n$result\r\n"; $presult =~ s/\r/\\r/g;$presult =~ s/\n/\\n/g; print $presult,"\n"; }

sub getcarrierpty {
    my ($flag) = @_;
    if ( !$carrierpty ) {
        $carrierpty = new IO::Pty;
        print '[Allocated Terminal: ',$carrierpty->ttyname(),"]\n";
    }
    my $fn = $carrierpty->ttyname();
    $fn =~ s/^\/dev\/// if $flag eq 'name';
    return $fn;
}

sub child_hangup {
    my $pid = wait;
    # FIXME Too much stuff happens here, needs Perl 5.8
    if ( $carrier && $pid == $carrier ) {
        modemreply('NO CARRIER') unless $suspended;
        hangup();
    }
}

sub hangup {
    local $SIG{CHLD} = 'IGNORE';
    print "[HANGUP]\n" if $carrier > 1;
    $select->remove($carrierread) if $carrierread;
    #print $pty "00000" if $pty;
    #print $slirpout "00000" if $slirpout;
    close $carrierreadfh if $carrierreadfh; undef $carrierreadfh;
    close $carrierwritefh if $carrierwritefh; undef $carrierwritefh;
    close $carrierpty if $carrierpty; undef $carrierpty;
    undef $carrierread; undef $carrierwrite;
    #close $pty if $pty; undef $pty;
    kill 15, $carrier if $carrier > 1;
    waitpid $carrier, 0;
    $carrier = 0;
    $suspended = 0;
    $last_direction = '';
}

sub init_defaults {
    $echo_mode = 1; # E
    $quiet_mode = 0; # Q
    $verbose_mode = 1; # V
    $smartmodem = 4;
    @reg = @defreg;
}

sub printable {
    my ($char) = @_;
    my $c = ord $char;
    return '.' if $c < 32 or $c > 126 or $c == 33;
    return $char;
}
__DATA__
[Settings]
getty=getty -nl%command% %rate% %ttyname%
todos=sh -c (%command%)|todos
[62442]
Helper=getty
Command=/bin/bash

[611]
Helper=todos
Command=/bin/ls -l /tmp/foo

[6384225]
Command=telnet nethack.alt.org

[(.*)]
Command=slirp-nandhp-patch ppp initiate-options tty%sp%%ttypath%

