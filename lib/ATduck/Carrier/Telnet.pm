package ATduck::Carrier::Telnet;
# This file is part of ATduck
use IO::Socket::INET;
use ATduck::Carrier;
use warnings;
use strict;

our @ISA = qw(ATduck::Carrier);

my @TERM = ('DEC-VT100','VT100','NETWORK');

sub new {
    my ($class, $modem, $arg) = @_;
    my $self = $class->SUPER::new($arg);
    bless($self, $class);

    $self->{buf} = '';
    $self->{term} = -1;
    $self->{telnet_will} = [];
    #$self->{telnet_do} = [];

    # Set up subprocess environment
    my ($host,$port) = ($self->{insuffix}, 23);
    $host =~ s/^[\s,]+//;
    if ( $host =~ /[a-zA-Z:.]/ ) {  # Parse text format
        $port = $1 if $host =~ s/:(.*)//;
    }
    else {                          # Parse "phone number" format
        $host =~ s/\D//g;
        $host =~ m/^(\d{3})(\d{3})(\d{3})(\d{3})(\d*)/ or return undef;
        $host = sprintf('%d.%d.%d.%d', $1, $2, $3, $4);
        $port = $5 || 23;
    }
    ATduck::Main->debug(1, undef, "Trying $host on $port...");
    my $sock = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $port)
        or return undef;
    $self->register($sock);

    return $self;
}

sub _will {
    my ($self, $option, $value) = @_;
    $self->{telnet_will}[$option] = $value if defined($value);
    $value = $self->{telnet_will}[$option];
    return defined($value) ? $value : 0;
}

sub read {
    my ($self, $size) = @_;
    my $buf = $self->SUPER::read($size);
    return undef unless defined($buf); # read returned undef; something's wrong
    $self->{buf} .= $buf;
    if ( 0 ) {
        my $c = join(' ', map { ord } split '', $buf);
        ATduck::Main->debug(1, undef, "Got $c");
    }
    $buf = '';
    my $restore = '';
    while ( $self->{buf} =~ s/^([^\xff]*)(\xff|$)// ) {
        $buf .= $1; $restore = $2;
        # If we're not starting a command, return what we read
        last unless $restore;
        # Try to parse the command
        $self->{buf} =~ s/^(.)// or last;
        $restore .= $1;
        my $command = ord $1;
        my $reply = '';
        if ( $command == 250 ) {    # SB (Subnegotiation begin)
            # Grab everything up to 240 (SE: Subnegotiation end).
            $self->{buf} =~ s/(.)(.*?)\xff\xf0// or last;
            # Note: Not stored in restore, assumes rest is always successful
            my ($type,$data) = (ord($1),$2);
            if ( $type == 24 && $data eq "\x01" && $self->_will(24) ) {
                # First byte: 1 = SEND, 0 = IS
                $self->{term}++;
                $self->{term} = -1 if $self->{term} >= @TERM;
                $reply = "\xfa\x18\x00$TERM[$self->{term}]\xff\xf0";
                ATduck::Main->debug(1, undef, "Sending terminal type $TERM[$self->{term}]");
            }
        }
        elsif ( $command >= 251 && $command <= 254 ) {
            $self->{buf} =~ s/^(.)// or last;
            # Note: Not stored in restore, assumes rest is always successful
            my $arg = $1;
            my $narg = ord($arg);
            if ( $command == 251 ) { # WILL
                $reply = "\xfe$arg";    # DONT
            }
            elsif ( $command == 252 ) { # WON'T
                $reply = "\xfe$arg";    # DON'T
            }
            elsif ( $command == 253 ) { # DO
                if ( $narg == 24 ) {    # Terminal type
                    $self->_will($narg, 1);
                    $reply = "\xfb$arg";# WILL
                }
                else {
                    $reply = "\xfc$arg";# WON'T
                }
            }
            elsif ( $command == 254 ) { # DON'T
                $self->_will($narg, 0);
                $reply = "\xfc$arg";    # WON'T
            }
        }
        elsif ( $command == 255 ) { # IAC escape
            $buf .= '\xff';
        }
        $restore = ''; # Parsing successful; clear restore buffer.
        # Send reply, if any.
        if ( 0 && $reply ) {
            my $c = join(' ', map { ord } split '', "\xff$reply");
            ATduck::Main->debug(1, undef, "Replying $c");
        }
        # Use SUPER's write because ours has been overridden to do escaping
        $self->SUPER::write("\xff$reply") if $reply;
    }
    $self->{buf} = "$restore$self->{buf}" if $restore;
    return $buf;
}

sub write {
    my ($self, $buf) = @_;
    if ( $buf ) {
        $buf =~ s/\r(?!\n)/\r\000/g; # Telnet prohibits bare CR, except CRLF
        $buf =~ s/\xff/\xff\xff/g; # Escape IAC by doubling it
    }
    return $self->SUPER::write($buf);
}

1;
