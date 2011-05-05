package ATduck::IO;
# This file is part of ATduck
use warnings;
use strict;

sub new {
    my ($class, $opts) = @_;
    my $self = $opts ? { %{$opts} } : {};
    # Don't bless ourself into a class, since we don't actually do anything
    # (ATduck::IO can only be subclassed, not instantiated)
    return $self;
}

sub register {
    my ($self, $reader, $writer) = @_;
    $writer = $reader if @_ < 3;
    $self->unregister();
    ATduck::EventLoop->register_fh($reader);
    $self->{reader} = $reader;
    $self->{writer} = $writer;
}

sub register_listener {
    my ($self, $listener) = @_;
    $self->unregister();
    ATduck::EventLoop->register_fh($listener);
    $self->{listener} = $listener;
}

sub unregister {
    my ($self) = @_;
    ATduck::EventLoop->unregister_fh($self->{reader}) if $self->{reader};
    ATduck::EventLoop->unregister_fh($self->{listener}) if $self->{listener};
    $self->{reader} = $self->{writer} = $self->{listener} = undef;
}

sub reader {
    my ($self, $arg) = @_;
    return $self->{reader};
}

sub writer {
    my ($self) = @_;
    return $self->{writer};
}

sub listener {
    my ($self) = @_;
    return $self->{listener};
}

sub write {
    my ($self, $buf) = @_;
    if ( 0 ) {
        my $c = join(' ', map { ord } split '', $buf);
        ATduck::Main->debug(1, undef, fileno($self->{writer}).' Out '.$c);
    }
    return syswrite($self->{writer}, $buf);
}

sub read {
    my ($self, $size) = @_;
    my $buf;
    my $rc = sysread($self->{reader}, $buf, $size);
    if ( 0 ) {
        my $c = join(' ', map { ord } split '', $buf);
        ATduck::Main->debug(1, undef, fileno($self->{writer}).' In  '.$c);
    }
    return $rc ? $buf : undef;
}

sub DESTROY {
    my ($self) = @_;
    ATduck::Main->debug(1,undef,'DESTROYING IO OBJECT '.ref($self));
    $self->unregister();
    close($self->{writer}) if $self->{writer};
    close($self->{reader}) if $self->{reader};
}

1;
