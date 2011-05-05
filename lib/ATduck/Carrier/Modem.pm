package ATduck::Carrier::Modem;
# This file is part of ATduck
use ATduck::Carrier;
use warnings;
use strict;

our @ISA = qw(ATduck::Carrier);

sub new {
    my ($class, $modem, $arg) = @_;
    my $self = $class->SUPER::new($arg);
    bless($self, $class);
    if ( $self->{input} ) {
        $self->{modem} = ATduck::EventLoop->find_modem_by_id($self->{input});
    }
    return undef unless $self->{modem};
    $self->{reader} = $self->{modem}->serial->reader;
    $self->{writer} = $self->{modem}->serial->writer;

    # Create a second carrier, and attach to the remote
    if ( $modem ) {
        my $c = { modem => $modem, name => $modem->{name},
                  number => $modem->{number} };
        my $rc = $self->{modem}->ring($class->new(undef, $c));
        return undef unless $rc;
    }
    return $self;
}

sub online {
    my ($self) = @_;
    return $self->{modem}->is_online || $self->{modem}->is_placing;
}

sub connected {
    my ($self) = @_;
    # How to make dialing modem connect?
    $self->{modem}->poll_outgoing();
}

sub write {
    my ($self, @args) = @_;
    # Don't write if other modem is not online
    return unless $self->{modem}->online_mode;
    return $self->SUPER::write(@args);
}

sub DESTROY {
    my ($self) = @_;
    my $m = $self->{modem};
    $self->{modem} = undef;
    $m->hangup() if $m;
}
