use HTTP::Parser;
use strict;
use warnings;

package Request;

sub new {
    my ($class, $socket, $opts) = @_;
    my $self = bless {
        method => HTTP::Parser::methods()->[$opts->{method}],
        url => $opts->{url},
        socket => $socket,
        _options => $opts,
        _headers => undef,
        ondata => \&noop,
        onend => \&noop,
    }, $class;
    return $self;
}

sub getAllHeaders {
    my ($self) = @_;
    if (!$self->{_headers}) {
        $self->{_headers} = indexHeaders($self->{_options}->{headers});
    }
    return $self->{_headers};
}

sub getHeader {
    my ($self, $name) = @_;
    return $self->getAllHeaders()->{lc $name};
}

sub noop {}

sub indexHeaders {
    my ($headers) = @_;
    my %map;
    for (my $i = 0; $i < scalar @$headers; $i += 2) {
        $map{lc $headers->[$i]} = $headers->[$i + 1];
    }
    return \%map;
}

1;
