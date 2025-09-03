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

use HTTP::Request::Common;
use WWW::Form::UrlEncoded qw(parse_urlencoded);
use WWW::Twilio::TwiML;
use Try::Tiny;

use Koha::Notice::Messages;

=head1 API

=head2 Class Methods

=head3 Returns TwiML for the given message

=cut

sub twiml {
    warn "Koha::Plugin::Com::ByWaterSolutions::TwilioVoice::API::twiml";
    my $c = shift->openapi->valid_input or return;

    return try {

        my $message_id = $c->validation->param('message_id');
        my $message    = Koha::Notice::Messages->find($message_id);
        my $patron     = Koha::Patrons->find( $message->borrowernumber );
        unless ($message) {
            return $c->render(
                status  => 404,
                openapi => { error => "Message not found." }
            );
        }

        my $letter = C4::Letters::GetPreparedLetter(
            module      => "members",
            letter_code => "TWILIO_INTRO",
            message_transport_type => "phone",
            branchcode  => $patron->branchcode,
            objects     => {patron => $patron, borrower => $patron, message => $message},
        );

        my $twiml;
        if ( $letter ) {
            $twiml = $letter->{content};
        } else {
            my $self = Koha::Plugin::Com::ByWaterSolutions::TwilioVoice->new({});
            my $HoldMusicUrl
              = $self->retrieve_data('HoldMusicUrl') || "http://com.twilio.music.classical.s3.amazonaws.com/ClockworkWaltz.mp3";

            my $tw = new WWW::Twilio::TwiML;
            $tw->Response->Pause({length => 2})->parent->Say({voice => "Polly.Joanna", language => "en-US"},
                "You have a message from your library, please wait.")->parent->Pause({length => 2})
              ->parent->Play($HoldMusicUrl);
            $twiml = $tw->to_string;
        }

        $message->status('sent');
        $message->failure_code(undef); # Clear the PENDING RESPONSE we stored here when we sent the call request
        $message->store();

        warn "TWILIO VOICE: twiml(): " . Data::Dumper::Dumper( $twiml );

        return $c->render( status => 200, format => "xml", text => $twiml );
    } catch {
        warn "TwilioVoice ERROR: $_";
        $c->unhandled_exception($_);
    };
}

sub update_message_status {
    warn "Koha::Plugin::Com::ByWaterSolutions::TwilioVoice::API::update_message_status";
    my $c = shift->openapi->valid_input or return;

    return try {
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

            warn "TWILIO VOICE: update_message_status(): "
              . Data::Dumper::Dumper( \%data );

            my $status =
              $twilio_status eq 'queued'      ? 'sent'   :    # We should get another status update later
              $twilio_status eq 'ringing'     ? 'sent'   :    # Ditto
              $twilio_status eq 'in-progress' ? 'sent'   :    # The person picked up, basically completed
              $twilio_status eq 'completed'   ? 'sent'   :      # Clearly completed
              $twilio_status eq 'busy'        ? 'failed' :    # TODO: Make retrying busy a plugin setting
              $twilio_status eq 'failed'      ? 'failed' :    # Phone number was most likely invalid
              $twilio_status eq 'no-answer'   ? 'failed' :    # See TODO above
                                'failed';    # Staus was something we didn't expect


            $message->status($status);
            $message->failure_code(undef) if $twilio_status ne 'failed'; # Clear the PENDING RESPONSE we stored here when we sent the call request
            $message->store();

            return $c->render( status => 204, text => q{} );
        }
        else {
            return $c->render(
                status  => 501,
                openapi => { error => "Unable to decode json" }
            );
        }
    } catch {
        $c->unhandled_exception($_);
    };
}

sub amd_callback {
    warn "Koha::Plugin::Com::ByWaterSolutions::TwilioVoice::API::amd_callback";
    my $c = shift->openapi->valid_input or return;

    return try {

        my $message_id = $c->validation->param('message_id');

        my $body = $c->req->body;
        warn "TWILIO VOICE: BODY: $body";

        if ( my %data = parse_urlencoded($body) ) {
            my $CallSid    = $data{CallSid};
            my $AccountSid = $data{AccountSid};
            my $AnsweredBy = $data{AnsweredBy};

            warn "TWILIO VOICE: message_id: $message_id";
            warn "TWILIO VOICE: CallSid: $CallSid";
            warn "TWILIO VOICE: AccountSid: $AccountSid";
            warn "TWILIO VOICE: AnsweredBy: $AnsweredBy";

            my $message = Koha::Notice::Messages->find($message_id);
            unless ($message) {
                return $c->render(
                    status  => 404,
                    openapi => { error => "Message not found." }
                );
            }

            my $content;
            if (substr($message->content, 0, 39) eq '<?xml version="1.0" encoding="UTF-8" ?>') {
                $content = $message->content;
            }
            else {
                my $tw = new WWW::Twilio::TwiML;

                $tw->Response->Pause({length => 2})
                  ->parent->Say({voice => "Polly.Joanna", language => "en-US"}, $message->content)
                  ->parent->Pause({length => 2})
                  ->parent->Say({voice => "Polly.Joanna", language => "en-US"}, $message->content);

                $content = $tw->to_string;
            }

            warn "TWILIO VOICE: TwiML: " . Data::Dumper::Dumper( $content );

            #FIXME: Better to just grab from the database directly?
            my $self =
              Koha::Plugin::Com::ByWaterSolutions::TwilioVoice->new( {} );
            my $AuthToken = $self->retrieve_data('AuthToken');

            my $ua = LWP::UserAgent->new;

            # Send the call request
            my $url = "https://api.twilio.com/2010-04-01/Accounts/$AccountSid/Calls/$CallSid.json";
            warn "TWILIO VOICE: URL: $url";

            my $request = POST $url, [ Twiml => $content, ];
            $request->authorization_basic( $AccountSid, $AuthToken );
            my $response = $ua->request($request);
            warn "TWILIO VOICE: RESPONSE MESSAGE: " . $response->message;
            warn "TWILIO VOICE: RESPONSE CODE: " . $response->code;

            if ( $response->is_success ) {
                warn "TWILIO VOICE: Twilio response indicates success!";
                return $c->render( status => 204, text => q{} );
            }
            else {
                warn "TWILIO VOICE: Twilio response indicates failure: "
                  . $response->status_line;

                # Twilio failure usually indicates the call has already ended
                # Return a 2xx code to let Twilio know there's not a problem with our API
                return $c->render( status => 204, text => q{} );

                # return $c->render(
                #    status  => 501,
                #    openapi => { error => "Twilio call update failed" }
                #);
            }
        }
        else {
            warn "TWILIO VOICE: AMD 501 UNABLE TO PARSE BODY PARAMS";
            return $c->render(
                status  => 501,
                openapi => { error => "Unable to parse body parameters" }
            );
        }
    }
    catch {
        warn "TWILIO VOICE: CAUGHT UNHANDLED ERROR: $_";
        $c->unhandled_exception($_);
    };
}

1;
