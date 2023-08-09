use strict;
use warnings;
use utf8;
use Turbo;
use HTTP::Parser::XS qw(HEADERS_COMPLETE BODY MESSAGE_COMPLETE);

package Server;

use parent 'Turbo::Server';

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);

    $self->{_pool} = [];
    $self->{_smallPool} = [];
    $self->{_reuseChunkHeader} = sub {
        my ($self, $bufs) = @_;
        push @{$self->{_smallPool}}, $bufs->[2];
    };
    $self->{_reuseChunk} = sub {
        my ($self, $bufs) = @_;
        push @{$self->{_smallPool}}, $bufs->[0];
    };

    $self->on(connection => sub {
        my ($self, $socket) = @_;
        my $headers = $self->_alloc();
        my $buf = $self->_alloc();
        my $parser = HTTP::Parser::XS->new(HEADERS_COMPLETE);

        my ($req, $res);

        $parser->on_headers_complete(sub {
            my ($opts) = @_;
            $req = Request->new($socket, $opts);
            $res = Response->new($self, $socket, $headers);
            $self->emit('request', $req, $res);
        });

        $parser->on_body(sub {
            my ($body, $start, $end) = @_;
            $req->ondata($body, $start, $end);
        });

        $parser->on_message_complete(sub {
            $req->onend();
        });

        $socket->read($buf, sub {
            my ($err, $buf, $read) = @_;
            return if $err || !$read;
            $parser->execute($buf, 0, $read);
            $socket->read($buf, $_[1]);
        });

        $socket->on(close => sub {
            $self->_pool_push($headers, $buf);
        });
    });

    bless $self, $class;
    return $self;
}

sub _alloc {
    my $self = shift;
    return pop @{$self->{_pool}} || Turbo::Buffer::alloc_unsafe(6531);
}

sub _allocSmall {
    my $self = shift;
    return pop @{$self->{_smallPool}} || Turbo::Buffer::alloc_unsafe(2);
}

1;
