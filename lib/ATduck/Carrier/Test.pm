package ATduck::Carrier::Test;
use IO::Socket::INET;
use ATduck::IO;
use warnings;
use strict;

our @ISA = qw(ATduck::IO);

sub new {
    my ($class) = shift @_;
    my $self = $class->SUPER::new(@_);
    bless($self, $class);
    my $sock = IO::Socket::INET->new('localhost:5555') or die; # FIXME carp
    $self->register($sock);
    return $self;
}

1;
