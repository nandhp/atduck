package ATduck::Transport::UNIX;
# This file is part of ATduck
use IO::Socket::UNIX;
use ATduck::Transport;
use warnings;
use strict;

our @ISA = qw(ATduck::Transport);

ATduck::Main->install_transport(__PACKAGE__, 'UNIX');

sub new_client {
    my $class = shift @_;
    my $self = $class->SUPER::new_client(@_);
    bless($self, $class);
    my $sock = $self->{reader} || $self->{writer};
    if ( !$sock ) {
        $sock = IO::Socket::UNIX->new(Peer => $self->{file})
            or die "Connecting to $self->{file}: $!\n";
    }
    $self->register($sock);
    return $self;
}

sub new_server {
    my $class = shift @_;
    my $self = $class->SUPER::new_server(@_);
    bless($self, $class);
    my $sock = IO::Socket::UNIX->new(Local => $self->{file}, Listen => 5)
        or die "Listening on $self->{file}: $!\n";
    $self->register_listener($sock);
    return $self;
}

sub parse {
    my ($self, $str) = @_;
    return { file => $str };
}

sub detect {
    my ($self, $str) = @_;
    return   0 if $str =~ m/^\\\\\.\\pipe\\/;
    return 100 if -S $str;
    return  10 if !-e $str;
    return   0;
}

sub accept {
    my ($self) = @_;
    my $sock = $self->{listener}->accept();
    return ref($self)->new_client({reader => $sock});
}

1;
