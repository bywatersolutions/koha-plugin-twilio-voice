# Twilio Voice plugin for Koha

This plugin allows Koha to send 'phone' notices via the Twilio service API.

# Installation

This plugin requires the installation of following Perl modules on the Koha server:
* `WWW::Twilio::TwiML`
* `WWW::Form::UrlEncoded`

If those modules are not installed, this plugin may not appear in your Koha instance's list of installed plugins.

# Koha configuration
* Ensure the syspref `PhoneNotification` is enabled.
* Ensure the syspref `TalkingTechItivaPhoneNotification` is *not* enabled.
* Create the `phone` transport version of all notices patron's can opt to recieve via phone.
  * These notices will be read as-is over the phone via Twilio.
  * Best to keep notices as terse as possible.
  * Repeat the entire notice twice in case the call goes to voicemail.

# Plugin Configuration

> :warning: **Do not call your patrons by accident in the middle of the night!** Run multiple instances of `process_message_queue.pl` with the `-t` paramter. Limit sending of phone calls common waking hours in your area.

* Create a Twilio account, log in to Twilio
* Create a new project
* Get a trial number, or verify an existing phone number for this project
* Verify your phone number for testing purposes 
* Note your Account SID and Auth Token on the project landing page
* Browse to the Twilio plugin configuration page in Koha
* From there, you can plug in the Account SID, Auth Token, and Twilio phone number from  your Twilio project
