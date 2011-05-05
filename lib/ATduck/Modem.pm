package ATduck::Modem;
# This file is part of ATduck

use ATduck::DialPlan;
use Time::HiRes;
use constant {
    # Command argument formats
    OPT_ARG => 0, NO_ARG => 1, SREG_ARG => 2, DIAL_ARG => 3, EXT_ARG => 4,
    # Extended command operation modes
    EXT_QUERY => 0, EXT_HELP => 1, EXT_SET => 2,
    # Common responses
    OK => [undef, 'OK', undef], ERROR => [undef, 'ERROR', undef]
};
use warnings;
use strict;

# Conversion from text responses to numeric responses
my %numerics = ( OK => 0, CONNECT => 1, RING => 2, 'NO CARRIER' => 3,
                 ERROR => 4, 'NO DIALTONE' => 6, BUSY => 7, 'NO ANSWER' => 8 );

# Default values for S-registers
my @reg = (0,         # S0  Auto-answer on this ring. Don't auto-answer if 0.
           0,         # S1  Incoming ring counter.
           43,        # S2  Escape to command mode char (43='+',>127=None)
           ord("\r"), # S3  Carriage return character (13="\r")
           ord("\n"), # S4  Line feed character (10="\n")
           ord("\b"), # S5  Backspace character (8="\b")
           0,         # S6  Dial tone wait time (default 2-255 sec)
           0,         # S7  Carrier wait time (default 1-255 sec)
           0,         # S8  Comma pause time (default 2)
           0,         # S9  Carrier detect time (1-255 1/10ths second)
           0,         # S10 Time from carrier loss to hangup (1/10ths sec.)
           0,         # S11 Pulse dial tone length (50-255 milliseconds)
           50,        # S12 Guard time for +++ (0-255 1/50th seconds)
          );

# Rate, used for CONNECT status
our $rate = 115200;
my $ring_cadence = 6;

my $MODE_COMMAND   = 0x01; # Accepting commands, suspended if with ONLINE
my $MODE_ONLINE    = 0x02; # Call is established, suspended if with COMMAND
my $MODE_PENDING   = 0x04; # Call ringing (with COMMAND) or waiting for remote
#my $MODE_SUSPENDED = $MODE_COMMAND | $MODE_ONLINE;  # Temp. escaped from call
#my $MODE_INCOMING  = $MODE_COMMAND | $MODE_PENDING; # Receiving a call
#my $MODE_OUTGOING  = $MODE_PENDING;                 # Placing a call
#my $MODE_BUSY      = $MODE_ONLINE | $MODE_PENDING;  # Line is busy

sub new {
    my ($class, $serial) = @_;
    die "Not a client socket" unless $serial->reader;
    my $self = { serial => $serial, id => 0, # Serial line
                 carrier => undef, mode => $MODE_COMMAND, # Modem mode
                 readtime => 0, readplus => 0, plustime => 0, # Modem escape
                 templine => '', lastline => 'AT',
               };
    bless($self, $class);

    # Reset the modem
    $self->init();

    # Insert the modem into the list
    ATduck::EventLoop->add_modem($self);

    # Look up our Caller ID information
    ($self->{number}, $self->{name}) =
        ATduck::DialPlan->reverse('Modem', $self->{id});
    $self->{name} ||= 'O'; $self->{number} ||= 'O';

    #{ my $orig = select($m->{serial}{r}); $|=1; select($orig) }
    ATduck::Main->debug(1, $self, 'Modem created');

    return $self;
}

sub init {
    my ($self) = @_;
    $self->{echo} = 1;          # E1
    $self->{quiet} = 0;         # Q0
    $self->{verbose} = 1;       # V1
    $self->{smartmodem} = 4;    # X4
    $self->{sendcid} = 0;       # +VCID=0
    $self->{serviceclass} = 0;  # +FCLASS=0
    $self->{reg} = [ @reg ];
}

