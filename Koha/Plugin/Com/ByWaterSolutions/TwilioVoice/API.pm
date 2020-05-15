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
    my $message = Koha::Notice::Messages->find( $message_id );
    unless ($message) {
        return $c->render( status => 404, openapi => { error => "Message not found." } );
    }

    my $tw = new WWW::Twilio::TwiML;
    $tw->Response->Say({voice => "alice", language => "en-AU"}, $message->content);
    print $tw->to_string;

    $message->status('sent');
    $message->store();

    return $c->render( status => 200, format => "xml", text => $tw->to_string );
}

sub update_message_status {
    my $c = shift->openapi->valid_input or return;

    my $message_id = $c->validation->param('message_id');
    warn "MESSAGE ID: $message_id";
    my $message = Koha::Notice::Messages->find( $message_id );
    unless ($message) {
        return $c->render( status => 404, openapi => { error => "Message not found." } );
    }

    my $body = $c->req->body;
    warn "BODY: $body";

    if ( my %data = parse_urlencoded($body) ) {
        warn Data::Dumper::Dumper( \%data );

        my $twilio_status = $data{CallStatus};
        warn "TWILIO STATUS: $twilio_status";

        my $status = $twilio_status eq 'queued'      ? 'pending' : # We should get another status update later
                     $twilio_status eq 'ringing'     ? 'pending' : # Ditto
                     $twilio_status eq 'in-progress' ? 'sent'    : # The person picked up, basically completed
                     $twilio_status eq 'completed'   ? 'sent'    : # Clearly completed
                     $twilio_status eq 'busy'        ? 'pending' : # Phone was busy, requeue and try again
                     $twilio_status eq 'failed'      ? 'failed'  : # Phone number was most likely invalid
                     $twilio_status eq 'no-answer'   ? 'pending' : # Nobody picked up, requeue and try again
                                                        'failed' ; # Staus was something we didn't expect
        warn "KOHA STATUS: $status";
        $message->status($status);
        $message->store();

        return $c->render( status => 200, text => q{} );
    } else {
        return $c->render( status => 500, openapi => { error => "Unable to decode json" } );
    }
}

1;
