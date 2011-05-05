package ATduck::EventLoop;
# This file is part of ATduck

=head1 NAME

ATduck::EventLoop - Event loop for ATduck

=head1 DESCRIPTION

This module contains the main event loop for ATduck.

=head1 UTILITY METHODS

=cut

use Time::HiRes;
use IO::Select;
use POSIX qw(:sys_wait_h);
use threads;
use threads::shared;
use warnings;
use strict;

my @modems = ();
my @listeners = ();
my @events = ();
my $zombies = 0;

my $select = IO::Select->new();

my $minwait = 0.125; # Minimal time to wait on select loop

=head2 main()

ATduck's main event loop. Handles modems, listeners, timer events, and
zombie subprocesses.

=cut

sub main {
    my ($self) = @_;
    # Set up event handlers. We want these to be very simple.
    local $SIG{CHLD} = sub { $zombies++ };
    local $SIG{INT} = sub { $self->_quit(); exit };
    local $SIG{PIPE} = 'IGNORE'; # Don't crash
    # Turn on autoflush.
    local $| = 1;
    # The main outer loop. Continue until we have nothing left to do.
    while ( @modems || @listeners ) {
        # Find our next event
        my $wait = undef;
        if ( @events ) {
            $wait = Time::HiRes::time - $events[0]{when};
            $wait = $minwait if $wait < $minwait;
        }

        # Run the select loop
        foreach my $fh ( $select->can_read($wait) ) {
            #last if $urgent_timer;
            # Maybe this is a Modem's serial port?
            my $modem = ATduck::EventLoop->find_modem_by_serial_reader($fh);
            if ( $modem ) { $modem->ready(); next }
            # Maybe this is a Modem's carrier?
            $modem = ATduck::EventLoop->find_modem_by_carrier_reader($fh);
            if ( $modem ) { $modem->receive(); next }
            # Maybe it's not a modem, but a listener?
            $modem = ATduck::EventLoop->find_listener_by_listener($fh);
            if ( $modem ) { ATduck::Modem->new($modem->accept()); next }
            # Or maybe something's wrong?
            die
        }

        # Run all timers that are ready
        while ( @events and Time::HiRes::time >= $events[0]{when} ) {
            my $event = shift @events;
            # Dispatch event
            &{$event->{callback}}();
        }
        # Reap zombies separately. This isn't a proper event handler since
        # we want to minimize the job of the _catch_zombie signal handler.
        ATduck::EventLoop->_reap_zombies() if $zombies;
    }
    $self->_quit();
}

# Zombie reaping event handler
sub _reap_zombies {
    my ($self) = @_;
    $zombies = 0;
    while ( (my $pid = waitpid(-1, WNOHANG)) != -1 ) {
        my $m = $self->find_modem_by_carrier_pid($pid);
        next unless $m;
        $m->hangup();
    }
}

# Quit cleanup handler, to avoid relying entirely on garbage collection
sub _quit {
    my ($self) = @_;
    $self->remove_modem($modems[0]) while @modems;
}


=head1 MODEM MANAGEMENT

=head2 add_modem($modem)

Assign an ID to the modem and add it to the event loop.

=cut

sub add_modem {
    my ($self, $modem) = @_;
    my $id = 1;
    foreach ( @modems ) {
        last if $_->{id} > $id;
        $id++;
    }
    $modem->id($id);
    push @modems, $modem;
    $self->register_fh($modem->serial->reader);
    return $id;
}

sub remove_modem {
    my ($class, $modem ) = @_;
    my $id = $modem->id;
    for ( my $i = 0; $i < @modems; $i++ ) {
        next unless $id eq $modems[$i]->id;
        splice(@modems, $i, 1);
        last;
    }
}

sub find_modem_by_serial_reader {
    my ($class, $fh) = @_;
    foreach my $m ( @modems ) {
        return $m if $m->serial->reader eq $fh;
    }
}

sub find_modem_by_carrier_reader {
    my ($class, $fh) = @_;
    foreach my $m ( @modems ) {
        my $c = $m->carrier;
        next unless $c;
        return $m if $c->reader eq $fh;
    }
}

sub find_modem_by_carrier_pid {
    my ($class, $pid) = @_;
    foreach my $m ( @modems ) {
        my $c = $m->carrier;
        next unless $c;
        return $m if exists($c->{pid}) and $c->{pid} == $pid;
    }
}

sub find_modem_by_id {
    my ($class, $id) = @_;
    foreach my $m ( @modems ) {
        return $m if $m->id == $id;
    }
}

# Need a plan...

sub modems {
    return \@modems;
}

=head1 LISTENER MANAGEMENT

=cut

sub add_listener {
    my ($self, $listener) = @_;
    push @listeners, $listener;
    $self->register_fh($listener->listener);
}

sub find_listener_by_listener {
    my ($class, $fh) = @_;
    foreach my $l ( @listeners ) {
        return $l if $l->listener eq $fh;
    }
}

=head1 FILEHANDLE MANAGEMENT

=cut

sub register_fh {
    my ($self) = shift;
    foreach ( @_ ) {
        $select->add($_);
    }
}

sub unregister_fh {
    my ($self) = shift;
    return unless $select; # Sometimes this doesn't exist during cleanup
    foreach ( @_ ) {
        $select->remove($_) if $select->exists($_);
    }
}

=head1 TIMER MANAGEMENT

=cut

=head2 ATduck::EventLoop->after($when, ...)

Set a timer to trigger after time seconds. Wrapper for at, below.

=cut

sub after {
    my ($self, $when, @args) = @_;
    $self->at(Time::HiRes::time + $when, @args);
}

=head2 ATduck::EventLoop->at($time, $callback)

Set a timer to trigger at this time. When triggered, run this callback.

=cut

sub at {
    my ($self, $when, $callback) = @_;
    my $i = 0;
    for ( $i = 0; $i < @events; $i++ ) {
        last if $events[$i]{when} > $when;
    }
    splice(@events, $i, 0, {when => $when, callback => $callback});
}

1;