sub ready {
    # Read from the serial port and process the input
    my ($self) = @_;
    my $buf = $self->serial->read(512);
    if ( !defined($buf) ) {
        ATduck::EventLoop->remove_modem($self);
    }
    elsif ( $self->command_mode ) { # Handle command
        # Serial echo
        $self->serial->write($buf) if $self->{echo};
        ATduck::Main->tracestream($self, 0, 1, $buf);

        # Append to the temporary buffer
        $self->{templine} .= $buf;

        # Backspace
        my $bs = quotemeta(chr($self->reg(5)));
        1 while $self->{templine} =~ s/(?:^|.)$bs//;

        # Parse for A/ or ATcommand
        my $le = quotemeta(chr($self->reg(3)).chr($self->reg(4)));
        while ( $self->{templine} =~ s/^.*?(?:A\/|(AT.*?)\s*[$le]+)//si ) {
            $self->{lastline} = $1 if defined($1); # AT command
            #printprefix('');
            $self->_command($self->{lastline});
        }
        # Test with: ATI4    A/ATI3 foo\nbar\nA/foobar\n

        # Remove all remaining complete lines, since they apparently
        # don't have AT on them.
        $self->{templine} =~ s/^.+[$le]+//sg;
    }
    elsif ( $self->online_mode ) { # Forward packets to the carrier
        # Check for escape sequence
        my $now = Time::HiRes::time; my $plus = $self->reg(2);
        if ( ($plus <= 127) and      # > 127 denotes Escape disabled
             ($plus = quotemeta chr $plus) and
             ($buf =~ m/^(.*?)((?:$plus){1,3})(.*?)$/) and
             (!$self->reg(12) or (!$1 and !$3)) ) {
            my ($prefix, $pluscount, $suffix) = ($1, length($2), $3);
            my $guard = $self->reg(12)/50.0;

            # Test with:    foo+++ATH    +++ATH    +++

            # If we last had a plus, reset if guard time exceeded since.
            # Else, ensure guard time exceeded since last read.
            if ( ( $self->reg(12) and $self->{readplus} and
                   ($now >= $self->{plustime}+$guard) ) or
                 ( !$self->{readplus} and ($now >= $self->{readtime}+$guard) ))
                { $self->{readplus}  = $pluscount }
            # Another plus soon after the last
            elsif ( $self->{readplus} ) { $self->{readplus} += $pluscount }
            if ( $self->{readplus} ) {
                ATduck::Main->debug(1, $self,
                                    "Plus $self->{readplus} at $now");
                $self->{plustime} = $now;
            }

            # Suspend after guard time elapses
            if ( $self->{readplus} >= 3 ) {
                my $endtime = $self->{plustime}+$self->reg(12)/50.0;
                ATduck::EventLoop->at($endtime, sub { $self->_checkplus() });
            }
        }
        else {
            $self->{readplus} = $self->{plustime} = 0;
            ATduck::Main->tracestream($self, 0, 0, $buf);
        }
        $self->{readtime} = $now;

        # Write to carrier, unless it's a suspended modem
        $self->carrier->write($buf);
        # unless exists($m->{carrier}{modem}) and
        #       $m->{carrier}{modem}{suspended};
    }
    elsif ( $self->is_placing ) { # Cancel outgoing call
        $self->hangup();
    }
    else {
        # die
    }
}

sub _checkplus {
    my ($self) = @_;
    return unless $self->is_online;
    return unless $self->online_mode and ($self->{readplus} == 3) and
                  ($self->{readtime} <= $self->{plustime});
    $self->{mode} |= $MODE_COMMAND;
    $self->{readplus} = $self->{plustime} = 0;
    ATduck::Main->debug(1, $self, 'Suspended');
    $self->_reply(undef, 'OK', undef);
}

sub receive {
    # Read from the carrier and forward over the serial port
    my ($self) = @_;
    my $c = $self->carrier;
    return unless $c;
    my $buf = $c->read(512);
    return $self->hangup() unless defined($buf); # FIXME: undefined buffer
    return unless $self->online_mode;
    ATduck::Main->tracestream($self, 1, 0, $buf);
    $self->serial->write($buf);
}

sub _reply {
    my ($self, $text, $code, $suffix) = @_;
    my $reply = '';
    if ( defined($text) ) {
        $reply .= "\r\n" if $self->{verbose};
        $reply .= "$text\r\n";
    }

    # Table 3/V.250 – Effect of V parameter on response formats
    #                       V0                 V1
    # Information responses <text><cr><lf>     <cr><lf><text><cr><lf>
    # Result codes          <numeric code><cr> <cr><lf><verbose code><cr><lf>

    if ( $code and !$self->{quiet} ) {
        $code =~ s/\s*\d+$// unless $self->{verbose} and $self->{smartmodem};
        if ( $self->{verbose} ) { $reply .= "\r\n$code\r\n" }
        else {
            $reply .= (exists($numerics{$code})?$numerics{$code}:99)."\r";
        }
    }
    $reply .= "$suffix\r\n" if defined($suffix);
    # Get values for \r and \n from registers.
    $reply =~ s/(\r|\n)/chr(($1 eq "\r")?$self->reg(3):$self->reg(4))/eg;
    ATduck::Main->tracereply($self, 1, $reply);
    $self->serial->write($reply) if $self->serial;
}

