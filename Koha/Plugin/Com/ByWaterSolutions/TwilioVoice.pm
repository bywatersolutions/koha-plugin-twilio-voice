package Koha::Plugin::Com::ByWaterSolutions::TwilioVoice;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Auth;
use C4::Context;
use Koha::Notice::Messages;

use HTTP::Request::Common;
use LWP::UserAgent;
use Mojo::JSON qw(decode_json);
use List::Util qw(first any);

## Here we set our plugin version
our $VERSION         = "{VERSION}";
our $MINIMUM_VERSION = "19.11.06";

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
    my ($class, $args) = @_;

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
    my ($self, $params) = @_;

    my $type        = $params->{type};
    my $letter_code = $params->{letter_code};
    my $where       = $params->{where};
    my $message_id  = $params->{message_id};

    # If a type limit is passed in, only run if the type is "phone"
    return if ref($type) eq 'ARRAY' && scalar @$type > 0 && !grep(/^phone$/, @$type); # 22.11.00, 22.05.8, 21.11.14 +, bug 27265
    return if ref($type) eq q{}     && $type ne q{}      && $type ne 'phone';

    # If this version of Koha sends an arrayref, check the length of it and set the var to false if it has no elements
    $letter_code = undef if ref($letter_code) eq 'ARRAY' && scalar @$letter_code == 0;

    my $BorrowernumberFilter = $self->retrieve_data('BorrowernumberFilter');

    my $AccountSid                         = $self->retrieve_data('AccountSid');
    my $AuthToken                          = $self->retrieve_data('AuthToken');
    my $single_notice_hold                 = $self->retrieve_data('single_notice_hold');
    my $skip_if_other_transports           = $self->retrieve_data('skip_if_other_transports');
    my $skip_odue_if_other_if_sms_or_email = $self->retrieve_data('skip_odue_if_other_if_sms_or_email');

    my $from = $self->retrieve_data('From');

    my $parameters = {status => 'pending', message_transport_type => 'phone',};
    $parameters->{borrowernumber} = $BorrowernumberFilter if $BorrowernumberFilter;
    $parameters->{letter_code} = $letter_code if $letter_code;
    $parameters->{message_id} = $message_id if $message_id;
    my $messages = Koha::Notice::Messages->search($parameters);
    $messages = $messages->search( \$where ) if $where;

    my $dbh = C4::Context->dbh;

    # Reset the status of any calls that may have failed due to the plugin api being inaccessible
    $dbh->do(q{
        UPDATE message_queue
        SET failure_code = NULL,
            status = 'failed'
        WHERE failure_code = 'PENDING RESPONSE'
          AND updated_on < NOW() - INTERVAL 10 MINUTE;
    });

    my $letter1 = $dbh->selectcol_arrayref(q{SELECT DISTINCT(letter1) FROM overduerules});
    my $letter2 = $dbh->selectcol_arrayref(q{SELECT DISTINCT(letter2) FROM overduerules});
    my $letter3 = $dbh->selectcol_arrayref(q{SELECT DISTINCT(letter3) FROM overduerules});
    my @odue_letter_codes = ( @$letter1, @$letter2, @$letter3 );

    my $sent = {};
    while (my $m = $messages->next) {
        $m->status('sent');
        $m->update();

        my $patron = Koha::Patrons->find($m->borrowernumber);
        next unless $patron;

        my $phone = $patron->phone || $patron->mobile;

        unless ( $phone ) {
            $m->status('failed');
            $m->update();
            next;
        }

        if ($m->letter_code eq 'HOLD' && $single_notice_hold) {
            if ($sent->{HOLD}->{$m->borrowernumber}) {
                $sent->{HOLD}->{$m->borrowernumber} = 1;

                $m->status('deleted');    # As close a status to 'skipped' as we have
                $m->update();

                next;
            }
        }

        if ($skip_if_other_transports) {
            my $other_messages = Koha::Notice::Messages->search({
                -and => [
                    borrowernumber => $m->borrowernumber,
                    status         => 'pending',
                    letter_code    => $m->letter_code,
                    -or            => [message_transport_type => 'email', message_transport_type => 'sms',]
                ],
            });

            if ($other_messages->count) {
                $m->status('deleted');    # As close a status to 'skipped' as we have
                $m->update();
                next;
            }
        }

        # If enabled, skip sending if this is an overdue notice *and* the patron has an sms number or email address
        if ($skip_odue_if_other_if_sms_or_email && any { $m->{letter_code} eq $_ } @odue_letter_codes) {
            my $skip = $patron->notice_email_address || $patron->smsalertnumber;

            if ($skip) {
                $m->status('deleted');    # As close a status to 'skipped' as we have
                $m->update();
                next;
            }
        }

        # Normalize the phone number to E.164 format, Twilio has a convenient ( and free ) API for this.
        my $ua      = LWP::UserAgent->new;
        my $request = HTTP::Request->new(GET => "https://lookups.twilio.com/v1/PhoneNumbers/$phone?CountryCode=US");
        $request->authorization_basic($AccountSid, $AuthToken);
        my $response = $ua->request($request);
        next if $response->code eq "404";
        my $data = decode_json($response->decoded_content);
        my $to   = $data->{phone_number};

        my $OPACBaseURL
          = $self->retrieve_data('IncomingApiCallsUrl') || C4::Context->preference('OPACBaseURL');
        $OPACBaseURL =~ s/[^[:print:]]+//g;
        $OPACBaseURL =~ s/[^[:ascii:]]+//g;

        # Send the call request
        my $message_id                    = $m->id;
        my $url                           = "https://api.twilio.com/2010-04-01/Accounts/$AccountSid/Calls.json";
        my $twiml_url                     = "$OPACBaseURL/api/v1/contrib/twiliovoice/message/$message_id/twiml";
        my $status_callback_url           = "$OPACBaseURL/api/v1/contrib/twiliovoice/message/$message_id/status";
        my $async_amd_status_callback_url = "$OPACBaseURL/api/v1/contrib/twiliovoice/message/$message_id/amd";

        warn "Twilio Phone message sent to $to for message id $message_id";

        $request = POST $url,
          [
            From                         => $from,
            To                           => $to,
            Url                          => $twiml_url,
            StatusCallback               => $status_callback_url,
            StatusCallbackEvent          => 'completed',
            StatusCallbackMethod         => 'POST',
            MachineDetection             => 'DetectMessageEnd',
            AsyncAmd                     => 'true',
            AsyncAmdStatusCallback       => $async_amd_status_callback_url,
            AsyncAmdStatusCallbackMethod => 'POST',
          ];
        $request->authorization_basic($AccountSid, $AuthToken);
        $response = $ua->request($request);

        unless ($response->is_success) {
            warn "Twilio response indicates failure: " . $response->status_line;
            $m->status('failed');
            $m->update();
        } else {
            $m->failure_code('PENDING RESPONSE');
        }
    }
}

