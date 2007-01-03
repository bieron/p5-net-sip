###########################################################################
# Net::SIP::Simple
# simple methods for creation of UAC,UAS
# - register    register Address
# - invite      create new call
# - listen      UAS, wait for incoming requests
###########################################################################

use strict;
use warnings;

package Net::SIP::Simple;
use fields (
	'endpoint',           # Net::SIP::Endpoint
	'dispatcher',         # Net::SIP::Dispatcher
	'loop',               # Net::SIP::Dispatcher::Eventloop or similar
	'outgoing_proxy',     # optional outgoing proxy (addr:port)
	'registrar',          # optional registrar (addr:port)
	'auth',               # Auth data, see Net::SIP::Endpoint
	'from',               # SIP address of caller
	'domain',             # default domain for SIP addresses
	'last_error',         # last error
);

use Carp qw(croak);
use Net::SIP::Dispatcher;
use Net::SIP::Dispatcher::Eventloop;
use Net::SIP::Endpoint;
use Net::SIP::Registrar;
use Net::SIP::StatelessProxy;
use Net::SIP::Leg;
use Net::SIP::Simple::Call;
use Net::SIP::Simple::RTP;
use Net::SIP::Util qw( :all );
use List::Util 'first';
use Net::SIP::Debug;

###########################################################################
# create UA
# Args: ($class;%args)
#   %args: misc args, all args are optional
#     outgoing_proxy - specify outgoing proxy
#     proxy          - alias to outgoing_proxy
#     legs|leg       - \@list of local sockets,ip:addr or ip, needed if no
#                      outgoing proxy is given. if only one item does not need
#                      to be a list
#     registrar      - use registrar for registration 
#     auth           - auth data: [ user,pass ] or { realm1 => [user,pass],.. }
#     from           - myself, used for calls and registration
#     loop           - predefined Net::SIP::Dispatcher::Eventloop, used if
#                      shared between UAs
#     dispatcher     - predefined Net::SIP::Dispatcher, used if
#                      shared between UAs
#     domain         - domain used if from/to.. do not contain domain
#     domain2proxy   - hash of { domain => proxy }
#                      used to find proxy for domain. If nothing matches here
#                      DNS need to be used. Special domain '*' catches all
#     d2p            - alias for domain2proxy
# Returns: $self
# Comment: 
# FIXME
# If more than one leg is given (e.g. legs+outgoing_proxy) than you have
# to provide a function to find out, which leg is used to send out a request
###########################################################################
sub new {
	my ($class,%args) = @_;
	my $auth = delete $args{auth};
	my $registrar = delete $args{registrar};

	my $from = delete $args{from};
	my $domain = delete $args{domain};
	if ($from) {
		$domain = $1 if !defined($domain)
			&& $from =~m{\bsips?:[^@]+\@([\w\-\.]+)};
		$from = "$from <sip:$from\@$domain>" 
			if $from !~m{\s} && $from !~m{\@};
	}

	my $legs = delete $args{legs} || delete $args{leg};
	$legs = [ $legs ] if $legs && !ref($legs);
	$legs ||= [];

	foreach ($legs ? @$legs : ()) {
		if ( ref ) {
			# assume file handle
			$_ = Net::SIP::Leg->new( sock => $_ )
		} elsif ( m{^(?:(udp|tcp):)?([\w\-\.]+)(?::(\d+))?$} ) {
			# host|udp:host|udp:host:port|host:port
			$_ = Net::SIP::Leg->new(
				addr => $2, port => $3, proto => $1 );
		}
	}

	my $ob = delete $args{outgoing_proxy} 
		|| delete $args{proxy};
	if ( $ob && ! first { $_->can_deliver_to($ob) } @$legs ) {
		my ($sock) = create_socket_to( $ob ) or die $!;
		push @$legs, Net::SIP::Leg->new( sock => $sock );
	}

	if ( $registrar && ! first { $_->can_deliver_to($registrar) } @$legs ) {
		my ($sock) = create_socket_to( $registrar ) or die $!;
		push @$legs, Net::SIP::Leg->new( sock => $sock );
	}


	my $loop = delete $args{loop} 
		|| Net::SIP::Dispatcher::Eventloop->new;

	my $d2p = delete $args{domain2proxy} || delete $args{d2p};
	my $disp = delete $args{dispatcher}
		|| Net::SIP::Dispatcher->new(
			$legs,
			$loop,
			outgoing_proxy => $ob,
			domain2proxy => $d2p,
		);

	my $endpoint = Net::SIP::Endpoint->new( $disp );

	my $self = fields::new( $class );
	%$self = (
		auth => $auth,
		from => $from,
		endpoint => $endpoint,
		registrar => $registrar,
		dispatcher => $disp,
		loop => $loop,
	);
	return $self;
}