# Receive an incoming call
sub ring {
    my ($self, $carrier) = @_;
    return undef if $self->is_busy;
    $self->{carrier} = $carrier;
    $self->{mode} = $MODE_COMMAND|$MODE_PENDING;
    $self->_ring();
    return 1;
}

# Send ring to modem
sub _ring {
    my ($self) = @_;
    return unless $self->{carrier} and $self->is_receiving;

    my $ringnum = $self->reg(1)+1;
    $self->reg(1, $ringnum); # S1: Ring counter

    my $callerid = undef;
    $callerid = $self->_callerid($self->{sendcid}-1)
        if $self->{sendcid} and $ringnum <= 1;

    $self->_reply(undef, 'RING', $callerid);

    if ( $self->reg(0) && ($self->reg(1) >= $self->reg(0)) ) {
        # Autoanswer
        $self->_reply(@{$self->_connect()});
        return;
    }
    ATduck::EventLoop->after($ring_cadence, sub { $self->_ring() });
}

sub _connect {
    my ($self, $carrier) = @_;
    $self->{carrier} = $carrier if defined($carrier);
    if ( $self->{carrier}->online ) {
        $self->{mode} = $MODE_ONLINE; # Clear all pending and command states
        $self->{carrier}->connected();
        return [undef, "CONNECT $rate", undef];
    }
    else { # Carrier is not online, we must wait for it
        $self->{mode} = $MODE_PENDING;
        return [undef, '', undef];
    }
}

sub poll_outgoing {
    my ($self) = @_;
    return unless $self->{carrier} and $self->is_placing;
    $self->_reply(@{$self->_connect()}) if $self->{carrier}->online;
}

sub hangup {
    my ($self) = @_;
    $self->{carrier} = undef;
    $self->_reply(undef, 'NO CARRIER', undef) if $self->online_mode;
    $self->{mode} = $MODE_COMMAND;
}

# Commands

sub A {
    my ($self, $arg) = @_;
    return [undef, 'NO CARRIER', undef] unless $self->{carrier} and
        $self->is_receiving;
    return $self->_connect();
}

sub D {
    my ($self, $arg) = @_;
    return ERROR if $self->is_busy;
    my $carrier = ATduck::DialPlan->lookup($arg);
    return [undef, 'NO DIALTONE', undef] unless $carrier and $carrier->{type};
    $self->{mode} = $MODE_PENDING;
    eval {
        $carrier = "ATduck::Carrier::$carrier->{type}"->new($self, $carrier);
        1;
    } or return [undef, 'NO ANSWER', undef];
    if ( !$carrier ) {
        $self->{mode} = $MODE_COMMAND;
        return [undef, 'BUSY', undef];
    }
    return $self->_connect($carrier);
}

sub E {
    my ($self, $arg) = @_;
    return ERROR if $arg and ( $arg < 0 or $arg > 1 );
    $self->{echo} = $arg ? $arg : 0;
    return OK;
}

sub H {
    my ($self, $arg) = @_;
    return ERROR if $arg;
    $self->hangup();
    return OK;
}

sub I {
    my ($self, $arg) = @_;
    return [ATduck::Main->info($arg), 'OK', undef];
}

sub O {
    my ($self, $arg) = @_;
    return ERROR if $arg;
    return [undef, 'NO CARRIER', undef] unless $self->is_online;
    return $self->_connect();
}

sub Q {
    my ($self, $arg) = @_;
    return ERROR if $arg and ( $arg < 0 or $arg > 1 );
    $self->{quiet} = $arg ? $arg : 0;
    return OK;
}

sub S {
    my ($self, $reg, $arg) = @_;
    my $out = $self->reg($reg, $arg);
    return [defined($arg) ? undef : $out, 'OK', undef];
}

sub V {
    my ($self, $arg) = @_;
    return ERROR if $arg and ( $arg < 0 or $arg > 1 );
    $self->{verbose} = $arg ? $arg : 0;
    return OK;
}

sub X {
    my ($self, $arg) = @_;
    return ERROR if $arg and ( $arg < 0 or $arg > 4 );
    $self->{smartmodem} = $arg ? $arg : 0;
    return OK;
}

