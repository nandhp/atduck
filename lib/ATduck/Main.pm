package ATduck::Main;
# This file is part of ATduck

=head1 NAME

ATduck::Main - Main module for ATduck

=head1 DESCRIPTION

This module contains startup code and utility functions for ATduck.

=head1 UTILITY METHODS

=cut

use ATduck::EventLoop;
use ATduck::Modem;
use warnings;
use strict;

our $VERSION = 20110321;

# Info
my @info = (127001,                             # I0 Numeric identification
            0,                                  # I1 Display checksum
            '',                                 # I2 Verify checksum
            "ATduck $VERSION",                  # I3 Firmware revision
            "ATduck version $VERSION\r\n".      # I4 OEM string
            "Copyright (C) 2007-2011 nandhp <nandhp\@gmail.com>\r\n".
            "License GPLv2+: <http://www.gnu.org/licenses/gpl-2.0.html>\r\n".
            "This is open-source software; you may redistribute and/or\r\n".
            "modify it subject to certain conditions; see license.\r\n".
            "There is NO WARRANTY, to the extent permitted by law.",
           );


my %transports = ();
# Load transports, carriers
_load_plugins('Transport');
_load_plugins('Carrier');

=head2 ATduck::Main->install_transport($module, $name, ...)

Transport modules set up their "friendly name" in this hash.
For example, the ATduck::Transport::TCP4 module might do this:

  ATduck::Main->install_transport($module, $name, 'TCP4', 'TCP')

=cut

sub install_transport {
    my ($self, $module, @names) = @_;
    $transports{uc $_} = $module foreach @names;
}

# Search @INC and load all modules of the form ATduck::<realm>::<name>.
# Used to load all Transport and Carrier modules, thereby allowing plugins.
sub _load_plugins {
    my ($realm) = @_;
    foreach my $base ( @INC ) {
        my $dir = "$base/ATduck/$realm";
        next unless -d $dir;
        opendir(D, $dir) or next;
        foreach (readdir D) {
            next unless -f "$dir/$_";
            next unless $_ =~ m/^(.+)\.pm$/;
            require "$dir/$_";
        }
        closedir(D);
    }
}

=head2 ATduck::Main->parse_transport_address($str)

Determine which Transport module supports addresses as specified in $str,
and parse it.

Returns undef if parsing was not possible, or an array reference with the
first element being the module supporting the transport and the second element
being a hashref with the parsed form of the address.

=cut

sub parse_transport_address {
    my ($self, $str) = @_;
    my $type;
    # Check for a TYPE:whatever format
    if ( $str =~ m/^([A-Z0-9]+):(.+)$/i ) {
        ($type, my $rest) = (uc($1), $2);
        if ( exists($transports{$type}) ) { $str = $rest }
        else { $type = undef }
    }
    # If not, or there was but it wasn't valid, run each detect method on
    # the string. Choose the one that provided the highest confidence.
    if ( !$type ) {
        my $best = 0;
        foreach my $t ( keys %transports ) {
            my $confidence = $transports{$t}->detect($str);
            if ( $confidence > $best ) { $type = $t; $best = $confidence }
        }
    }
    # Return undef if detection or parsing failed.
    return undef unless $type;
    my $parsed = $transports{$type}->parse($str);
    return $parsed ? [ $transports{$type}, $parsed ] : undef;
}

=head2 ATduck::Main->info($index)

Return the value of the given I (Identify) command.

=cut

sub info {
    my ($self, $idx) = @_;
    return $info[$idx] if exists($info[$idx]);
    return undef;
}

# Debug output

=head1 DEBUG METHODS

=head2 $debuglevel

Debugging level: 0 = no debugging messages,
1 = Status messages and modem commands,
2 = Show transferred data.

=cut

our $debuglevel = 1;
my $debugprefix = '';

=head2 ATduck::Main->debug($level, $modem, $message)

Display $message as a debugging message from $modem with level $level
(see $debuglevel).

=cut

sub debug {
    my ($self, $level, $modem, $message) = @_;
    return if $level > $debuglevel;
    $self->_debugprefix('') if $debugprefix;
    if ( $modem ) { printf("[%1d] %s\n", $modem->id, $message) }
    else { print $message,"\n" }
}

=head2 ATduck::Main->tracestream($modem, $send, $command, $print)

Log $print as session data tracing for $modem,
either being sent ($send) or received, as a command ($command) or data.

Consecutive messages with the same $modem, $send, $command will be combined
onto a single line.

=cut

sub tracestream {
    my ($self, $modem, $send, $command, $print) = @_;
    return if 2-$command > $debuglevel;
    my $prefix = sprintf("[%d] %s ", $modem->id, _debugprefixarrow($send));
    $self->_debugprefix($prefix);
    if ( $command ) {
        $print =~ s/\n(?!$)/\n$debugprefix/g;
        $print =~ s/\r//g;
        $print =~ s/([^\n])/_printable($1)/eg;
    }
    else { $print =~ s/(.)/_printable($1)/egs }
    print $print;
}

=head2 ATduck::Main->tracereply($modem, $send, $str)

Log $str as session data tracing for $modem,
either being sent ($send) or received.

Multiple lines in a single message will be displayed as separate lines.

=cut

sub tracereply {
    my ($self, $modem, $send, $str) = @_;
    return if 1 > $debuglevel;
    $self->_debugprefix('') if $debugprefix;
    $str =~ s/(^\r?\n|\r?\n$)//g;
    my $prefix = sprintf("[%d] %s ", $modem->id, _debugprefixarrow($send));
    $str =~ s/\n/\n$prefix/g;
    print "$prefix$str\n";
}

sub _debugprefix {
    my ($self, $prefix) = @_;
    return if $debugprefix eq $prefix;
    print "\n" if $debugprefix;
    print $prefix;
    $debugprefix = $prefix;
}

sub _debugprefixarrow {
    my ($send) = @_;
    return '<' if $send > 0;
    return '>' unless $send;
    return ' ';
}

sub _printable {
    my ($char) = @_;
    return $char unless $char;
    my $c = ord $char;
    return sprintf("<%02x>",$c) if $c < 32 or $c > 126;
    return $char;
}

1;