###########################################################################
# get last error or set it
# Args: ($self;$err)
#  $err: if given will set error
# Returns: $last_error
###########################################################################
sub error {
	my Net::SIP::Simple $self = shift;
	if ( @_ ) {
		$self->{last_error} = shift;
		DEBUG( Debug::stacktrace( "set error to ".$self->{last_error}) );
	}
	return $self->{last_error};
}


###########################################################################
# mainloop
# Args: (;$timeout,@stopvar)
#  $timeout: timeout, undef for no timeout. argument can be ommitted
#  @stopvar: @array of Scalar-REF, loop stops if one scalar is true
# Returns: NONE
###########################################################################
sub loop {
	my Net::SIP::Simple $self = shift;
	my ($timeout,@stopvar);
	foreach (@_) {
		if ( ref($_) ) {
			push @stopvar,$_
		} elsif ( defined($_)) {
			$timeout = $_
		}
	}
	return $self->{loop}->loop( $timeout,@stopvar );
}

###########################################################################
# control RTP behavior
# Args: ($self,$method,@arg)
#  $method: Method name for behavior, e.g. calls Net::SIP::Simple::RTP::$method
#  @arg: Arguments for method
# Returns: $cb
#  $cb: callback structure
###########################################################################
sub rtp {
	my Net::SIP::Simple $self = shift;
	my ($method,@arg) = @_;
	my $sub = UNIVERSAL::can( 'Net::SIP::Simple::RTP',$method )
		|| UNIVERSAL::can( 'Net::SIP::Simple::RTP','media_'.$method )
		|| croak( "no such method '$method' in Net::SIP::Simple::RTP" );
	return $sub->( 'Net::SIP::Simple::RTP',@arg );
}


###########################################################################
# Register UA at registrar
# waits until final response is received
# Args: ($self,%args)
#  %args: Hash with keys..
#    registrar: Register there, default $self->{registrar}
#    from:      use 'from' as lokal address, default $self->{from}
#    leg:       use given Net::SIP::Leg object for registration, default first leg
#    cb_final:  user defined callback when final response is received
#    more args (expire...) will be forwarded to Net::SIP::Endpoint::register
# Returns: expires
#   if user defined callback or failed expires will be undef
#   otherwise it will be the expires value from the registrars response
###########################################################################
sub register {
	my Net::SIP::Simple $self = shift;
	my %args = @_;

	my $registrar = delete $args{registrar} || $self->{registrar} 
		|| croak( "no registrar" );
	my $leg = delete $args{leg};
	if ( !$leg ) {
		# use first leg
		($leg) = $self->{dispatcher}->get_legs();
	}

	my $from = delete $args{from} || $self->{from} 
		|| croak( "unknown from" );
	my $contact = $from;
	my $local = $leg->{addr}.':'.$leg->{port};
	$contact.= '@'.$local unless $contact =~s{\@([\w\-\.]+)}{\@$local};

	my %rarg = (
		from => $from,
		registrar => $registrar,
		contact => $contact,
		auth => delete $args{auth} || $self->{auth},
	);
	%rarg = ( %rarg, %args ) if %args;

	my $cb_final = delete $rarg{cb_final};
	my $stopvar = 0;
	$cb_final ||= \$stopvar;

	my $cb = sub {
		my ($self,$cb_final,$expires,$endpoint,$ctx,$errno,$code,$packet,$leg,$from) = @_;
		if ( $code && $code =~m{^2\d\d} ) {
			my $exp = $packet->get_header( 'Expires' );
			if ( ! defined $exp ) {
				foreach my $c ( $packet->get_header( 'contact' ) ) {
					my ($addr,$p) = sip_hdrval2parts( contact => $c );
					defined( my $e = $p->{expires} ) || next;
					$exp = $e if ! defined($exp) || $e < $exp; 
				}
			}
			$$expires = $exp;
			invoke_callback( $cb_final, 'OK', expires => $exp );

		} elsif ( $code ) {
			$self->error( "Failed with code $code" );
			invoke_callback( $cb_final, 'FAIL', code => $code );
		} elsif ( $errno ) {
			$self->error( "Failed with error $errno" );
			invoke_callback( $cb_final, 'FAIL', errno => $errno );
		} else {
			$self->error( "Unknown failure" );
			invoke_callback( $cb_final, 'FAIL' );
		}
	};

	my $expires;
	$self->{endpoint}->register( %rarg, callback => [ $cb,$self,$cb_final,\$expires ] );

	# if cb_final is local stopvar wait until it got set
	if ( \$stopvar == $cb_final ) {
		$self->loop( \$stopvar );
		return $stopvar eq 'OK' ? $expires: undef;
	}
}