sub Z {
    my ($self, $arg) = @_;
    $self->hangup();
    $self->init();
    return OK;
}

sub FCLASS {
    my ($self, $mode, $arg) = @_;
    return ['+FCLASS: 0', 'OK', undef] if $mode == EXT_HELP;
    return [$self->{serviceclass}, 'OK', undef] if $mode == EXT_QUERY;
    return ERROR if $arg < 0 or $arg > 0;
    $self->{serviceclass} = $arg;
    return OK;
}

sub GCAP {
    my ($self, $mode, $arg) = @_;
    return OK if $mode == EXT_HELP;
    return ERROR if $mode != EXT_QUERY;
    return ['+GCAP: +FCLASS', 'OK', undef];
}

sub GMI {
    my ($self, $mode, $arg) = @_;
    return OK if $mode == EXT_HELP;
    return ERROR if $mode != EXT_QUERY;
    return ["nandhp\r\nnandhp\@gmail.com", 'OK', undef];
}

sub GMM {
    my ($self, $mode, $arg) = @_;
    return OK if $mode == EXT_HELP;
    return ERROR if $mode != EXT_QUERY;
    return ['FIXME', 'OK', undef];
}

sub GMR {
    my ($self, $mode, $arg) = @_;
    return OK if $mode == EXT_HELP;
    return ERROR if $mode != EXT_QUERY;
    return ['FIXME', 'OK', undef];
}

sub GSN {
    my ($self, $mode, $arg) = @_;
    return OK if $mode == EXT_HELP;
    return ERROR if $mode != EXT_QUERY;
    return [$self->id, 'OK', undef];
}

sub VCID {
    my ($self, $mode, $arg) = @_;
    return ['+VCID: (0,1,2)', 'OK', undef] if $mode == EXT_HELP;
    return [$self->{sendcid}, 'OK', undef] if $mode == EXT_QUERY;
    return ERROR if $arg < 0 or $arg > 2;
    $self->{sendcid} = $arg;
    return OK;
}

sub VRID {
    my ($self, $mode, $arg) = @_;
    return ['(0,1)', 'OK', undef] if $mode == EXT_HELP;
    return ERROR if $arg < 0 or $arg > 1;
    # Fetch Caller ID
    return OK unless $self->{carrier};
    return [$self->_callerid($arg), 'OK', undef];
}

my %commands = (
    'A' =>          [  NO_ARG, \&A],    # Answer incoming call (V.250)
    'B' =>          [ OPT_ARG, undef],  # Bell mode (Most modems ignore)
    # C
    'D' =>          [DIAL_ARG, \&D],    # Dial (V.250)
    'E' =>          [ OPT_ARG, \&E],    # Echo of commands (V.250)
    # F
    # G
    'H' =>          [ OPT_ARG, \&H],    # Hangup (V.250)
    'I' =>          [ OPT_ARG, \&I],    # Identify (V.250)
    # J
    # K
    'L' =>          [ OPT_ARG, undef],  # Speaker loudness (V.250)
    'M' =>          [ OPT_ARG, undef],  # Speaker mute (V.250)
    'N' =>          [ OPT_ARG, undef],  # Require handshake speed S37
    'O' =>          [ OPT_ARG, \&O],    # Switch to online mode (V.250)
    'P' =>          [  NO_ARG, undef],  # Default to pulse dialing (V.250)
    'Q' =>          [ OPT_ARG, \&Q],    # Quiet; no response codes (V.250)
    # R
    'S' =>          [SREG_ARG, \&S],    # S-Register (V.250)
    'T' =>          [  NO_ARG, undef],  # Default to tone dialing (V.250)
    # U
    'V' =>          [ OPT_ARG, \&V],    # Verbose text responses (V.250)
    'W' =>          [  NO_ARG, undef],  # Negotiation progress messages (FIXME)
    'X' =>          [ OPT_ARG, \&X],    # Smartmodem call status detail (V.250)
    # Y
    'Z' =>          [ OPT_ARG, \&Z],    # Reset to defaults (V.250)
    '&C' =>         [ OPT_ARG, undef],  # Carrier Detect (V.250)
    '&D' =>         [ OPT_ARG, undef],  # Data Terminal Ready (V.250)
    '&F' =>         [ OPT_ARG, \&Z],    # Reset to factory defaults (V.250)
    '&K' =>         [ OPT_ARG, undef],  # Flow control
    '\Q' =>         [ OPT_ARG, undef],  # Flow control
    '+FCLASS' =>    [ EXT_ARG, \&FCLA], # Service class: fax/data/.... (T.31)
    '+FMI' =>       [ EXT_ARG, \&GMI],  # Identify manufacturer (T.31)
    '+FMM' =>       [ EXT_ARG, \&GMM],  # Identify model (T.31)
    '+FMR' =>       [ EXT_ARG, \&GMR],  # Identify revision (T.31)
    '+FSN' =>       [ EXT_ARG, \&GSN],  # Product serial number (T.31)
    '+GCAP' =>      [ EXT_ARG, \&GCAP], # Get capabilities list (V.250)
    '+GMI' =>       [ EXT_ARG, \&GMI],  # Identify manufacturer (V.250)
    '+GMM' =>       [ EXT_ARG, \&GMM],  # Identify model (V.250)
    '+GMR' =>       [ EXT_ARG, \&GMR],  # Identify revision (V.250)
    '+GSN' =>       [ EXT_ARG, \&GSN],  # Product serial number (V.250)
    '+VCID' =>      [ EXT_ARG, \&VCID], # Automatic Caller ID (V.253)
    '+VRID' =>      [ EXT_ARG, \&VRID], # Repeat Caller ID (V.253)
    '#CID' =>       [ EXT_ARG, \&VCID], # Automatic Caller ID (alternate)
);

