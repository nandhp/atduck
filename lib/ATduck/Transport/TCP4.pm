package ATduck::Transport::TCP4;
# This file is part of ATduck
use IO::Socket::INET;
use ATduck::Transport;
use warnings;
use strict;

our @ISA = qw(ATduck::Transport);

ATduck::Main->install_transport(__PACKAGE__, 'TCP4', 'TCP');

sub new_client {
    my $class = shift @_;
    my $self = $class->SUPER::new_client(@_);
    bless($self, $class);
    my $sock = $self->{reader} || $self->{writer};
    if ( !$sock ) {
        $sock = IO::Socket::INET->new
            (PeerAddr => $self->{host}, PeerPort => $self->{port})
            or die "Connecting to $self->{host}:$self->{port}: $!\n";
    }
    $self->register($sock);
    return $self;
}

sub new_server {
    my $class = shift @_;
    my $self = $class->SUPER::new_server(@_);
    bless($self, $class);
    my $sock = IO::Socket::INET->new
        (LocalAddr => $self->{host}, LocalPort => $self->{port}, Listen => 5,
         Reuse => 1) or die "Listening on $self->{host}:$self->{port}: $!\n";
    $self->register_listener($sock);
    return $self;
}

sub parse {
    my ($self, $str) = @_;
    $str =~ m/^\s*(?:([^:]*)\s*:\s*)?(\d+)\s*$/ or return undef;
    return { host => $1||'localhost', port => $2+0 };
}

sub detect {
    my ($self, $str) = @_;
    return 100 if $str =~ m/^([^\/: ,]*:)?\d+$/;
    return  50 if $str =~ m/^\s*\d+\s*$/;
    return   0;
}

sub accept {
    my ($self) = @_;
    my $sock = $self->{listener}->accept();
    return ref($self)->new_client({reader => $sock});
}

1;
