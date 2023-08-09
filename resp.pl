use strict;
use warnings;
use Turbo;
use HTTP::Parser::XS qw(HEADERS_COMPLETE BODY MESSAGE_COMPLETE);

our %httpStatus = (
    200 => 'HTTP/1.1 200 OK',
);

our $SEP = ': ';
our $EOL = "\r\n";
our $EOL_BUFFER = Turbo::Buffer->from_string($EOL);
our $EMPTY = Turbo::Buffer->alloc(0);
our $LAST_CHUNK = Turbo::Buffer->from_string("0\r\n\r\n");
our $LAST_CHUNK_AFTER_DATA = Turbo::Buffer->from_string("\r\n0\r\n\r\n");
our $HEADER_CHUNKED = Turbo::Buffer->from_string("Transfer-Encoding: chunked\r\n");
our $HEADER_KEEP_ALIVE = Turbo::Buffer->from_string("Connection: keep-alive\r\n");
our $CONTENT_LENGTH = qr/^Content-Length$/i;
our $CONNECTION = qr/^Connection$/i;

package Response;

sub new {
    my ($class, $server, $socket, $headers) = @_;

    my $self = {
        server => $server,
        socket => $socket,
        statusCode => 200,
        headerSent => 0,
        _headers => $headers,
        _headersLength => 0,
        _keepAlive => 1,
        _chunked => 1,
        _reuseChunkHeader => $server->{_reuseChunkHeader},
        _reuseChunk => $server->{_reuseChunk},
    };

    bless $self, $class;
    return $self;
}

sub setHeader {
    my ($self, $name, $value) = @_;

    die "Cannot write to headers after headers sent" if $self->{headerSent};
    my $header = "$name$SEP$value$EOL";

    if ($self->{_headersLength} + length($header) > 65534) {
        $self->{_headers} = Turbo::Buffer->concat([$self->{_headers}, Turbo::Buffer->alloc(65536)]);
    }

    $self->{_headers}->write_ascii($header, $self->{_headersLength});
    $self->{_headersLength} += length($header);

    if ($name =~ $CONTENT_LENGTH) {
        $self->{_chunked} = 0;
    } elsif ($name =~ $CONNECTION) {
        $self->{_keepAlive} = 0;
    }
}

sub _appendHeader {
    my ($self, $buf) = @_;

    if ($self->{_headersLength} + length($buf) > 65534) {
        $self->{_headers} = Turbo::Buffer->concat([$self->{_headers}, Turbo::Buffer->alloc(65536)]);
    }

    $self->{_headers}->copy($buf, $self->{_headersLength});
    $self->{_headersLength} += length($buf);
}

sub _flushHeaders {
    my ($self) = @_;

    $self->{headerSent} = 1;
    $self->_appendHeader($HEADER_KEEP_ALIVE) if $self->{_keepAlive};
    $self->_appendHeader($HEADER_CHUNKED) if $self->{_chunked};
    $self->{_headers}->write_ascii($EOL, $self->{_headersLength});
}

sub _writeHeader {
    my ($self, $buf, $n, $cb) = @_;

    $self->_flushHeaders();
    my $status = $httpStatus{$self->{statusCode}};

    $self->{socket}->writev(
        [$status, $self->{_headers}, $buf],
        [length($status), $self->{_headersLength} + 2, $n],
        $cb
    );
}

sub _writeHeaderv {
    my ($self, $bufs, $ns, $cb) = @_;

    $self->_flushHeaders();
    my $status = $httpStatus{$self->{statusCode}};

    $self->{socket}->writev(
        [$status, $self->{_headers}, @$bufs],
        [length($status), $self->{_headersLength} + 2, @$ns],
        $cb
    );
}

sub _writeHeaderChunkedv {
    my ($self, $bufs, $ns, $cb) = @_;

    $self->_flushHeaders();
    my $status = $httpStatus{$self->{statusCode}};
    my $chunkHeader = $self->{server}->_allocSmall();
    my $chunkHeaderLength = encodeHex(addAll($ns), $chunkHeader);

    $self->{socket}->writev(
        [$status, $self->{_headers}, $chunkHeader, @$bufs, $EOL_BUFFER],
        [length($status), $self->{_headersLength} + 2, $chunkHeaderLength, @$ns, 2],
        $cb || $self->{_reuseChunkHeader}
    );
}

sub _writeHeaderChunked {
    my ($self, $buf, $n, $cb) = @_;

    $self->_flushHeaders();
    my $status = $httpStatus{$self->{statusCode}};
    my $chunkHeader = $self->{server}->_allocSmall();
    my $chunkHeaderLength = encodeHex($n, $chunkHeader);

    $self->{socket}->writev(
        [$status, $self->{_headers}, $chunkHeader, $buf, $EOL_BUFFER],
        [length($status), $self->{_headersLength} + 2, $chunkHeaderLength, $n, 2],
        $cb || $self->{_reuseChunkHeader}
    );
}

sub write {
    my ($self, $buf, $n, $cb) = @_;

    $buf = Turbo::Buffer->from_string($buf) if ref($buf) eq '';
    if (ref($n) eq 'CODE') {
        $self->_write($buf, $buf->length, $n);
    } else {
        $self->_write($buf, $n || $buf->length, $cb);
    }
}

sub writev {
    my ($self, $bufs, $ns, $cb) = @_;

    if (ref($ns) eq 'CODE') {
        $self->_writev($bufs, getLengths($bufs), $ns);
    } else {
        $self->_writev($bufs, $ns || getLengths($bufs), $cb);
    }
}

sub _writev {
    my ($self, $bufs, $ns, $cb) = @_;

    if ($self->{_chunked}) {
        if ($self->{headerSent}) {
            $self->_writeChunkv($bufs, $ns, $cb);
        } else {
            $self->_writeHeaderChunkedv($bufs, $ns, $cb);
        }
    } else {
        if ($self->{headerSent}) {
            $self->{socket}->writev($bufs, $ns, $cb);
        } else {
            $self->_writeHeaderv($bufs, $ns, $cb);
        }
    }
}

sub encodeHex {
    my ($n, $buf) = @_;
    my $hex = sprintf('%x', $n);
    $buf->write_ascii($hex, 0);
    