sub _command {
    my ($self, $str) = @_;
    $str =~ s/^AT\s*//i;
    my @reply = @{&OK};
    while ( $str and $reply[1] eq 'OK' ) {
        my $command = uc $1
            if $str =~ s/^\s*([&\\]?[A-Z]|[+@#][-:\/._%!0-9A-Z]+)\s*//i;
        unless ( $command and exists($commands{$command}) )
            { $reply[1] = 'ERROR'; last }
        my ($argtype, $func) = @{$commands{$command}};

        # Parse any arguments to the command
        my @args = ();
        # Command takes no arguments. Do nothing, extra arguments cause error
        # on next loop.
        if ( $argtype == NO_ARG ) { }
        # Command takes optional (digit) argument.
        elsif ( $argtype == OPT_ARG ) {
            $args[0] = ($1+0) if $str =~ s/^(\d+)//;
        }
        # D takes a special argument format: Everything up to semicolon or
        # end-of-line.
        elsif ( $argtype == DIAL_ARG ) {
            $str =~ s/^(.*?)(?:;|$)// and $args[0] = $1;
        }
        # S takes a special argument format: Either a number and a question
        # mark; or a number, equals sign, and another number.
        elsif ( $argtype == SREG_ARG ) {
            if ( $str =~ s/^(\d+)(?:\?|=(\d*))// ) {
                $args[0] = $1+0;
                if ( defined($2) ) { $args[1] = $2 ? ($2+0) : 0 }
            }
            else { $reply[1] = 'ERROR'; last } # Syntax error
        }
        # Commands beginning with + or # use a special argument format
        # defined in V.250.
        elsif ( $argtype == EXT_ARG ) {
            if ( $str =~ s/^=\s*(?:"([^"]+)"|([^;"]*))\s*(?:;|$)// ) {
                if ( $2 and ($2 eq '?') ) { $args[0] = EXT_HELP }
                else {
                    $args[0] = EXT_SET;
                    $args[1] = $1 ? $1 : ( $2 ? ($2+0) : 0);
                }
            }
            else { $str =~ s/^\?//; $args[0] = EXT_QUERY }
        }
        # Command takes an unknown argument format. This is an serious error
        # in the program.
        else { die }

        # Run the command handler function, if defined.
        next unless defined($func);
        my $rc = $self->$func(@args);
        # Update the reply with the return value of the function.
        $reply[1] = $rc->[1];
        foreach ( 0, 2 )
            { $reply[$_] = ($reply[$_]||'').$rc->[$_] if defined($rc->[$_]) }
    }
    $self->_reply(@reply);
}

# Caller ID (badly ported from previous-generation ATduck)