###########################################################################
# create new call
# and waits until the INVITE is completed (e.g final response received)
# Args: ($self,$to;%args)
#   $to: sip address of peer 
#   %args: see Net::SIP::Simple::Call::invite
# Returns: $call
#   $call: Net::SIP::Simple::Call
###########################################################################
sub invite {
	my Net::SIP::Simple $self = shift;
	my ($to,%args) = @_;
	$to || croak( "need peer of call" );
	$to = "$to <sip:$to\@$self->{domain}>" if $to !~m{\s} && $to !~m{\@};
	my $call = Net::SIP::Simple::Call->new( $self,$to );
	my $stopvar;
	$call->reinvite(%args );
	return $call;
}

###########################################################################
# listen for and accept new calls
# Args: ($self,%args)
#  %args:
#    filter: optional sub or regex to filter which incoming calls gets accepted
#      if not given all calls will be accepted
#      if regex only from matching regex gets accepted
#      if sub and sub returns 1 call gets accepted, if sub returns 0 it gets rejected
#    cb_create: optional callback called on creation of newly created 
#      Net::SIP::Simple::Call
#    cb_final: callback called after receiving ACK
#    call_cleanup: called on destroy of call object
#    for all other args see Net::SIP::Simple::Call....
# Returns: $call
#   $call: Net::SIP::Simple::Call
###########################################################################
sub listen {
	my Net::SIP::Simple $self = shift;
	my %args = @_;

	# handle new requests
	my $receive = sub {
		my ($self,$args,$endpoint,$ctx,$request,$leg,$from) = @_;
		$request->method eq 'INVITE' or do {
			DEBUG( "drop non-INVITE request" );
			$self->{endpoint}->close_context( $ctx );
			return;
		};

		if ( my $filter = $args->{filter} ) {
			my $rv = invoke_callback( $filter, $ctx->{from} );
			if ( !$rv ) {
				DEBUG( "call from '$ctx->{from}' rejected" );
				$self->{endpoint}->close_context( $ctx );
				return;
			}
		}

		# new invite, create call
		my $call = Net::SIP::Simple::Call->new( $self,$ctx,{ %$args });
		my $cb = UNIVERSAL::can( $call,'receive' ) || die;

		# notify caller about new call
		invoke_callback( $args->{cb_create}, $call );
		if ( my $ccb = $args->{cb_cleanup} ) {
			push @{ $call->{cb_cleanup}}, $ccb;
		}

		# setup callback on context and call it for this packet
		$ctx->set_callback([ $cb,$call ]);
		$cb->( $call,$endpoint,$ctx,undef,undef,$request,$leg,$from );
	};

	$self->{endpoint}->set_application([ $receive, $self,\%args ]);
}

###########################################################################
# setup a simple registrar
# Args: ($self,%args)
#   %args:
#     max_expires: maximum expires time accepted fro registration, default 300
#     min_expires: minimum expires time accepted, default 30
#     domains|domain: domain or \@list of domains the registrar is responsable
#       for. special domain '*' catches all
# Returns: NONE
###########################################################################
sub create_registrar {
	my Net::SIP::Simple $self = shift;
	my $registrar = Net::SIP::Registrar->new(
		dispatcher => $self->{dispatcher}, 
		@_ 
	);
	$self->{dispatcher}->set_receiver( $registrar );
}

###########################################################################
# setup a stateless proxy with the optional ability to be 
# a registrar too
# Args: ($self,%args)
#   %args:
#     registrar: \%hash with args if it works additionally as a registrar,
#       see Net::SIP::Registrar->new
# Returns: NONE
###########################################################################
sub create_stateless_proxy {
	my Net::SIP::Simple $self = shift;
	my $proxy = Net::SIP::StatelessProxy->new(
		dispatcher => $self->{dispatcher}, 
		@_ 
	);
	$self->{dispatcher}->set_receiver( $proxy );
}

1;