package Koha::Plugin::Com::ByWaterSolutions::TwilioVoice::API;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

use WWW::Twilio::TwiML;
use WWW::Form::UrlEncoded qw(parse_urlencoded);

use Koha::Notice::Messages;

=head1 API

=head2 Class Methods

=head3 Returns TwiML for the given message

=cut

sub twiml {
    my $c = shift->openapi->valid_input or return;

    my $message_id = $c->validation->param('message_id');
    my $message    = Koha::Notice::Messages->find($message_id);
    unless ($message) {
        return $c->render(
            status  => 404,
            openapi => { error => "Message not found." }
        );
    }

    my $content = q{<?xml version="1.0" encoding="UTF-8"?>
<Response>
  <Say>Ahoy! You have a message from your library. Just a moment.</Say>
  <Play>http://demo.twilio.com/docs/classic.mp3</Play>
</Response>};

    my $tw = new WWW::Twilio::TwiML;
    $tw->Response
    ->Pause({length => 2})->parent
    ->Say(
        {
            voice    => "Polly.Joanna",
            language => "en-US"
        },
        $content
    )->parent
    ->Pause({length => 2})->parent
    ->Say(
        {
            voice    => "Polly.Joanna",
            language => "en-US"
        },
        $message->content
    );

    $message->status('sent');
    $message->store();

    warn "TWILIO: twiml(): " . Data::Dumper::Dumper( $tw->to_string );

    return $c->render( status => 200, format => "xml", text => $tw->to_string );
}

sub update_message_status {
    my $c = shift->openapi->valid_input or return;

    my $message_id = $c->validation->param('message_id');
    my $message    = Koha::Notice::Messages->find($message_id);
    unless ($message) {
        return $c->render(
            status  => 404,
            openapi => { error => "Message not found." }
        );
    }

    my $body = $c->req->body;

    if ( my %data = parse_urlencoded($body) ) {
        my $twilio_status = $data{CallStatus};

        warn "TWILIO: update_message_status(): " . Data::Dumper::Dumper( \%data );

        my $status = $twilio_status eq 'queued'      ? 'sent'   : # We should get another status update later
                     $twilio_status eq 'ringing'     ? 'sent'   : # Ditto
                     $twilio_status eq 'in-progress' ? 'sent'   : # The person picked up, basically completed
                     $twilio_status eq 'completed'   ? 'sent'   : # Clearly completed
                     $twilio_status eq 'busy'        ? 'failed' : # TODO: Make retrying busy a plugin setting
                     $twilio_status eq 'failed'      ? 'failed' : # Phone number was most likely invalid
                     $twilio_status eq 'no-answer'   ? 'failed' : # See TODO above
                                                       'failed' ; # Staus was something we didn't expect
        $message->status($status);
        $message->store();

        return $c->render( status => 204, text => q{} );
    }
    else {
        return $c->render(
            status  => 500,
            openapi => { error => "Unable to decode json" }
        );
    }
}

sub amd_callback {
    my $c = shift->openapi->valid_input or return;
    my $self = Koha::Plugin::Com::ByWaterSolutions::ItemRecalls->new({});

    my $message_id = $c->validation->param('message_id');
    my $CallSid    = $c->validation->param('CallSid');
    my $AccountSid = $c->validation->param('AccountSid');
    my $AnsweredBy = $c->validation->param('AnsweredBy');

    my $message    = Koha::Notice::Messages->find($message_id);
    unless ($message) {
        return $c->render(
            status  => 404,
            openapi => { error => "Message not found." }
        );
    }

    my $tw = new WWW::Twilio::TwiML;
    $tw->Response
    ->Pause({length => 2})->parent
    ->Say(
        {
            voice    => "Polly.Joanna",
            language => "en-US"
        },
        $message->content
    )->parent
    ->Pause({length => 2})->parent
    ->Say(
        {
            voice    => "Polly.Joanna",
            language => "en-US"
        },
        $message->content
    );

    warn "TWILIO: twiml(): " . Data::Dumper::Dumper( $tw->to_string );

    my $AccountSid = $self->retrieve_data('AccountSid');
    my $AuthToken  = $self->retrieve_data('AuthToken');

    my $ua = LWP::UserAgent->new;

    my $staffClientBaseURL = $self->retrieve_data('IncomingApiCallsUrl') || C4::Context->preference('staffClientBaseURL');
    $staffClientBaseURL =~ s/[^[:print:]]+//g;
    $staffClientBaseURL =~ s/[^[:ascii:]]+//g;

    # Send the call request
    my $url = "https://api.twilio.com/2010-04-01/Accounts/$AccountSid/Calls/$CallSid.json"

    $request = POST $url,
      [
          Twiml => $tw->to_string,
      ];
    $request->authorization_basic( $AccountSid, $AuthToken );
    $response = $ua->request($request);

    unless ($response->is_success) {
        warn "Twilio response indicates failure: " . $response->status_line;
    }
}

1;