sub configure {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    unless ($cgi->param('save')) {
        my $template = $self->get_template({file => 'configure.tt'});

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            AccountSid                         => $self->retrieve_data('AccountSid'),
            AuthToken                          => $self->retrieve_data('AuthToken'),
            HoldMusicUrl                       => $self->retrieve_data('HoldMusicUrl'),
            From                               => $self->retrieve_data('From'),
            IncomingApiCallsUrl                => $self->retrieve_data('IncomingApiCallsUrl'),
            single_notice_hold                 => $self->retrieve_data('single_notice_hold'),
            skip_if_other_transports           => $self->retrieve_data('skip_if_other_transports'),
            BorrowernumberFilter               => $self->retrieve_data('BorrowernumberFilter'),
            skip_odue_if_other_if_sms_or_email => $self->retrieve_data('skip_odue_if_other_if_sms_or_email'),
        );

        $self->output_html($template->output());
    }
    else {
        $self->store_data({
            AccountSid                         => $cgi->param('AccountSid'),
            AuthToken                          => $cgi->param('AuthToken'),
            HoldMusicUrl                       => $cgi->param('HoldMusicUrl'),
            From                               => $cgi->param('From'),
            IncomingApiCallsUrl                => $cgi->param('IncomingApiCallsUrl'),
            single_notice_hold                 => $cgi->param('single_notice_hold')       ? 1 : 0,
            skip_if_other_transports           => $cgi->param('skip_if_other_transports') ? 1 : 0,
            BorrowernumberFilter               => $cgi->param('BorrowernumberFilter'),
            skip_odue_if_other_if_sms_or_email => $cgi->param('skip_odue_if_other_if_sms_or_email') ? 1 : 0,
        });
        $self->go_home();
    }
}

sub install() {
    my ($self, $args) = @_;

    return 1;
}

sub upgrade {
    my ($self, $args) = @_;

    return 1;
}

sub uninstall() {
    my ($self, $args) = @_;

    return 1;
}

sub api_routes {
    my ($self, $args) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'twiliovoice';
}

1;
