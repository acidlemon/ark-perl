package Ark::Context;
use Mouse;
use Mouse::Util::TypeConstraints;

use Ark::Request;
use HTTP::Engine::Response;
use Scalar::Util ();

our $DETACH = 'ARK_DETACH';

subtype 'Ark::Request'
    => as 'Object'
    => where { $_->isa('Ark::Request') };

coerce 'Ark::Request'
    => from 'Object'
    => via {
        $_->isa('Ark::Request') ? $_ : Ark::Request->new(%$_);
    };

has request => (
    is       => 'rw',
    isa      => 'Ark::Request',
    required => 1,
    coerce   => 1,
);

has response => (
    is      => 'rw',
    isa     => 'HTTP::Engine::Response',
    lazy    => 1,
    default => sub {
        HTTP::Engine::Response->new;
    },
);

has app => (
    is       => 'rw',
    isa      => 'Ark::Core',
    required => 1,
    weak_ref => 1,
    handles  => ['log', 'get_actions', 'get_action'],
);

has stash => (
    is      => 'rw',
    isa     => 'HashRef',
    lazy    => 1,
    default => sub { {} },
);

has stack => (
    is      => 'rw',
    isa     => 'ArrayRef',
    lazy    => 1,
    default => sub { [] },
);

has state => (
    is      => 'rw',
    default => 0,
);

has error => (
    is      => 'rw',
    isa     => 'ArrayRef',
    lazy    => 1,
    default => sub { [] },
);

has setup_finished => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
);

after 'setup' => sub { shift->setup_finished(1) };

{   # alias
    no warnings 'once';
    *req = \&request;
    *res = \&response;
}

sub setup { }

sub process {
    my $self = shift;

    $self->prepare;
    $self->dispatch;
    $self->finalize;
}

sub prepare {
    my $self = shift;
    my $req  = $self->request;

    my @path = split /\//, $req->path;
    unshift @path, '' unless @path;

 DESCEND: while (@path) {
        my $path = join '/', @path;
        $path =~ s!^/!!;

        for my $type (@{ $self->app->dispatch_types }) {
            last DESCEND if $type->match( $req, $path );
        }

        my $arg = pop @path;
        $arg =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
        unshift @{ $req->arguments }, $arg;
    }

    s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg
        for grep {defined} @{ $req->captures || [] };

    $self->log( debug => 'Path is "%s"', $req->match );
    $self->log( debug => 'Arguments are "%s"', join('/', @{ $req->args }) );
}

sub forward {
    my ($self, $target, @args) = @_;

    return 0 unless $target;

    if (Scalar::Util::blessed($target)) {
        if ($target->isa('Ark::Action')) {
            $target->dispatch($self, @args);
            return $self->state;
        }
        elsif ($target->can('process')) {
            $self->execute($target, 'process', @args);
            return $self->state;
        }
    }
    else {
        if ($target =~ m!^/.+!) {
            my ($namespace, $name) = $target =~ m!^(.*/)([^/]+)$!;
            $namespace =~ s!(^/|/$)!!g;
            if (my $action = $self->get_action($name, $namespace || '')) {
                $action->dispatch($self, @args);
                return $self->state;
            }
        }
        else {
            my $last = $self->stack->[-1];
            if ($last
                 and $last->{obj}->isa('Ark::Controller')
                 and my $action = $self->get_action($target, $last->{obj}->namespace)) {

                $action->dispatch($self, @args);
                return $self->state;
            }
        }
    }

    my $error = qq/Couldn't forward to $target, Invalid action or component/;
    $self->log( error => $error );
    push @{ $self->error }, $error;

    return 0;
}

sub detach {
    shift->forward(@_);
    die $DETACH;
}

sub dispatch {
    my $self = shift;

    my $action = $self->request->action;
    if ($action) {
        $action->dispatch_chain($self);
    }
    else {
        $self->log( error => 'no action found' );
    }
}

sub depth {
    scalar @{ shift->stack };
}

sub execute {
    my ($self, $obj, $method, @args) = @_;
    my $class = ref $obj;

    $self->state(0);
    push @{ $self->stack }, {
        obj       => $obj,
        method    => $method,
        args      => \@args,
        as_string => "${class}->${method}"
    };

    eval {
        $self->state( $obj->$method($self, @args) );
    };

    my $last = pop @{ $self->stack };

    if (my $error = $@) {
        if ($error =~ /^${DETACH} at /) {
            die $DETACH if ($self->depth > 1);
        }
        else {
            push @{ $self->error }, $error;
            $self->state(0);
        }
    }

    $self->state;
}

sub finalize { }

1;
