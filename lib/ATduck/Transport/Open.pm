package ATduck::Transport::Open;
# This file is part of ATduck
use ATduck::Transport;
use warnings;
use strict;

our @ISA = qw(ATduck::Transport);

ATduck::Main->install_transport(__PACKAGE__, 'OPEN', 'GOPEN');

sub new_client {
    my $class = shift @_;
    my $self = $class->SUPER::new_client(@_);
    bless($self, $class);
    my $sock = $self->{reader} || $self->{writer};
    if ( !$sock ) {
        open $sock, '+<', $self->{file}
            or die "Can't open $self->{file}: $!\n";
    }
    $self->register($sock);
    return $self;
}

sub new_server { die "This transport cannot be used as a listener\n" }

sub parse {
    my ($self, $str) = @_;
    return { file => $str };
}

sub detect {
    my ($self, $str) = @_;
    return 100 if -c $str;
    return   0;
}

sub accept { die }

1;
