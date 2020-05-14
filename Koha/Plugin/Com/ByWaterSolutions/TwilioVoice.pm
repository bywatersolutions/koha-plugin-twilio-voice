package Koha::Plugin::Com::ByWaterSolutions::TwilioVoice;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Auth;
use C4::Context;
use Koha::Notice::Messages;

use Mojo::JSON qw(decode_json);
use Number::Phone::Normalize;
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

sub cronjob {
    my ( $self ) = @_;

    my $twilio = WWW::Twilio::API->new(
        AccountSid => $self->retrieve_data('AccountSid'),
        AuthToken  => $self->retrieve_data('AuthToken'),
    );

    my $from = $self->retrieve_data('From');

    my $messages = Koha::Notice::Messages->search({ status => 'pending', message_transport_type => 'phone' });

    while ( my $m = $messages->next ) {
        my $patron = Koha::Patrons->find( $m->borrowernumber );
        next unless $patron;

        my $phone = $patron->phone || $patron->mobile;
        #FIXME: the line below doesn't work yet
        $phone = phone_intl($phone, 'CountryCodeOut' => '1', 'CountryCode' => '1', 'IntlPrefixOut' => '+', 'AlwaysLD' => 1, 'IntlPrefix' => '99', 'IntlPrefixOut' => '99', 'LDPrefix' => '88' );
        next unless $phone;

        my $response = $twilio->POST(
            'Calls',
            From => $from, # Any phone number you specify here must be a Twilio phone number (you can purchase a number through the console) or a verified outgoing caller id for your account.
            To   => '+18145731189',
            Url  => 'https://staff-twilio.bwsdev2.bywatersolutions.com/api/v1/contrib/twiliovoice/messages/5'
        );

        #TODO: Check for successful queuing
        #TODO: Add callback to report failure
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
