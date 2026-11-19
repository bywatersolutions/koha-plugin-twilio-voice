#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

BEGIN {
    unshift( @INC, '/var/lib/koha/kohadev/plugins' );
    unshift( @INC, '/kohadevbox/koha' );
    unshift( @INC, '/kohadevbox/koha/t/lib' );
}

use Test::More tests => 2;
use Test::NoWarnings;

# A dev install has the literal placeholder "{VERSION}" as its version, which
# makes every version compare in Koha::Plugins::Base warn. Koha::Plugins loads
# enabled plugins at compile time, so filter that noise before the Koha
# modules load or Test::NoWarnings fails on it.
BEGIN {
    my $previous_warn = $SIG{__WARN__};
    $SIG{__WARN__} = sub {
        return if $_[0] =~ m/Argument "\{VERSION\}" isn't numeric/;
        $previous_warn ? $previous_warn->(@_) : warn @_;
    };
}

use C4::Context;
use Koha::Database;
use Koha::Notice::Message;

use t::lib::TestBuilder;

use Koha::Plugin::Com::ByWaterSolutions::TwilioVoice;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;
my $dbh     = C4::Context->dbh;

my $plugin = Koha::Plugin::Com::ByWaterSolutions::TwilioVoice->new;

sub build_message {
    my ($params) = @_;
    return Koha::Notice::Message->new(
        {
            borrowernumber         => $params->{patron}->id,
            subject                => 'Notice',
            content                => 'Notice content',
            letter_code            => $params->{letter_code} // 'HOLD',
            message_transport_type => $params->{message_transport_type},
            status                 => $params->{status} // 'pending',
            failure_code           => $params->{failure_code},
            time_queued            => \'NOW()',
        }
    )->store;
}

subtest 'single message runs skip other transports and the queue maintenance' => sub {
    plan tests => 4;

    $schema->storage->txn_begin;

    # Neutralize any existing phone messages so no calls are attempted
    $dbh->do(q{UPDATE message_queue SET status = 'deleted' WHERE message_transport_type = 'phone' AND status = 'pending'});

    my $patron = $builder->build_object( { class => 'Koha::Patrons' } );
    my $email  = build_message( { patron => $patron, message_transport_type => 'email', letter_code => 'PASSWORD_RESET' } );
    my $stale  = build_message(
        { patron => $patron, message_transport_type => 'phone', status => 'sent', failure_code => 'PENDING RESPONSE' } );
    $dbh->do(
        q{UPDATE message_queue SET updated_on = NOW() - INTERVAL 1 HOUR WHERE message_id = ?},
        undef, $stale->id
    );

    $plugin->before_send_messages( { message_id => $email->id } );
    is( $email->discard_changes->status, 'pending', 'email message left for Koha to send' );
    is( $stale->discard_changes->status, 'sent',    'stale call not reset when sending a single email' );

  SKIP: {
        # Koha 26.11 removed the overduerules table (Bug 10190), which full runs still query
        skip 'full runs need the overduerules table', 2 unless $dbh->selectrow_array(q{SHOW TABLES LIKE 'overduerules'});

        $plugin->before_send_messages( {} );
        is( $stale->discard_changes->status,       'failed', 'stale call reset on a full run' );
        is( $stale->discard_changes->failure_code, undef,    'failure code cleared on a full run' );
    }

    $schema->storage->txn_rollback;
};
