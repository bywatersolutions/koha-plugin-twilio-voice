package Koha::Plugin::Com::ByWaterSolutions::TwilioVoice;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Auth;
use C4::Context;
use Koha::Notice::Messages;

use HTTP::Request::Common;
use LWP::UserAgent;
use Mojo::JSON qw(decode_json);
use WWW::Twilio::API;

## Here we set our plugin version
our $VERSION = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Twilio Voice Plugin',
    author          => 'Kyle M Hall',
    date_authored   => '2020-05-13',
    date_updated    => "1900-01-01",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin enables sending of phone message to patrons via Twilio.',
};

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub before_send_messages {
    my ( $self ) = @_;

    my $AccountSid = $self->retrieve_data('AccountSid');
    my $AuthToken  = $self->retrieve_data('AuthToken');

    my $twilio = WWW::Twilio::API->new(
        AccountSid => $AccountSid,
        AuthToken  => $AuthToken,
    );

    my $from = $self->retrieve_data('From');

    my $messages = Koha::Notice::Messages->search({ status => 'pending', message_transport_type => 'phone' });

    while ( my $m = $messages->next ) {
        my $patron = Koha::Patrons->find( $m->borrowernumber );
        next unless $patron;

        my $phone = $patron->phone || $patron->mobile;
        warn "PHONE: $phone";

        # Normalize the phone number to E.164 format, Twilio has a convenient ( and free ) API for this.
        my $ua = LWP::UserAgent->new;
        my $request = HTTP::Request->new(GET => "https://lookups.twilio.com/v1/PhoneNumbers/$phone?CountryCode=US");
        $request->authorization_basic($AccountSid, $AuthToken);
        my $response = $ua->request($request);
        next if $response->code eq "404";
        my $data = decode_json( $response->decoded_content );
        my $to = $data->{phone_number};

        # Send the call request
        my $url = "https://api.twilio.com/2010-04-01/Accounts/$AccountSid/Calls.json";
        my $twiml_url = "https://staff-twilio.bwsdev2.bywatersolutions.com/api/v1/contrib/twiliovoice/messages/" . $m->id;
        my $status_callback_url = "https://staff-twilio.bwsdev2.bywatersolutions.com/api/v1/contrib/twiliovoice/message/" . $m->id;
        $request = POST $url, [From => $from, To => $to, Url => $twiml_url, StatusCallback => $status_callback_url];
        $request->authorization_basic($AccountSid, $AuthToken);
        $response = $ua->request($request);
        warn "RESPONSE CODE: " . $response->code;
        $data = decode_json( $response->decoded_content );
        warn "RESPONSE CONTENT: " . Data::Dumper::Dumper($data);
    }

}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template({ file => 'configure.tt' });

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            AccountSid => $self->retrieve_data('AccountSid'),
            AuthToken  => $self->retrieve_data('AuthToken'),
            From       => $self->retrieve_data('From'),
        );

        $self->output_html( $template->output() );
    }
    else {
        $self->store_data(
            {
                AccountSid => $cgi->param('AccountSid'),
                AuthToken  => $cgi->param('AuthToken'),
                From       => $cgi->param('From'),
            }
        );
        $self->go_home();
    }
}

sub install() {
    my ( $self, $args ) = @_;

    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;

    return 1;
}

sub uninstall() {
    my ( $self, $args ) = @_;

    return 1;
}

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ( $self ) = @_;
    
    return 'twiliovoice';
}

1;
