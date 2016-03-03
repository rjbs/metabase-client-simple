use 5.006;
use strict;
use warnings;

package Metabase::Client::Simple;
# ABSTRACT: a client that submits to Metabase servers

our $VERSION = '0.013';

use JSON::MaybeXS;
use HTTP::Tiny 0.056; # can_ssl
use URI;

my @valid_args;

BEGIN {
    @valid_args = qw(profile secret uri);

    for my $arg (@valid_args) {
        no strict 'refs';
        *$arg = sub { $_[0]->{$arg}; }
    }
}

=method new

  my $client = Metabase::Client::Simple->new(\%arg)

This is the object constructor.

Valid arguments are:

  profile - a Metabase::User::Profile object
  secret  - a Metabase::User::Secret object
  uri     - the root URI for the metabase server

If you use a C<uri> argument with the 'https' scheme, you must have
L<IO::Socket::SSL> and L<Net::SSLeay> installed.  You may also
require L<Mozilla::CA>.

=cut

sub new {
    my ( $class, @args ) = @_;

    my $args = $class->__validate_args( \@args, { map { $_ => 1 } @valid_args } );

    # uri must have a trailing slash
    $args->{uri} .= "/" unless substr( $args->{uri}, -1 ) eq '/';

    my $self = bless $args => $class;

    unless ( $self->profile->isa('Metabase::User::Profile') ) {
        Carp::confess("'profile' argument for $class must be a Metabase::User::Profile");
    }
    unless ( $self->secret->isa('Metabase::User::Secret') ) {
        Carp::confess("'profile' argument for $class must be a Metabase::User::secret");
    }

    my $scheme = URI->new( $self->uri )->scheme;
    my ( $can_ssl, $reason ) = HTTP::Tiny::can_ssl();
    unless ( $scheme eq 'http' || ( $scheme eq 'https' && $can_ssl ) ) {
        my $msg = "Scheme '$scheme' is not supported.\n";
        if ( $scheme eq 'https' ) {
            $msg .= $reason;
        }
        die $msg;
    }

    return $self;
}

sub _ua {
    my ($self) = @_;
    if ( !$self->{_ua} ) {
        $self->{_ua} =
          HTTP::Tiny->new( agent => __PACKAGE__ . "/" . __PACKAGE__->VERSION . " ", );
    }
    return $self->{_ua};
}

=method submit_fact

  $client->submit_fact($fact);

This method will submit a L<Metabase::Fact|Metabase::Fact> object to the
client's server.  On success, it will return a true value.  On failure, it will
raise an exception.

=cut

sub submit_fact {
    my ( $self, $fact ) = @_;

    my $path = sprintf 'submit/%s', $fact->type;

    $fact->set_creator( $self->profile->resource )
      unless $fact->creator;

    my $req_uri = $self->_abs_uri($path);

    my $auth = $self->_ua->_uri_escape(
        join( ":", $self->profile->resource->guid, $self->secret->content ) );

    $req_uri->userinfo($auth);

    my @req = (
        $req_uri,
        {
            headers => {
                Content_Type => 'application/json',
                Accept       => 'application/json',
            },
            content => JSON::MaybeXS->new( { ascii => 1 } )->encode( $fact->as_struct ),
        },
    );

    my $res = $self->_ua->post(@req);

    if ( $res->{status} == 401 ) {
        if ( $self->guid_exists( $self->profile->guid ) ) {
            Carp::confess $self->_error( $res => "authentication failed" );
        }
        $self->register; # dies on failure
        # should now be registered so try again
        $res = $self->_ua->post(@req);
    }

    unless ( $res->{success} ) {
        Carp::confess $self->_error( $res => "fact submission failed" );
    }

    # This will be something more informational later, like "accepted" or
    # "queued," maybe. -- rjbs, 2009-03-30
    return 1;
}

=method guid_exists

  $client->guid_exists('2f8519c6-24cf-11df-90b1-0018f34ec37c');

This method will check whether the given GUID is found on the metabase server.
The GUID must be in lower-case, string form.  It will return true or false.
Note that a server error will also result in a false value.

=cut

sub guid_exists {
    my ( $self, $guid ) = @_;

    my $path = sprintf 'guid/%s', $guid;

    my $req_uri = $self->_abs_uri($path);

    my $res = $self->_ua->head($req_uri);

    return $res->{success};
}

=method register

  $client->register;

This method will submit the user credentials to the metabase server.  It will
be called automatically by C<submit_fact> if necessary.   You generally won't
need to use it.  On success, it will return a true value.  On failure, it will
raise an exception.

=cut

sub register {
    my ($self) = @_;

    my $req_uri = $self->_abs_uri('register');

    for my $type (qw/profile secret/) {
        $self->$type->set_creator( $self->$type->resource )
          unless $self->$type->creator;
    }

    my @req = (
        $req_uri,
        {
            headers => {
                Content_Type => 'application/json',
                Accept       => 'application/json',
            },
            content => JSON::MaybeXS->new( { ascii => 1 } )
              ->encode( [ $self->profile->as_struct, $self->secret->as_struct ] ),
        }
    );

    my $res = $self->_ua->post(@req);

    unless ( $res->{success} ) {
        Carp::confess $self->_error( $res => "registration failed" );
    }

    return 1;
}

#--------------------------------------------------------------------------#
# private methods
#--------------------------------------------------------------------------#

# Stolen from ::Fact.
# XXX: Should refactor this into something in Fact, which we can then rely on.
# -- rjbs, 2009-03-30
sub __validate_args {
    my ( $self, $args, $spec ) = @_;
    my $hash =
        ( @$args == 1 and ref $args->[0] ) ? { %{ $args->[0] } }
      : ( @$args == 0 ) ? {}
      :                   {@$args};

    my @errors;

    for my $key ( keys %$hash ) {
        push @errors, qq{unknown argument "$key" when constructing $self}
          unless exists $spec->{$key};
    }

    for my $key ( grep { $spec->{$_} } keys %$spec ) {
        push @errors, qq{missing required argument "$key" when constructing $self}
          unless defined $hash->{$key};
    }

    Carp::confess( join qq{\n}, @errors ) if @errors;

    return $hash;
}

sub _abs_uri {
    my ( $self, $str ) = @_;
    my $req_uri = URI->new($str)->abs( $self->uri );
}

sub _error {
    my ( $self, $res, $prefix ) = @_;
    $prefix ||= "unrecognized error";
    if ( ref($res) && $res->{headers}{'content-type'} eq 'application/json' ) {
        my $entity = JSON::MaybeXS->new( { ascii => 1 } )->decode( $res->{content} );
        return "$prefix\: $entity->{error}";
    }
    else {
        return "$prefix\: " . $res->{reason};
    }
}

1;

__END__

=for Pod::Coverage profile secret uri

=head1 SYNOPSIS

  use Metabase::Client::Simple;
  use Metabase::User::Profile;
  use Metabase::User::Secret;

  my $profile = Metabase::User::Profile->load('user.profile.json');
  my $secret  = Metabase::User::Secret ->load('user.secret.json' );

  my $client = Metabase::Client::Simple->new({
    profile => $profile,
    secret  => $secret,
    uri     => 'http://metabase.example.com/',
  });

  my $fact = generate_metabase_fact;

  $client->submit_fact($fact);

=head1 DESCRIPTION

Metabase::Client::Simple provides is extremely simple, lightweight library for
submitting facts to a L<Metabase|Metabase> web server.

=cut


