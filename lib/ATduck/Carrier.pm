package ATduck::Carrier;
# This file is part of ATduck
use ATduck::IO;
use warnings;
use strict;

our @ISA = qw(ATduck::IO);

sub new {
    my $class = shift @_;
    my $self = $class->SUPER::new(@_);
    $self->{starttime} = time; # For Caller ID
    # Don't bless ourself into a class, since we don't actually do anything
    # (ATduck::Carrier can only be subclassed, not instantiated)
    return $self;
}

sub online { return 1 }

sub connected { return }

1;
