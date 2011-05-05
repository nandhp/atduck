package ATduck::Carrier::Shell;
# This file is part of ATduck
use POSIX;
use IO::Pty;
use IPC::Open2;
use ATduck::Carrier;
use warnings;
use strict;

our @ISA = qw(ATduck::Carrier);

sub new {
    my ($class, $modem, $arg) = @_;
    my $self = $class->SUPER::new($arg);
    bless($self, $class);

    # Set up subprocess environment
    $self->_pty() if $self->{usepty};
    local $ENV{M_RATE} = $ATduck::Modem::rate;
    local $ENV{SLIRP_TTY} = local $ENV{M_TTYPATH} =
        $self->_pty('path') if $self->{pty};
    local $ENV{M_TTYNAME} = $self->_pty('name') if $self->{pty};
    local $ENV{TERM} = 'vt100';
    $self->{pid} = open2($self->{readpipe}, $self->{writepipe},
                         'sh', '-c', $self->{data});
    # Check that open2 succeeded
    return undef unless $self->{pid};
    # Set up filehandles
    if ( $self->{pty} ) { $self->register($self->{pty}) }
    else { $self->register($self->{readpipe}, $self->{writepipe}) }

    return $self;
}

# Allocate a PTY to use instead of STDIN/STDOUT
sub _pty {
    my ($self, $flag) = @_;
    if ( !$self->{pty} ) {
        $self->{pty} = new IO::Pty;
        # Turn off echo and other unplesantness.
        # Required on cygwin because subprocesses have incredible overhead,
        # and by the time SLiRP finally gets around to setting up the PTY,
        # the dialer may have already received the CONNECT response, started
        # sending data, received echoed data back, and given up on account
        # of "line echo".
        #
        # So let's just avoid that. The settings below are from SLiRP.
        my $termios = POSIX::Termios->new();
        my $fileno = fileno($self->{pty});
        $termios->getattr($fileno);
        # Note: fileno might be zero, but we don't expect to fiddle with STDIN.
        if ( $fileno && $termios ) {
            $termios->setiflag(0);
            $termios->setoflag(0);
            $termios->setlflag(0);
            $termios->setcc(&POSIX::VMIN, 1);
            $termios->setcc(&POSIX::VTIME, 0);
            $termios->setattr($fileno, &POSIX::TCSANOW);
        }
        # FIXME debug
        #info($m, 'Allocated Terminal: '.$m->{carrier}{pty}->ttyname());
    }
    return unless $flag;
    my $fn = $self->{pty}->ttyname();
    $fn =~ s/^\/dev\/// if $flag eq 'name';
    return $fn;
}

sub DESTROY {
    my ($self) = @_;
    $self->SUPER::DESTROY(@_);
    # Also close non-registered file handles
    foreach ( qw/readpipe writepipe pty/ ) {
        close($self->{$_}) if $self->{$_};
    }
    # Also kill child process
    if ( $self->{pid} > 1 ) {
        local $SIG{CHLD} = 'IGNORE';
        kill 15, $self->{pid} foreach 'SIGHUP', 'SIGINT';
        waitpid $self->{pid}, 0; # FIXME: What if this takes a long time?
    }
}

1;
