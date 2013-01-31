package ATduck::Transport::Win32Pipe;
# This file is part of ATduck
use ATduck::Transport;
use Config;
use warnings;
use strict;

our @ISA = qw(ATduck::Transport);

ATduck::Main->install_transport(__PACKAGE__, 'WIN32PIPE');

my @pendingpipes :shared = ();

my $PIPESIG = 'USR1';
# Try to find a real-time signal we can use
{
    my @rtsigs = split / /, $Config{sig_name};
    shift @rtsigs while @rtsigs && $rtsigs[0] ne 'RTMIN';
    if ( 5 < @rtsigs ) { $PIPESIG = $rtsigs[5] }
}
$SIG{$PIPESIG} = \&_cleanup;

# Open a Win32 Named Pipe
sub new_client {
    my $class = shift @_;
    my $self = $class->SUPER::new_client(@_);
    bless($self, $class);

    die "Win32Pipe: thread-capable Perl required" unless $Config{usethreads};
    # Load modules (we don't want ATduck to depend on these modules unless
    # we use Win32Pipes)
    foreach ( qw/Win32API::File Win32::Event/ ) {
        die(($@||$!)."\nWin32Pipe: Can't load $_") unless eval "use $_; 1";
    }

    # Open the named pipe
    $self->{pipe} = Win32API::File::createFile
        ($self->{file}, 'rwe',
         {Flags => Win32API::File::FILE_FLAG_OVERLAPPED()})
        or die 'Win32Pipe: CreateFile: ' .
            Win32API::File::fileLastError() . "\n";

    # Create the bridge pipes
    pipe my $reader, $self->{reader_output}; # Open WinpipeRead bridge
    pipe $self->{writer_input}, my $writer;  # Open WinpipeWrite bridge
    $self->register($reader, $writer);

    # Create threads to handle the reading and writing tasks
    $self->{readthread} = threads->create(\&_read_thread, $self)
        or die "Win32Pipe reader: CreateThread: $!";
    $self->{writethread} = threads->create(\&_write_thread, $self)
        or die "Win32Pipe writer: CreateThread: $!";

    return $self;
}

# FIXME
#
# See "Multithreaded Pipe Server":
# http://msdn.microsoft.com/en-us/library/aa365588(v=vs.85).aspx
sub new_server { die "This transport cannot be used as a listener\n" }

sub _read_thread {
    my ($self) = @_;
    my $event = Win32::Event->new(1, 0);
    if ( !$event ) { die "Win32Pipe reader: CreateEvent failed: $!\n" }
    my $ERROR_IO_PENDING = 997;
    #print "Reading\n";

    while ( 1 ) {
        my ($buf, $bytes) = ('X'x512, 0);
        # Create an OVERLAPPED structure to point to the Event we will wait on
        my $overlapped = pack('LLLLL',0,0,0,0,${$event});
        if ( !Win32API::File::ReadFile($self->{pipe}, $buf, length($buf),
                                       $bytes, $overlapped) ) {
            # If we received ERROR_IO_PENDING, wait for the IO to complete
            my $E = Win32API::File::fileLastError();
            if ( $E != $ERROR_IO_PENDING ) {
                warn "WIN32Pipe reader: WriteFile: $E\n";
                last;
            }
            if ( !Win32API::File::GetOverlappedResult
                     ($self->{pipe}, $overlapped, $bytes, 1) ) {
                $E = Win32API::File::fileLastError();
                warn "Win32Pipe reader: GetOverlappedResult: $E\n";
                last;
            }
        }
        # Warning: GetOverlappedResult does not resize the buffer.
        syswrite($self->{reader_output}, $buf, $bytes);
    }

    print "Reading finished\n";
    # Schedule a deletion of the modem
    { lock(@pendingpipes); push @pendingpipes, $self->{pipe} }
    # Interrupt the select loop (This will never be read)
    #syswrite($self->{reader_output}, 'X');
    kill $PIPESIG, $$;
}

sub _write_thread {
    my ($self) = @_;
    my ($buf,$bytes) = ('', 0);
    my $event = Win32::Event->new(1, 0);
    if ( !$event ) { die "Win32Pipe writer: CreateEvent failed: $!\n" }
    my $ERROR_IO_PENDING = 997;
    #print "Writing\n";

    while (sysread($self->{writer_input}, $buf, 512)>0) {
        # Create an OVERLAPPED structure to point to the Event we will wait on
        my $overlapped = pack('LLLLL',0,0,0,0,${$event});
        #print "W $buf\n";
        if ( !Win32API::File::WriteFile($self->{pipe}, $buf, 0, [],
                                        $overlapped) ) {
            # If we received ERROR_IO_PENDING, wait for the IO to complete
            my $E = Win32API::File::fileLastError();
            if ( $E != $ERROR_IO_PENDING ) {
                warn "WIN32Pipe writer: WriteFile: $E\n";
                last;
            }
            if ( !Win32API::File::GetOverlappedResult
                     ($self->{pipe}, $overlapped, $bytes, 1) ) {
                $E = Win32API::File::fileLastError();
                warn "Win32Pipe writer: GetOverlappedResult: $E\n";
                last;
            }
        }
    }

    print "Writing finished\n";
    # Schedule a deletion of the modem
    { lock(@pendingpipes); push @pendingpipes, $self->{pipe} }
    # Interrupt the select loop (This will never be read)
    #syswrite($self->{reader_output}, 'X');
    kill $PIPESIG, $$;
}

# Remove modems with broken pipes
sub _cleanup {
    # Note that splice is not supported on shared arrays.
    while ( 1 ) {
        my ($p, $m);
        #print "Cleaning ".scalar(@pendingpipes)."\n";
        { lock(@pendingpipes); $p = shift @pendingpipes }
        last unless $p;
        foreach ( @{ATduck::EventLoop->modems} ) {
            next unless ref($_->{serial}) eq __PACKAGE__;
            if ( $_->{serial}{pipe} eq $p ) { $m = $_; last }
        }
        #print "Found ".($m?$m->{id}:'(unknown)')."\n";
        $m->hangup();
        ATduck::EventLoop->remove_modem($m);
    }
}

sub DESTROY {
    my ($self) = @_;
    $self->SUPER::DESTROY(@_);

    if ( $self->{pipe} ) {
        Win32API::File::CloseHandle($self->{pipe});
            #or die "Win32Pipe: CloseHandle: " .
            #    Win32API::File::fileLastError()."\n";
        # We're probably quitting anyway; there's no reason to crash because
        # the pipe can't be closed.
        $self->{pipe} = undef;
    }
    foreach ( qw/readthread writethread/ ) {
        next unless $self->{$_};
        #$self->{$_}->sig('TERM'); # Do I need this? FIXME test more
        $self->{$_}->detach;
    }
    foreach ( qw/reader_output writer_input/ ) {
        close $self->{$_} if $self->{$_};
        $self->{$_} = undef;
    }
}

sub parse {
    my ($self, $str) = @_;
    $str = "\\\\.\\pipe\\$str" if $str !~ /[\/\\]/;
    return { file => $str };
}

sub detect {
    my ($self, $str) = @_;
    return 100 if $str =~ m/^\\\\\.\\pipe\\/;
    return   0;
}

sub accept { die }

1;