# Generate SDMF or MDMF Caller ID message
sub _callerid_pack {
    my ($mdmf, $info) = @_;
    # SDMF/MDMF Overview (More details in ETSI 659 "Subscriber line protocol
    #   over the local loop for display (and related) services", 2001-2004)
    #
    # SDMF format (Plain Caller ID):
    #   04XX      Denotes SDMF format and length of message (char, not ASCII)
    #     MMMMDDDDHHHHMMMM
    #             Month, day, hour, minute (8 bytes: Two ASCII digits each)
    #     NN...   Phone number, or 'O' = Out of area, 'P' = Private caller
    #   CC        Checksum
    #
    # MDMF format (Caller ID with Name):
    #   80XX      Denotes MDMF format and length of message (char, not ASCII)
    #     TTLL    Data segment type and length (char, not ASCII)
    #     XX...   Data segment data
    #     ...     Additional data segments
    #   CC        Checksum
    #
    # MDMF data types:
    #   01        Date and time, encoded as in SDMF
    #   02        Phone number
    #   04        Number unavailable: 'O' = Out of area, 'P' = Private caller
    #   07        Name
    #   08        Name unavailable:   'O' = Out of area, 'P' = Private caller
    #
    # Checksum format: twos complement of the mod-256 sum of data
    my $data = '';
    my ($date,$time) = _callerid_datetime($info);
    my ($number, $name) = ($info->{number}||'O', $info->{name}||'O');
    if ( $mdmf ) {
        $data .= chr(1).chr(8).$date.$time;
        if ( !$number or $number eq 'O' or $number eq 'P' )
            { $data .= chr(4).chr(1).$number } # Phone number unavailable
        else { $data .= chr(2).chr(length($number)).($number||'O') }
        if ( !$name or $name eq 'O' or $name eq 'P' )
            { $data .= chr(8).chr(1).$name } # Name unavailable
        else { $data .= chr(7).chr(length($name)).($name||'O') }
    }
    else { $data .= $date.$time.($number||'O') } # SDMF
    $data = chr($mdmf?0x80:0x04).chr(length($data)).$data;
    my $datastr = '';
    my $cksum = 0;
    for ( my $i = 0; $i < length($data); $i++ ) {
        my $c = ord(substr($data, $i, 1));
        $cksum += $c;
        $datastr .= sprintf("%x", $c);
    }
    return $datastr.sprintf("%02x",(-($cksum%256))&0xff);
}
sub _callerid_datetime { # Return the current time, formatted for Caller ID
    my ($info) = @_;
    my ($sec,$min,$hr,$day,$mon) = localtime($info->{starttime}||time);
    return (sprintf("%02d%02d", $mon+1, $day), sprintf("%02d%02d", $hr, $min));
}
sub _callerid { # Format Caller ID for sending
    my ($self, $raw) = @_;
    if ( $self->{carrier} ) {
        if ( $raw )
            { return 'MESG='._callerid_pack(1,$self->{carrier}) }
        my ($date,$time) = _callerid_datetime($self->{carrier});
        my ($number, $name) = ($self->{carrier}->{number}||'O',
                               $self->{carrier}->{name}||'O');
        return "DATE = $date\r\nTIME = $time\r\nNMBR = $number\r\nNAME = $name";
    }
    return '';
}

# Accessors, etc.

sub serial {
    my ($self) = @_;
    return $self->{serial};
}

sub carrier {
    my ($self) = @_;
    return $self->{carrier};
}

sub id {
    my ($self, $value) = @_;
    $self->{id} = $value if $value;
    return $self->{id};
}

sub command_mode {
    my ($self) = @_;
    return ($self->{mode} & $MODE_COMMAND) ? 1 : 0;
}

sub online_mode {
    my ($self) = @_;
    return ($self->{mode} == $MODE_ONLINE) ? 1 : 0;
}

sub is_online {
    my ($self) = @_;
    return ($self->{mode} & $MODE_ONLINE) ? 1 : 0;
}

sub is_receiving {
    my ($self) = @_;
    return (($self->{mode} & $MODE_COMMAND) &&
            ($self->{mode} & $MODE_PENDING)) ? 1 : 0;
}

sub is_placing {
    my ($self) = @_;
    return (!($self->{mode} & $MODE_COMMAND) &&
            ($self->{mode} & $MODE_PENDING)) ? 1 : 0;}

sub is_busy {
    my ($self) = @_;
    return ($self->{mode} & ($MODE_ONLINE|$MODE_PENDING)) ? 1 : 0;
}


sub reg {
    my ($self, $reg, $value) = @_;
    if ( defined($value) ) { $self->{reg}[$reg] = $value }
    elsif ( $reg > @{$self->{reg}} ) { return 0 }
    return $self->{reg}[$reg]||0;
}

sub DESTROY {
    my ($self) = @_;
    $self->hangup();
}
1;
