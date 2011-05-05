package ATduck::DialPlan;
# This file is part of ATduck

use warnings;
use strict;

# Load phonebook
my @phonebook = ();
while (<DATA>) {
    next if m/^(;|#|$)/;
    if ( m/^\s*(?:\[(.+)\]|\<(.+)\>)\s*(.*?)\s*$/ ) {
        my $mode = $1 ? 'prefix' : 'suffix';
        my ($pattern, $params) = ($1||$2, $3);
        if ( $mode eq 'suffix' ) { # Convert suffix-glob to regexp [FIXME]
            $pattern =~ s/[^0-9?]//g;
            $pattern =~ s/(\?+)/'('.('.' x length($1)).')'/ge;
        }
        my $h = { match => $pattern, matchmode => $mode, data => '' };
        while ( $params =~ m/\s*([a-zA-Z0-9_]+)(=(\S*))?/g )
            { $h->{$1} = $2 ? $3 : 1 }
        push @phonebook, $h;
    }
    else { $phonebook[-1]{data} .= $_ }
}
# Sort the phonebook so that prefixes come before suffixes
# and longer matches come before shorter ones.
@phonebook = sort { ($a->{matchmode} cmp $b->{matchmode}) ||
                    (length($b->{match}) <=> length($a->{match})) } @phonebook;

# Parse number based on dialing plan
sub lookup {
    my ($self, $str, $nleft) = @_;
    (my $filtered = $str) =~ s/\D//g;
    $nleft = 10 unless defined($nleft);
    return if $nleft < 0;

    # Check phonebook
    my $return = undef;
    foreach my $c ( @phonebook ) {
        next unless exists($c->{match});
        # Prefix match (for special handling of the entire dialing string)
        if ( ($c->{matchmode} eq 'prefix') and
             ($str =~ m/^([^0-9A-D]*)$c->{match}(.+)$/) ) {
            #(my $prefix,$input) = ($1,$2);
            #$input =~ s/^[\s,W]*/$prefix/; # Remove leading wait characters
            $return = { %{$c}, input => $1.$2,
                        inprefix => $1, insuffix => $2 }; # Duplicate
            last;
        }
        # Suffix match (for simple dispatch using phonebook entries)
        elsif( ($c->{matchmode} eq 'suffix') and
               ($filtered =~ m/($c->{match})$/) ) {
            $return = { %{$c}, input => ($2||$1) }; # Duplicate
            last;
        }
    }
    if ( $return->{type} eq 'Alias' ) {
        $return = $self->lookup($return->{target}, $nleft-1);
    }
    return $return;
}

sub reverse {
    my ($self, $type, $input) = @_;
    my ($name,$number) = ('O','O');
    foreach my $e ( @phonebook ) {
        next unless exists($e->{match}) and ($e->{type}||'') eq $type;
        my $match = $e->{match};
        if ( $e->{matchmode} eq 'prefix' ) {
            $match =~ s/\D//g;
            $number = $match.$input;
        }
        elsif ( $e->{matchmode} eq 'suffix' ) {
            $number = $match;
            $number =~ s/\((\.+)\)/sprintf('%0'.length($1).'d', $input)/e;
        }
    }
    # FIXME: Consider looking for aliases
    return wantarray ? ($number,$name) : $number;
}

__DATA__
#
# ATduck Dialing Plan
#
# [] matches are regexps that are anchored to the beginning of the original
#    dialing string. The portion of the original dialing string following
#    the match is used as a parameter.
#
# <> matches are patterns that are anchored to the end of the digit-only
#    dialing string. In this pattern, ? denotes any number. First set of
#    wildcards are used as a parameter if applicable (e.g. <6???> type=id
#    means last three digits of the number are the modem ID).
#
#

# All numbers with prefix 8 are handled as an IP adress + port number
[8] type=Telnet

# All numbers with prefix 9 are forwarded to the physical modem
[9] type=Dialout

# Extensions beginning with 6 are modem-to-modem
<6???> type=Modem

# Aliases
<62442> type=Alias target=5550

# Shell commands
<5550> type=Shell usepty
getty -nl"$SHELL" "$M_RATE" "$M_TTYNAME"

<5551> type=Shell
cat /etc/motd | todos

<5552> type=Alias target=8,nethack.alt.org

<5553> type=Shell
set -e
again=y
while [ "$again" = y ]; do
    if robotfindskitten; then
        echo -n 'Would you like to play again? [y/N] '
        again=`head -c 1`
        echo "$again"
    else
        echo 'Sorry, could not start robotfindskitten.'
        again=n
    fi
done

<5555> type=Shell usepty
SLIRP_PATH=./slirp-nandhp-patch
if [ -e /bin/cygcheck ]; then SLIRP_PATH=$SLIRP_PATH.exe; fi
$SLIRP_PATH ppp initiate-options "tty $M_TTYPATH"

<5556> type=Shell usepty
SLIRP_PATH=./slirp-nandhp-patch
if [ -e /bin/cygcheck ]; then SLIRP_PATH=$SLIRP_PATH.exe; fi
$SLIRP_PATH "tty $M_TTYPATH"

<5559> type=Alias target=8,scn.org

