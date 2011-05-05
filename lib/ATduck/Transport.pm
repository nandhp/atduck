package ATduck::Transport;
# This file is part of ATduck
use ATduck::IO;
use warnings;
use strict;

our @ISA = qw(ATduck::IO);

sub new_client {
    my $class = shift @_;
    my $self = $class->SUPER::new(@_);
    # Don't bless ourself into a class, since we don't actually do anything
    # (ATduck::Transport can only be subclassed, not instantiated)
    return $self;
}

sub new_server {
    my $class = shift @_;
    my $self = $class->SUPER::new(@_);
    # Don't bless ourself into a class, since we don't actually do anything
    # (ATduck::Transport can only be subclassed, not instantiated)
    return $self;
}

1;
